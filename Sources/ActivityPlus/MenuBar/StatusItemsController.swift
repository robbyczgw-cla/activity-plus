import ActivityCore
import AppKit
import SwiftUI

/// Owns one NSStatusItem per configured menu bar item. SwiftUI's MenuBarExtra only supports a fixed
/// number of items, so this is plain AppKit: each item's look is a SwiftUI view rendered to an image.
@MainActor
final class StatusItemsController: NSObject, NSPopoverDelegate {
    static let shared = StatusItemsController()

    private var entries: [(config: MenuBarItemConfig, item: NSStatusItem)] = []
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
            MainActor.assumeIsolated { self?.reload() }
        }
        // The clock must tick even when sampling is slow.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.entries.contains(where: { $0.config.module == .clock }) else { return }
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
        var configs = MenuBarItemStore.load()
        // An app without any menu bar item could not be reached once its window is closed.
        if configs.isEmpty { configs = [MenuBarItemConfig(module: .status, style: .icon)] }
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
    }

    func refresh(onlyClocks: Bool = false) {
        let monitor = Monitor.shared
        let services = AppServices.shared
        let strained = monitor.isUnderStrain && UserDefaults.standard.object(forKey: "menuBarWarnWhenStrained") as? Bool ?? true
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

    static func render<V: View>(_ view: V) -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage()
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
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
        menu.addItem(.separator())

        // Quick choice of what the menu bar shows; finer control lives in Settings → Menu Bar.
        let shown = Set(entries.map(\.config.module))
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
        symbols.state = entries.contains(where: \.config.showIcon) ? .on : .off
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
