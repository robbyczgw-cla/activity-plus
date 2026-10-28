import ActivityCore
import AppKit
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

    init(name: String, bundleID: String?, pid: pid_t, icon: NSImage?) {
        self.name = name; self.bundleID = bundleID; self.pid = pid; self.icon = icon
    }

    init(_ client: PrivacyReader.Client) {
        self.init(name: client.name, bundleID: client.bundleID, pid: client.pid,
                  icon: NSRunningApplication(processIdentifier: client.pid)?.icon)
    }
}

/// Which apps use the microphone and whether a camera is on, like the orange and green dots in the menu bar.
/// Only reads (see `PrivacyReader` in ActivityCore): neither opens the microphone or camera, and neither shows a
/// permission prompt. Polls every 2.5 s while something observes it.
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
        let clients = PrivacyReader.microphoneUsers()
        let mics = clients.map(AppRef.init)
        let devices = PrivacyReader.runningCameras()
        if mics != microphone { microphone = mics }
        if devices != cameraDevices { cameraDevices = devices }
        let on = !devices.isEmpty
        if on != cameraInUse { cameraInUse = on }
        let guess = on ? PrivacyReader.cameraCandidates(microphoneUsers: clients).map(AppRef.init) : []
        if guess != camera { camera = guess }
    }
}
