import ActivityCore
import AppKit
import SwiftUI

/// How the configured items appear: one status item each, all in one, or one each until they stop fitting.
enum MenuBarLayout: String, CaseIterable, Identifiable {
    case separate, combined, automatic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .separate: "Separate"
        case .combined: "Combined"
        case .automatic: "Combine when they don't fit"
        }
    }
    static var current: MenuBarLayout {
        MenuBarLayout(rawValue: UserDefaults.standard.string(forKey: "menuBarLayout") ?? "") ?? .automatic
    }
}

/// What the last layout check found, for the Menu Bar settings.
@MainActor @Observable
final class MenuBarLayoutStatus {
    static let shared = MenuBarLayoutStatus()
    /// Items macOS could not place, typically pushed behind the notch.
    var hidden = 0
    /// Automatic mode found too little room and combined the items.
    var autoCombined = false
    /// Set when even the combined item was too wide: how many values it shows.
    var combinedShowing: Int?
}

/// Owns one NSStatusItem per configured menu bar item. SwiftUI's MenuBarExtra only supports a fixed
/// number of items, so this is plain AppKit: each item's look is a SwiftUI view rendered to an image.
@MainActor
final class StatusItemsController: NSObject, NSPopoverDelegate {
    static let shared = StatusItemsController()

    private var entries: [(config: MenuBarItemConfig, item: NSStatusItem)] = []
    /// The single item of the combined layout, and which horizontal stretch of it belongs to which module.
    private var combined: NSStatusItem?
    private var segments: [(tab: MenuBarPanel.Tab, minX: CGFloat, maxX: CGFloat)] = []
    private var configs: [MenuBarItemConfig] = []
    /// How many values the combined item shows; lowered when even the combined item does not fit.
    private var combinedLimit = Int.max
    private let popover = NSPopover()
    private weak var popoverButton: NSStatusBarButton?

    func start() {
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        reload()
        Monitor.shared.observers.append { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: MenuBarItemStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryLayout() }
        }
        // Another display, a closed lid or a new resolution: maybe everything fits again (or no longer does).
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryLayout() }
        }
        // The clock must tick even when sampling is slow.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.configs.contains(where: { $0.module == .clock }) else { return }
                self.refresh(onlyClocks: true)
            }
        }
    }

    /// Recreates all items; creation order decides the position (the first item ends up rightmost).
    private var reloads = 0

    func reload() {
        reloads += 1
        if ProcessInfo.processInfo.environment["ACTIVITYPLUS_SNAPSHOTS"] != nil { NSLog("snapshot statusItems reload #%d", reloads) }
        entries.forEach { NSStatusBar.system.removeStatusItem($0.item) }
        entries = []
        if let combined { NSStatusBar.system.removeStatusItem(combined) }
        combined = nil
        popover.performClose(nil)
        // "Dock only": no menu bar items at all (the snapshot mode still renders them).
        guard AppPresence.current.showsMenuBar || ProcessInfo.processInfo.environment["ACTIVITYPLUS_SNAPSHOTS"] != nil else {
            if ProcessInfo.processInfo.environment["ACTIVITYPLUS_DEBUG_MENUBAR"] != nil { NSLog("menubar items: 0 (presence dockOnly)") }
            return
        }
        var configs = MenuBarItemStore.load()
        // An app without any menu bar item could not be reached once its window is closed.
        if configs.isEmpty { configs = [MenuBarItemConfig(module: .status, style: .icon)] }
        self.configs = configs
        let layout = MenuBarLayout.current
        if layout == .combined || (layout == .automatic && MenuBarLayoutStatus.shared.autoCombined) {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "activityplus.combined"
            if let button = item.button {
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.imagePosition = .imageOnly
                button.toolTip = "Activity+"
            }
            combined = item
            combinedLimit = Int.max
            MenuBarLayoutStatus.shared.combinedShowing = nil
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.checkFit() }
            return
        }
        for config in configs.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "activityplus.\(config.id.uuidString)"
            if let button = item.button {
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.imagePosition = .imageOnly
                button.toolTip = "Activity+ · \(config.module.title)"
            }
            entries.insert((config, item), at: 0)
        }
        refresh()
        if ProcessInfo.processInfo.environment["ACTIVITYPLUS_DEBUG_MENUBAR"] != nil {
            NSLog("menubar items: %d (presence %@)", entries.count, AppPresence.current.rawValue)
        }
        // macOS places status items asynchronously; look once they have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.checkFit() }
    }

    /// Back to separate items (in automatic mode) and look again whether they fit.
    private func retryLayout() {
        MenuBarLayoutStatus.shared.autoCombined = false
        reload()
    }

    /// Counts items macOS could not show. Items that do not fit are piled up at one spot next to the
    /// notch (on top of each other) or moved under it; on a screen without a notch they leave the screen.
    private func checkFit() {
        let debug = ProcessInfo.processInfo.environment["ACTIVITYPLUS_DEBUG_MENUBAR"] != nil
        if let combined {
            let hidden = Self.isHidden(combined, among: [])
            if debug { NSLog("menubar fit: combined (%d values) window %@ hidden %d", combinedLimit, combined.button?.window.map { NSStringFromRect($0.frame) } ?? "none", hidden ? 1 : 0) }
            // Even one item is too wide: show fewer values until it fits; the panel has them all.
            if hidden, combinedLimit > 1 {
                combinedLimit = max(1, combinedLimit / 2)
                MenuBarLayoutStatus.shared.combinedShowing = combinedLimit
                refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.checkFit() }
            }
            return
        }
        let shown = entries.map(\.item).filter(\.isVisible)   // items below their threshold are hidden on purpose
        let hidden = shown.filter { Self.isHidden($0, among: shown) }.count
        MenuBarLayoutStatus.shared.hidden = hidden
        if debug {
            for entry in entries {
                NSLog("menubar fit: %@ window %@", entry.config.module.title, entry.item.button?.window.map { NSStringFromRect($0.frame) } ?? "none")
            }
            NSLog("menubar fit: %d hidden", hidden)
        }
        if hidden > 0, MenuBarLayout.current == .automatic {
            MenuBarLayoutStatus.shared.autoCombined = true
            reload()
        }
    }

    static func isHidden(_ item: NSStatusItem, among others: [NSStatusItem]) -> Bool {
        guard let window = item.button?.window else { return true }
        let frame = window.frame
        guard let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return true }
        if frame.maxX <= screen.frame.minX || frame.minX >= screen.frame.maxX { return true }
        if let right = screen.auxiliaryTopRightArea {
            // The area right of the notch; read as global or as screen-relative, whichever lies on this screen.
            let notchEnd = right.minX >= screen.frame.minX ? right.minX : screen.frame.minX + right.minX
            if frame.minX < notchEnd { return true }
        }
        // Placed items sit side by side; ones that did not fit share a spot with another.
        return others.contains { other in
            guard other !== item, let otherFrame = other.button?.window?.frame else { return false }
            let overlap = frame.intersection(otherFrame).width
            return overlap > min(frame.width, otherFrame.width) / 2
        }
    }

    func refresh(onlyClocks: Bool = false) {
        let monitor = Monitor.shared
        let services = AppServices.shared
        let strained = monitor.isUnderStrain && UserDefaults.standard.object(forKey: "menuBarWarnWhenStrained") as? Bool ?? true
        if let combined {
            refreshCombined(combined, strained: strained)
            return
        }
        for (index, entry) in entries.enumerated() {
            guard let button = entry.item.button else { continue }
            if onlyClocks && entry.config.module != .clock { continue }
            let reading = ModuleReading.read(entry.config, monitor: monitor, services: services)
            let hide = entry.config.hideBelowPercent > 0 && reading.percentOfScale < entry.config.hideBelowPercent && !strained
            entry.item.isVisible = !hide
            guard !hide else { continue }
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let monochrome = entry.config.colorMode == .monochrome
            // Monochrome items are template images: macOS tints them for light, dark and highlighted bars.
            let ink: Color = monochrome ? .black : (dark ? .white : .black)
            // The first item warns while the Mac struggles: an icon becomes the warning sign, others get one in front.
            let warn = strained && index == 0
            if warn && entry.config.style == .icon {
                button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Your Mac is under strain")
                button.image?.isTemplate = true
            } else {
                let image = Self.render(MenuBarWidget(config: entry.config, reading: reading, ink: ink, showWarning: warn))
                image.isTemplate = monochrome
                button.image = image
            }
        }
    }

    /// All items side by side in one image; each item's width is remembered so a click opens its tab.
    private func refreshCombined(_ item: NSStatusItem, strained: Bool) {
        guard let button = item.button else { return }
        let monitor = Monitor.shared, services = AppServices.shared
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let allMonochrome = configs.allSatisfy { $0.colorMode == .monochrome }
        let ink: Color = allMonochrome ? .black : (dark ? .white : .black)
        var parts: [(tab: MenuBarPanel.Tab, image: NSImage)] = []
        for (index, config) in configs.enumerated() where parts.count < combinedLimit {
            let reading = ModuleReading.read(config, monitor: monitor, services: services)
            if config.hideBelowPercent > 0 && reading.percentOfScale < config.hideBelowPercent && !strained { continue }
            parts.append((config.module.panelTab, Self.render(MenuBarWidget(config: config, reading: reading, ink: ink, showWarning: strained && index == 0))))
        }
        if parts.isEmpty, let config = configs.first {
            parts = [(config.module.panelTab, Self.render(MenuBarWidget(config: config, reading: ModuleReading.read(config, monitor: monitor, services: services), ink: ink)))]
        }
        let gap: CGFloat = 7
        let width = parts.reduce(0) { $0 + $1.image.size.width } + gap * CGFloat(max(0, parts.count - 1))
        let height = parts.map(\.image.size.height).max() ?? 18
        var x: CGFloat = 0
        var newSegments: [(tab: MenuBarPanel.Tab, minX: CGFloat, maxX: CGFloat)] = []
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var cursor: CGFloat = 0
            for part in parts {
                part.image.draw(in: NSRect(x: cursor, y: (height - part.image.size.height) / 2, width: part.image.size.width, height: part.image.size.height))
                cursor += part.image.size.width + gap
            }
            return true
        }
        for part in parts {
            newSegments.append((part.tab, x, x + part.image.size.width + gap / 2))
            x += part.image.size.width + gap
        }
        segments = newSegments
        image.isTemplate = allMonochrome
        button.image = image
    }

    static func render<V: View>(_ view: V) -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage()
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if let combined, combined.button === sender {
            if NSApp.currentEvent?.type == .rightMouseUp {
                showMenu(for: combined)
            } else {
                // Open the tab of the value under the pointer.
                let x = NSApp.currentEvent.map { sender.convert($0.locationInWindow, from: nil).x } ?? 0
                let tab = segments.first { x >= $0.minX && x < $0.maxX }?.tab ?? segments.last?.tab ?? .overview
                togglePopover(from: sender, tab: tab)
            }
            return
        }
        guard let entry = entries.first(where: { $0.item.button === sender }) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(for: entry.item)
        } else {
            togglePopover(from: sender, tab: entry.config.module.panelTab)
        }
    }

    private func togglePopover(from button: NSStatusBarButton, tab: MenuBarPanel.Tab) {
        if popover.isShown, popoverButton === button {
            popover.performClose(nil)
            return
        }
        popover.performClose(nil)
        let panel = MenuBarPanel(initialTab: tab, close: { [weak self] in self?.popover.performClose(nil) })
            .environment(Monitor.shared)
            .environment(AppServices.shared)
        popover.contentViewController = NSHostingController(rootView: panel)
        popoverButton = button
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu(for item: NSStatusItem) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Activity+", action: #selector(openMain), keyEquivalent: "o").target = self
        if let recording = AppServices.shared.recording {
            let stop = NSMenuItem(title: "Stop Recording \"\(recording.name)\" (\(Format.elapsed(recording.duration)))", action: #selector(toggleRecording), keyEquivalent: "")
            stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            stop.target = self
            menu.addItem(stop)
        } else {
            let start = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
            start.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            start.target = self
            menu.addItem(start)
        }
        menu.addItem(.separator())

        // Quick choice of what the menu bar shows; finer control lives in Settings → Menu Bar.
        let shown = Set(configs.map(\.module))
        let header = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for module in MenuBarItemConfig.Module.allCases where module != .status {
            let entry = NSMenuItem(title: module.title, action: #selector(toggleModule(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = module.rawValue
            entry.state = shown.contains(module) ? .on : .off
            entry.image = NSImage(systemSymbolName: module.systemImage, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        let symbols = NSMenuItem(title: "Symbols Next to Values", action: #selector(toggleSymbols), keyEquivalent: "")
        symbols.target = self
        symbols.state = configs.contains(where: \.showIcon) ? .on : .off
        menu.addItem(symbols)
        let presets = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        let presetMenu = NSMenu()
        for preset in MenuBarItemConfig.Preset.allCases {
            let entry = NSMenuItem(title: preset.title, action: #selector(applyPreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.rawValue
            presetMenu.addItem(entry)
        }
        presets.submenu = presetMenu
        menu.addItem(presets)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Customize Menu Bar…", action: #selector(openMenuBarSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Activity+", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil   // keep left clicks opening the popover
    }

    @objc private func openMain() { WindowOpener.openMain() }
    @objc private func toggleRecording() {
        let services = AppServices.shared
        if services.recording != nil { services.stopRecording() } else { services.startRecording(name: "") }
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let module = MenuBarItemConfig.Module(rawValue: raw) else { return }
        var items = MenuBarItemStore.load()
        if items.contains(where: { $0.module == module }) {
            items.removeAll { $0.module == module }
            // Never end up with an empty menu bar: Activity+ would become unreachable.
            if items.isEmpty { items = [.quick(.status)] }
        } else {
            items.removeAll { $0.module == .status }
            items.append(.quick(module))
        }
        MenuBarItemStore.save(items)
    }

    @objc private func toggleSymbols() {
        var items = MenuBarItemStore.load()
        let on = !items.contains(where: \.showIcon)
        for index in items.indices { items[index].showIcon = on }
        MenuBarItemStore.save(items)
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = MenuBarItemConfig.Preset(rawValue: raw) else { return }
        MenuBarItemStore.save(preset.items)
    }
    @objc private func openMenuBarSettings() { WindowOpener.openSettings(tab: "menuBar") }
    @objc private func quit() { NSApp.terminate(nil) }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // drop the panel so it stops re-rendering
    }
}

/// Opening windows from AppKit code (status items, notifications) in a SwiftUI-lifecycle app.
@MainActor
enum WindowOpener {
    /// Captured from any live SwiftUI view; SwiftUI's openWindow works app-wide once obtained.
    static var openWindow: OpenWindowAction?
    static var openSettingsAction: OpenSettingsAction?

    static func openMain(page: String? = nil) {
        if let page { AppServices.shared.requestedPage = page }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Activity+" }), window.contentView != nil {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
    }

    static func openSettings(tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") }
        NSApp.activate()
        if let openSettingsAction { openSettingsAction() } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

/// An invisible view that hands SwiftUI's window actions to `WindowOpener`.
struct WindowActionsCapture: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                WindowOpener.openWindow = openWindow
                WindowOpener.openSettingsAction = openSettings
            }
    }
}
