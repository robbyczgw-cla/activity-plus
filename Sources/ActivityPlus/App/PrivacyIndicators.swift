import AppKit
import AudioToolbox
import CoreAudio
import CoreMediaIO
import Darwin
import Observation

/// An app (or the app behind a helper process) that uses the microphone or camera.
struct AppRef: Identifiable, Hashable {
    let name: String
    let bundleID: String?
    let pid: pid_t
    let icon: NSImage?
    var id: String { bundleID ?? "pid:\(pid)" }

    static func == (lhs: AppRef, rhs: AppRef) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Which apps use the microphone and whether a camera is on, like the orange and green dots in the menu bar.
/// Only reads: Core Audio's process list and Core Media IO's "is running somewhere" flag. Neither opens the
/// microphone or camera, and neither shows a permission prompt. Polls every 2.5 s while something observes it.
@MainActor @Observable
final class PrivacyIndicators {
    static let shared = PrivacyIndicators()

    /// Apps that are recording audio right now.
    private(set) var microphone: [AppRef] = []
    /// A camera is running. macOS offers no way to ask which app uses it, so this is a guess.
    private(set) var cameraInUse = false
    /// Names of the cameras that are running.
    private(set) var cameraDevices: [String] = []
    /// Apps that probably use the camera: well-known camera apps that are running, or the microphone users.
    /// Empty when nothing sensible can be guessed.
    private(set) var camera: [AppRef] = []

    var isActive: Bool { !microphone.isEmpty || cameraInUse }

    @ObservationIgnored private var observers = 0
    @ObservationIgnored private var timer: Timer?

    private init() {}

    /// Call when a view (or panel) starts showing the indicators; balance with `release()`.
    func retain() {
        observers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func release() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        timer?.invalidate()
        timer = nil
        microphone = []; camera = []; cameraDevices = []; cameraInUse = false
    }

    func refresh() {
        let mics = Self.microphoneUsers()
        let devices = Self.runningCameras()
        if mics != microphone { microphone = mics }
        if devices != cameraDevices { cameraDevices = devices }
        let on = !devices.isEmpty
        if on != cameraInUse { cameraInUse = on }
        let guess = on ? Self.cameraCandidates(microphoneUsers: mics) : []
        if guess != camera { camera = guess }
    }

    // MARK: Microphone

    private static func microphoneUsers() -> [AppRef] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        let status = objects.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }

        let me = getpid()
        var found: [String: AppRef] = [:]
        for object in objects {
            guard let running: UInt32 = audioValue(object, kAudioProcessPropertyIsRunningInput), running != 0,
                  let pid: pid_t = audioValue(object, kAudioProcessPropertyPID), pid != me else { continue }
            let bundle: CFString? = audioValue(object, kAudioProcessPropertyBundleID)
            let ref = resolve(pid: pid, fallbackBundleID: bundle as String?)
            found[ref.id] = found[ref.id] ?? ref
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func audioValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr ? value.load(as: T.self) : nil
    }

    /// The app a process belongs to: helpers (Chrome's audio service, Zoom's media process) are folded into
    /// the regular app that started them.
    private static func resolve(pid: pid_t, fallbackBundleID: String?) -> AppRef {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return AppRef(name: app.localizedName ?? app.bundleIdentifier ?? "Process \(current)",
                              bundleID: app.bundleIdentifier, pid: current, icon: app.icon)
            }
            let parent = parentPID(of: current)
            if parent <= 1 { break }
            current = parent
        }
        // Not part of a regular app (Siri, dictation, a command-line tool).
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? processName(pid) ?? fallbackBundleID?.split(separator: ".").last.map(String.init) ?? "Process \(pid)"
        return AppRef(name: name, bundleID: fallbackBundleID ?? app?.bundleIdentifier, pid: pid, icon: app?.icon)
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? pid_t(info.pbi_ppid) : 0
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    // MARK: Camera

    private static func runningCameras() -> [String] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.stride)
        var used: UInt32 = 0
        let status = devices.withUnsafeMutableBytes { CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, $0.baseAddress!) }
        guard status == 0 else { return [] }

        var names: [String] = []
        for device in devices {
            var running = UInt32(0)
            var runningAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                           mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                           mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var runningUsed: UInt32 = 0
            guard CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running) == 0,
                  running != 0 else { continue }
            names.append(deviceName(device) ?? "Camera")
        }
        return names
    }

    private static func deviceName(_ device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &name)
        return status == 0 ? name?.takeRetainedValue() as String? : nil
    }

    private static let cameraApps: Set<String> = [
        "com.apple.FaceTime", "com.apple.PhotoBooth", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.skype.skype", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
        "com.obsproject.obs-studio", "com.apple.QuickTimePlayerX", "com.google.Chrome", "com.apple.Safari",
        "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "com.loom.desktop", "com.logitech.logitune",
    ]

    /// Apps that use the microphone are almost always the ones with the camera too (calls); otherwise known camera apps
    /// that are running. A guess, shown as "probably".
    private static func cameraCandidates(microphoneUsers: [AppRef]) -> [AppRef] {
        if !microphoneUsers.isEmpty { return microphoneUsers }
        let running: [AppRef] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, cameraApps.contains(id) else { return nil }
            return AppRef(name: app.localizedName ?? id, bundleID: id, pid: app.processIdentifier, icon: app.icon)
        }
        // Several candidates (a browser, a chat app, a call app) say nothing; stay silent then.
        return running.count == 1 ? running : []
    }
}
