import ActivityCore
import AppKit
import SwiftUI

/// Where the notch is: the built-in display whose safe area has a top inset.
struct NotchGeometry: Equatable {
    /// The notch in global screen coordinates (bottom-left origin).
    let notch: NSRect
    let screenFrame: NSRect

    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               CGDisplayIsBuiltin(id) == 0 { continue }
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let width = screen.frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            guard width > 40, height > 0 else { continue }
            let notch = NSRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - height, width: width, height: height)
            return NotchGeometry(notch: notch, screenFrame: screen.frame)
        }
        return nil
    }

    static var exists: Bool { current() != nil }
}

/// Settings → Menu Bar → Notch.
enum NotchSettings {
    static let enabledKey = "notch.enabled"
    static let hoverKey = "notch.hoverValues"
    static func hintKey(_ kind: NotchHint.Kind) -> String { "notch.hint.\(kind.rawValue)" }

    private static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static var enabled: Bool { flag(enabledKey) }
    static var hoverValues: Bool { flag(hoverKey) }
    static func allows(_ kind: NotchHint.Kind) -> Bool { flag(hintKey(kind)) }
}

/// Never becomes key or main, so hovering or clicking it never takes focus from the app you are in.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// AppKit would push a window that overlaps the menu bar down below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI content; reports the pointer entering and leaving, and takes the first click.
private final class NotchHostingView: NSHostingView<NotchRootView> {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    required init(rootView: NotchRootView) { super.init(rootView: rootView) }
    @MainActor required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // activeAlways: works while another app is active and the panel is not key.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHover?(false) }
    }
}

/// The notch panel: invisible over the notch while idle, live values on hover, short hints.
///
/// The window always has the size of what it shows (the bare notch while idle), so it never covers
/// menu bar items it does not draw over. It is a non-activating panel that cannot become key, sits
/// at status bar level on every Space, and is left out of window cycling, Mission Control and
/// screen captures.
@MainActor
final class NotchController {
    static let shared = NotchController()

    private let model = NotchModel()
    private var panel: NotchPanel?
    private var host: NotchHostingView?
    private var geometry: NotchGeometry?
    private var started = false
    private var hovering = false
    private var pendingExpand: Task<Void, Never>?
    private var pendingCollapse: Task<Void, Never>?
    private var hintTimer: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    private static let expandAnimation = Animation.spring(response: 0.38, dampingFraction: 0.8)
    private static let collapseAnimation = Animation.spring(response: 0.3, dampingFraction: 1)

    private init() {}

    var isActive: Bool { panel?.isVisible == true }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Monitor.shared.observers.append { [weak self] snapshot in
            MainActor.assumeIsolated { self?.observe(snapshot) }
        }
        refresh()
        runDemoIfRequested()
    }

    /// Shows or hides the panel for the current displays and settings.
    func refresh() {
        let geometry = NotchSettings.enabled ? NotchGeometry.current() : nil
        guard let geometry else {
            self.geometry = nil
            reset()
            panel?.orderOut(nil)
            return
        }
        let changed = geometry != self.geometry
        self.geometry = geometry
        model.notch = geometry.notch.size
        let panel = panel ?? makePanel()
        if changed { reset() }
        panel.setFrame(frame(for: model.mode), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        let host = NotchHostingView(rootView: NotchRootView(model: model, open: { [weak self] page in self?.open(page) }))
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    /// The window frame for a mode: the shape's size, top-centered on the notch.
    private func frame(for mode: NotchModel.Mode) -> NSRect {
        guard let geometry else { return .zero }
        let size = model.size(mode)
        return NSRect(x: (geometry.notch.midX - size.width / 2).rounded(), y: geometry.screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Transitions

    private func show(_ mode: NotchModel.Mode) {
        guard let panel, geometry != nil, model.mode != mode else { return }
        settleTask?.cancel()
        let target = frame(for: mode)
        // Grow the window first (the shape animates inside it), shrink it only once the shape is small.
        let current = panel.frame
        let union = NSRect(x: min(current.minX, target.minX), y: min(current.minY, target.minY),
                           width: max(current.maxX, target.maxX) - min(current.minX, target.minX),
                           height: max(current.maxY, target.maxY) - min(current.minY, target.minY))
        panel.setFrame(union, display: true)
        let growing = model.size(mode).height >= model.size(model.mode).height
        withAnimation(growing ? Self.expandAnimation : Self.collapseAnimation) { model.mode = mode }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, let self, self.model.mode == mode else { return }
            self.panel?.setFrame(target, display: true)
            self.recheckPointer()
        }
    }

    private func collapse() {
        pendingCollapse?.cancel()
        hintTimer?.cancel()
        show(.idle)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            self?.showNextHint()
        }
    }

    private func reset() {
        pendingExpand?.cancel(); pendingCollapse?.cancel(); hintTimer?.cancel(); settleTask?.cancel()
        hovering = false
        model.mode = .idle
    }

    private func open(_ page: String) {
        collapse()
        WindowOpener.openMain(page: page)
    }

    // MARK: Hover

    private func hoverChanged(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            pendingCollapse?.cancel()
            guard NotchSettings.hoverValues, model.mode != .expanded else { return }
            pendingExpand?.cancel()
            pendingExpand = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled, let self, self.hovering else { return }
                self.hintTimer?.cancel()
                self.show(.expanded)
            }
        } else {
            pendingExpand?.cancel()
            guard model.mode != .idle else { return }
            // A hint you pointed at goes away a little later; the hover panel after half a second.
            let delay = model.mode == .expanded ? 0.5 : 1.0
            pendingCollapse?.cancel()
            pendingCollapse = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, !self.hovering else { return }
                self.collapse()
            }
        }
    }

    /// After the window changes size under a still pointer, no enter/exit event arrives.
    private func recheckPointer() {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        let frame = panel.frame
        // The top edge is the screen edge: count the pointer pressed against it as inside.
        let inside = point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY + 1
        if inside != hovering { hoverChanged(inside) }
    }

    // MARK: Hints

    private var queue: [(hint: NotchHint, date: Date, duration: TimeInterval)] = []
    private var lastShown: [String: Date] = [:]
    private var retry: Task<Void, Never>?

    /// Queues a hint; the same key appears at most once every 10 minutes.
    func post(_ hint: NotchHint, force: Bool = false, duration: TimeInterval = 4) {
        guard isActive, force || NotchSettings.allows(hint.kind) else { return }
        if !force, let last = lastShown[hint.key], Date().timeIntervalSince(last) < 600 { return }
        lastShown[hint.key] = Date()
        queue.removeAll { $0.hint.key == hint.key }
        queue.append((hint, Date(), duration))
        showNextHint()
    }

    /// Not while the panel is open or about to open, a button is held, the pointer is up in the
    /// menu bar (someone using menus), or Find the Cause is measuring WindowServer.
    private var hintBlocked: Bool {
        if model.mode != .idle || hovering { return true }
        if NSEvent.pressedMouseButtons != 0 { return true }
        if GPUCauseFinder.shared.isRunning { return true }
        if let geometry {
            let point = NSEvent.mouseLocation
            let strip = NSRect(x: geometry.screenFrame.minX, y: geometry.notch.minY,
                               width: geometry.screenFrame.width, height: geometry.notch.height + 1)
            if strip.contains(point) { return true }
        }
        return false
    }

    private func showNextHint() {
        queue.removeAll { Date().timeIntervalSince($0.date) > 20 }
        guard let next = queue.first else { return }
        guard !hintBlocked else {
            retry?.cancel()
            retry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.showNextHint()
            }
            return
        }
        queue.removeFirst()
        show(.hint(next.hint))
        let duration = next.duration
        hintTimer?.cancel()
        hintTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, case .hint = self.model.mode, !self.hovering else { return }
            self.collapse()
        }
    }

    // MARK: Watching for hint-worthy changes (no extra sampling: the snapshot Monitor already made)

    private var previous: SystemSnapshot?
    private var seenHangs: Set<UUID> = []
    private var recordingID: Int64?
    private var findCauseRunning = false
    private var recordingStarted: Date?
    private var chargerPending = 0

    private func observe(_ s: SystemSnapshot) {
        defer { previous = s }
        let services = AppServices.shared
        let recording = services.recording
        let running = GPUCauseFinder.shared.isRunning
        defer {
            recordingID = recording?.id
            findCauseRunning = running
        }
        guard isActive, let prev = previous else {
            seenHangs = Set(services.hangs.current.values.map(\.id))
            return
        }

        if s.memory.pressure == .critical, prev.memory.pressure != .critical {
            post(NotchHint(kind: .memory, key: "memory", symbol: "memorychip", tint: .red,
                           text: String(localized: "Memory pressure is critical"),
                           trailing: Format.memory(s.memory.used), page: "metric:memory"))
        }

        if s.thermal.level >= 2, s.thermal.level > prev.thermal.level {
            let critical = s.thermal == .critical
            post(NotchHint(kind: .thermal, key: "thermal", symbol: "thermometer.high", tint: critical ? .red : .orange,
                           text: critical ? String(localized: "Your Mac is very hot") : String(localized: "Your Mac is getting hot"),
                           trailing: s.sensors.cpuTemperature.map { Format.temperature($0) }, page: "sensors"))
        }

        // Charger: the adapter's rating can arrive a sample after the plug, so wait up to two samples for it.
        if let battery = s.battery {
            if battery.isPluggedIn, prev.battery?.isPluggedIn == false { chargerPending = 3 }
            if chargerPending > 0 {
                chargerPending -= 1
                if !battery.isPluggedIn {
                    chargerPending = 0
                } else if battery.adapterWatts != nil || chargerPending == 0 {
                    chargerPending = 0
                    post(Self.chargerHint(battery))
                }
            }
        }

        if Performance.hangs {
            let current = services.hangs.current.values
            for hang in current where !seenHangs.contains(hang.id) {
                post(NotchHint(kind: .hang, key: "hang:\(hang.bundleID ?? hang.name)", symbol: "hourglass", tint: .yellow,
                               text: String(localized: "\(hang.name) is not responding"), page: "alerts"))
            }
            seenHangs = Set(current.map(\.id))
        }

        if let recording, recordingID == nil {
            recordingStarted = recording.started
            post(NotchHint(kind: .recording, key: "recording.start", symbol: "record.circle", tint: .red,
                           text: String(localized: "Recording started"), page: "sessions"))
        } else if recording == nil, recordingID != nil {
            let length = recordingStarted.map { Format.duration(Date().timeIntervalSince($0)) }
            post(NotchHint(kind: .recording, key: "recording.stop", symbol: "stop.circle", tint: .white,
                           text: String(localized: "Recording stopped"), trailing: length, page: "sessions"))
        }

        // Only the result: an animation during the run would add to the WindowServer load it measures.
        if findCauseRunning, !running, case .done(let analysis, _, _) = GPUCauseFinder.shared.state {
            let text: String
            if let cause = analysis.causes.first(where: \.isMeasurable) {
                text = String(localized: "Find the Cause: \(cause.name)")
            } else {
                text = String(localized: "Find the Cause: no single app")
            }
            post(NotchHint(kind: .findCause, key: "findCause", symbol: "magnifyingglass", tint: .cyan,
                           text: text, page: "metric:gpu"))
        }
    }

    static func chargerHint(_ battery: BatteryStats) -> NotchHint {
        let watts = battery.adapterWatts.map { " · \($0) W" } ?? ""
        let text = battery.isCharging ? String(localized: "Charging\(watts)") : String(localized: "Plugged in\(watts)")
        return NotchHint(kind: .charger, key: "charger", symbol: "bolt.fill", tint: .green,
                         text: text, trailing: Format.percent(battery.percent), page: "battery")
    }

    /// A believable hint for demos and snapshots: the charger if one is connected, else memory pressure.
    static func sampleHint() -> NotchHint {
        let s = Monitor.shared.snapshot
        if let battery = s.battery, battery.isPluggedIn { return chargerHint(battery) }
        return NotchHint(kind: .memory, key: "demo", symbol: "memorychip", tint: .red,
                         text: String(localized: "Memory pressure is critical"),
                         trailing: Format.memory(s.memory.used), page: "metric:memory")
    }

    // MARK: Debug aids

    /// ACTIVITYPLUS_NOTCH_DEMO=hover opens the panel at launch (it stays until the pointer has passed over it);
    /// =hint shows a sample hint every 8 seconds, six times.
    private func runDemoIfRequested() {
        guard let demo = ProcessInfo.processInfo.environment["ACTIVITYPLUS_NOTCH_DEMO"] else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.isActive else { NSLog("notch demo: no notch panel (no notch, or turned off)"); return }
            switch demo {
            case "hint":
                // The real 4 seconds and the collapse, a few times over.
                for _ in 0..<6 {
                    self.post(Self.sampleHint(), force: true)
                    try? await Task.sleep(for: .seconds(8))
                }
            default:
                self.show(.expanded)
            }
        }
    }

    /// Offscreen renders for SnapshotRunner: notch-hover.png and notch-hint.png, drawn on a strip that
    /// stands in for the menu bar so the outline is visible.
    static func renderSnapshots(to dir: String) {
        let notch = NotchGeometry.current()?.notch.size ?? CGSize(width: 185, height: 32)
        for (name, mode) in [("notch-hover", NotchModel.Mode.expanded), ("notch-hint", .hint(sampleHint()))] {
            let model = NotchModel(notch: notch, mode: mode)
            let size = model.largest
            let canvas = CGSize(width: size.width + 120, height: size.height + 40)
            let view = ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Color(white: 0.86).frame(height: notch.height)
                    LinearGradient(colors: [Color(red: 0.32, green: 0.42, blue: 0.56), Color(red: 0.2, green: 0.25, blue: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                }
                NotchRootView(model: model, open: { _ in }).frame(width: size.width, height: size.height)
            }
            .frame(width: canvas.width, height: canvas.height)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: canvas)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            savePNG(host, to: "\(dir)/\(name).png")
        }
    }

    private static func savePNG(_ view: NSView, to path: String) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
