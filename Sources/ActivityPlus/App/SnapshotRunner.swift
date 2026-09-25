import AppKit
import SwiftUI

/// Debug aid: `ACTIVITYPLUS_SNAPSHOTS=/some/dir open Activity+.app` renders every page of the main
/// window (and the menu bar panel) to PNG files, then quits. Uses the app's own view hierarchy,
/// so it needs no screen-recording permission. Used to check layouts before committing.
@MainActor
enum SnapshotRunner {
    static let selectNotification = Notification.Name("ActivityPlusSelectPage")
    static var isActive: Bool { ProcessInfo.processInfo.environment["ACTIVITYPLUS_SNAPSHOTS"] != nil }

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["ACTIVITYPLUS_SNAPSHOTS"] else { return }
        // ACTIVITYPLUS_APPEARANCE=dark|light renders marketing shots in one consistent look.
        switch ProcessInfo.processInfo.environment["ACTIVITYPLUS_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let pages = (ProcessInfo.processInfo.environment["ACTIVITYPLUS_PAGES"] ?? "overview,metric:cpu,metric:memory,metric:gpu,metric:disk,metric:network,metric:energy,battery,sensors,projects,history,alerts,sound,diagnosis,startup,storage,weekly,automations,sleep,connections")
            .split(separator: ",").map(String.init)
        let warmup = Double(ProcessInfo.processInfo.environment["ACTIVITYPLUS_WARMUP"] ?? "12") ?? 12
        Task { @MainActor in
            // Long-running scans start right away so their results are on screen by snapshot time.
            if pages.contains("storage") { AppServices.shared.scanStorage() }
            if pages.contains("startup") || pages.contains("diagnosis") { AppServices.shared.scanStartupItems() }
            try? await Task.sleep(for: .seconds(warmup))
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for window in NSApp.windows {
                NSLog("snapshot window: title=%@ id=%@ class=%@ visible=%d size=%@", window.title, window.identifier?.rawValue ?? "-",
                      String(describing: type(of: window)), window.isVisible ? 1 : 0, NSStringFromSize(window.frame.size))
            }
            NSLog("snapshot statusItems: %d configured, %d NSStatusBarWindows", MenuBarItemStore.load().count,
                  NSApp.windows.filter { String(describing: type(of: $0)) == "NSStatusBarWindow" }.count)
            for page in pages {
                NotificationCenter.default.post(name: selectNotification, object: page)
                try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["ACTIVITYPLUS_PAGE_WAIT"] ?? "2") ?? 2))
                if let window = NSApp.windows.first(where: { $0.title == "Activity+" || $0.identifier?.rawValue.contains("main") == true }),
                   let view = window.contentView {
                    save(view, to: "\(dir)/\(page.replacingOccurrences(of: ":", with: "-")).png")
                }
            }
            let previousTab = UserDefaults.standard.string(forKey: "menuBarPanelTab")
            for tab in MenuBarPanel.Tab.allCases {
                UserDefaults.standard.set(tab.rawValue, forKey: "menuBarPanelTab")
                snapshotPanel(to: "\(dir)/menubar-\(tab.rawValue).png")
            }
            UserDefaults.standard.set(previousTab ?? MenuBarPanel.Tab.overview.rawValue, forKey: "menuBarPanelTab")
            for dark in [false, true] { snapshotWidgetGallery(dark: dark, to: "\(dir)/widgets-\(dark ? "dark" : "light").png") }
            let previousSettingsTab = UserDefaults.standard.string(forKey: "settingsTab")
            for tab in ["general", "menuBar", "panel", "window", "units", "performance", "updates"] {
                UserDefaults.standard.set(tab, forKey: "settingsTab")
                snapshotHosted(SettingsView(), size: NSSize(width: 640, height: 620), to: "\(dir)/settings-\(tab).png")
            }
            UserDefaults.standard.set(previousSettingsTab ?? "general", forKey: "settingsTab")
            for dark in [false, true] {
                if let png = ShareCard.pngData(Monitor.shared.snapshot, dark: dark) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/sharecard-\(dark ? "dark" : "light").png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Every module in every style it supports, as the menu bar would draw it.
    private static func snapshotWidgetGallery(dark: Bool, to path: String) {
        let ink: Color = dark ? .white : .black
        let gallery = VStack(alignment: .leading, spacing: 6) {
            ForEach(MenuBarItemConfig.Module.allCases) { module in
                HStack(spacing: 14) {
                    Text(module.title).font(.caption).frame(width: 90, alignment: .leading).foregroundStyle(ink)
                    ForEach(module.styles) { style in
                        let config: MenuBarItemConfig = {
                            var c = MenuBarItemConfig(module: module, style: style)
                            c.showLabel = style != .text
                            c.colorMode = [.ring, .gauge, .dot, .battery, .coreBars].contains(style) ? .byLevel : .monochrome
                            return c
                        }()
                        MenuBarWidget(config: config, reading: ModuleReading.read(config, monitor: Monitor.shared, services: AppServices.shared), ink: ink)
                    }
                }
            }
        }
        .padding(12)
        .background(dark ? Color(white: 0.15) : Color(white: 0.93))
        snapshotHosted(gallery, size: nil, to: path)
    }

    private static func snapshotHosted<V: View>(_ view: V, size: NSSize?, to path: String) {
        let host = NSHostingView(rootView: view.environment(Monitor.shared).environment(AppServices.shared))
        host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        save(host, to: path)
    }

    private static func snapshotPanel(to path: String) {
        let host = NSHostingView(rootView: MenuBarPanel()
            .environment(Monitor.shared)
            .environment(AppServices.shared)
            .background(.windowBackground))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        save(host, to: path)
    }

    /// Always renders at 2× so screenshots stay sharp even when the Mac drives a 1× display.
    private static func save(_ view: NSView, to path: String) {
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
