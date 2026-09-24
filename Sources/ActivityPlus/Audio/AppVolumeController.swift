import AppKit
import AudioToolbox
import CoreAudio
import Observation
import Synchronization

@MainActor
@Observable
final class AppVolumeController {
    struct AudioApp: Identifiable, Hashable {
        let id: String
        let name: String
        let pids: [pid_t]
        var isPlaying: Bool
    }

    private(set) var apps: [AudioApp] = []
    private(set) var lastError: String?

    @ObservationIgnored private var controls: [String: Control] = [:]
    @ObservationIgnored private var activeTaps: [String: ActiveTap] = [:]
    @ObservationIgnored private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var stopped = false

    private final class Control {
        var volume: Float = 1
        var muted = false
    }

    private final class GainBox {
        let value: Atomic<Float>
        init(_ gain: Float) { value = Atomic(gain) }
        func set(_ gain: Float) { value.store(gain, ordering: .releasing) }
        func get() -> Float { value.load(ordering: .acquiring) }
    }

    private final class ActiveTap {
        let tapID: AudioObjectID
        let aggregateID: AudioDeviceID
        let ioProcID: AudioDeviceIOProcID
        let gain: GainBox

        init(tapID: AudioObjectID, aggregateID: AudioDeviceID, ioProcID: AudioDeviceIOProcID, gain: GainBox) {
            self.tapID = tapID
            self.aggregateID = aggregateID
            self.ioProcID = ioProcID
            self.gain = gain
        }
    }

    init() {
        installDefaultOutputListener()
        refresh()
    }

    deinit {
        if let listener = defaultOutputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        }
        for tap in activeTaps.values { Self.destroy(tap) }
    }

    func refresh() {
        guard !stopped else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { setError("Unable to read Core Audio process list (\(status))."); return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: 0, count: count)
        status = objects.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { setError("Unable to read Core Audio process list (\(status))."); return }

        var grouped: [String: (name: String, pids: Set<pid_t>, playing: Bool, objects: [AudioObjectID])] = [:]
        for object in objects {
            guard let pid: pid_t = processValue(object, selector: kAudioProcessPropertyPID),
                  let running: UInt32 = processValue(object, selector: kAudioProcessPropertyIsRunningOutput),
                  running != 0 else { continue }
            let bundleValue: CFString? = processValue(object, selector: kAudioProcessPropertyBundleID)
            let bundle = bundleValue as String?
            let app = NSRunningApplication(processIdentifier: pid)
            let id = bundle.flatMap { $0.isEmpty ? nil : $0 } ?? "pid:\(pid)"
            var item = grouped[id] ?? (app?.localizedName ?? bundle ?? "Process \(pid)", [], false, [])
            item.pids.insert(pid)
            item.playing = true
            item.objects.append(object)
            grouped[id] = item
        }

        apps = grouped.map { id, value in
            AudioApp(id: id, name: value.name, pids: value.pids.sorted(), isPlaying: value.playing)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastError = nil

        for (id, tap) in activeTaps where grouped[id] == nil {
            Self.destroy(tap)
            activeTaps.removeValue(forKey: id)
        }
        for (id, value) in grouped where effectiveGain(for: id) != 1 {
            if activeTaps[id] == nil { createTap(for: id, processObjects: value.objects) }
        }
    }

    func volume(for appID: String) -> Float { controls[appID]?.volume ?? 1 }

    func setVolume(_ volume: Float, for appID: String) {
        let control = controls[appID] ?? Control()
        controls[appID] = control
        control.volume = min(2, max(0, volume.isFinite ? volume : 1))
        applyControl(for: appID)
    }

    func isMuted(_ appID: String) -> Bool { controls[appID]?.muted ?? false }

    func setMuted(_ muted: Bool, for appID: String) {
        let control = controls[appID] ?? Control()
        controls[appID] = control
        control.muted = muted
        applyControl(for: appID)
    }

    func stopAll() {
        stopped = true
        for tap in activeTaps.values { Self.destroy(tap) }
        activeTaps.removeAll()
        if let listener = defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, DispatchQueue.main, listener)
            defaultOutputListener = nil
        }
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                                           mElement: kAudioObjectPropertyElementMain)

    private func installDefaultOutputListener() {
        let queue = DispatchQueue.main
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.rebuildTaps() }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, listener)
        if status == noErr { defaultOutputListener = listener }
        else { setError("Unable to observe default output changes (\(status)).") }
    }

    private func rebuildTaps() {
        for tap in activeTaps.values { Self.destroy(tap) }
        activeTaps.removeAll()
        refresh()
    }

    private func effectiveGain(for id: String) -> Float {
        let control = controls[id]
        return control?.muted == true ? 0 : (control?.volume ?? 1)
    }

    private func applyControl(for id: String) {
        let gain = effectiveGain(for: id)
        if gain == 1 {
            if let tap = activeTaps.removeValue(forKey: id) { Self.destroy(tap) }
        } else if let tap = activeTaps[id] {
            tap.gain.set(gain)
        } else if let app = apps.first(where: { $0.id == id }) {
            let objects = processObjects(for: app.pids)
            createTap(for: id, processObjects: objects)
        }
    }

    private func createTap(for id: String, processObjects: [AudioObjectID]) {
        guard !processObjects.isEmpty else { return }
        let gain = GainBox(effectiveGain(for: id))
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.name = "ActivityPlus \(id)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { setError("Unable to create audio tap for \(id) (\(status)); check audio capture permission."); return }

        guard let outputUID = defaultOutputUID() else {
            AudioHardwareDestroyProcessTap(tapID)
            setError("No default output device is available.")
            return
        }
        let tapEntry: [String: Any] = ["uid": description.uuid.uuidString,
                                       "drift": true]
        let aggregate: [String: Any] = [kAudioAggregateDeviceNameKey: "ActivityPlus \(id)",
                                        kAudioAggregateDeviceUIDKey: UUID().uuidString,
                                        kAudioAggregateDeviceIsPrivateKey: true,
                                        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                                        kAudioAggregateDeviceSubDeviceListKey: [["uid": outputUID]],
                                        kAudioAggregateDeviceTapListKey: [tapEntry],
                                        kAudioAggregateDeviceTapAutoStartKey: true]
        var aggregateID = AudioDeviceID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            setError("Unable to create private audio device for \(id) (\(status)).")
            return
        }

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, DispatchQueue.global(qos: .userInitiated)) { _, input, _, output, _ in
            let multiplier = gain.get()
            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outBuffers = UnsafeMutableAudioBufferListPointer(output)
            for index in 0..<min(inBuffers.count, outBuffers.count) {
                guard let source = inBuffers[index].mData, let destination = outBuffers[index].mData else { continue }
                let bytes = min(Int(inBuffers[index].mDataByteSize), Int(outBuffers[index].mDataByteSize))
                destination.copyMemory(from: source, byteCount: bytes)
                let samples = bytes / MemoryLayout<Float>.stride
                let floats = destination.assumingMemoryBound(to: Float.self)
                for sample in 0..<samples { floats[sample] *= multiplier }
            }
        }
        guard status == noErr, let ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            setError("Unable to create audio processing callback for \(id) (\(status)).")
            return
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            setError("Unable to start audio processing for \(id) (\(status)).")
            return
        }
        activeTaps[id] = ActiveTap(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID, gain: gain)
        lastError = nil
    }

    private func processObjects(for pids: [pid_t]) -> [AudioObjectID] {
        pids.compactMap { pid in
            var processID = pid
            var object = AudioObjectID(kAudioObjectUnknown)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                    UInt32(MemoryLayout<pid_t>.size), &processID,
                                                    &size, &object)
            return result == noErr ? object : nil
        }
    }

    private func defaultOutputUID() -> String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var address = Self.defaultOutputAddress
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    private func processValue<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        return status == noErr ? value.load(as: T.self) : nil
    }

    private func setError(_ message: String) { lastError = message }

    nonisolated private static func destroy(_ tap: ActiveTap) {
        AudioDeviceStop(tap.aggregateID, tap.ioProcID)
        AudioDeviceDestroyIOProcID(tap.aggregateID, tap.ioProcID)
        AudioHardwareDestroyAggregateDevice(tap.aggregateID)
        AudioHardwareDestroyProcessTap(tap.tapID)
    }
}
