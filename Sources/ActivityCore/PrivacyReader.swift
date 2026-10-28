import AppKit
import AudioToolbox
import CoreAudio
import CoreMediaIO
import Darwin
import Foundation

/// Which apps use the microphone and whether a camera is running, like the orange and green dots in the menu bar.
/// Only reads: Core Audio's process list and Core Media IO's "is running somewhere" flag. Neither opens the
/// microphone or camera, and neither shows a permission prompt.
public enum PrivacyReader {
    /// An app (or the app behind a helper process) that uses the microphone or camera.
    public struct Client: Sendable, Hashable, Identifiable {
        public let name: String
        public let bundleID: String?
        public let pid: pid_t
        public var id: String { bundleID ?? "pid:\(pid)" }
        public init(name: String, bundleID: String?, pid: pid_t) { self.name = name; self.bundleID = bundleID; self.pid = pid }
        public static func == (lhs: Client, rhs: Client) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: Microphone

    /// Apps that are recording audio right now (the calling process excluded).
    public static func microphoneUsers() -> [Client] {
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
        var found: [String: Client] = [:]
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
    private static func resolve(pid: pid_t, fallbackBundleID: String?) -> Client {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return Client(name: app.localizedName ?? app.bundleIdentifier ?? "Process \(current)",
                              bundleID: app.bundleIdentifier, pid: current)
            }
            let parent = parentPID(of: current)
            if parent <= 1 { break }
            current = parent
        }
        // Not part of a regular app (Siri, dictation, a command-line tool).
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? processName(pid) ?? fallbackBundleID?.split(separator: ".").last.map(String.init) ?? "Process \(pid)"
        return Client(name: name, bundleID: fallbackBundleID ?? app?.bundleIdentifier, pid: pid)
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

    /// Names of the cameras that are running right now.
    public static func runningCameras() -> [String] {
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

    public static let cameraApps: Set<String> = [
        "com.apple.FaceTime", "com.apple.PhotoBooth", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.skype.skype", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
        "com.obsproject.obs-studio", "com.apple.QuickTimePlayerX", "com.google.Chrome", "com.apple.Safari",
        "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "com.loom.desktop", "com.logitech.logitune",
    ]

    /// Apps that use the microphone are almost always the ones with the camera too (calls); otherwise known camera apps
    /// that are running. A guess, shown as "probably".
    public static func cameraCandidates(microphoneUsers: [Client]) -> [Client] {
        if !microphoneUsers.isEmpty { return microphoneUsers }
        let running: [Client] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return Client(name: app.localizedName ?? id, bundleID: id, pid: app.processIdentifier)
        }
        return pickCameraCandidate(running)
    }

    /// From the running regular apps: exactly one well-known camera app is a usable guess; several (a browser, a
    /// chat app, a call app) say nothing, so the answer is empty then.
    public static func pickCameraCandidate(_ running: [Client]) -> [Client] {
        let known = running.filter { $0.bundleID.map(cameraApps.contains) ?? false }
        return known.count == 1 ? known : []
    }
}
