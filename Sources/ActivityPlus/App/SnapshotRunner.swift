import AppKit
import SwiftUI

/// Debug aid: `ACTIVITYPLUS_SNAPSHOTS=/some/dir open Activity+.app` renders every page of the main
/// window (and the menu bar panel) to PNG files, then quits. Uses the app's own view hierarchy,
/// so it needs no screen-recording permission. Used to check layouts before committing.
@MainActor
enum SnapshotRunner {
    static let selectNotification = Notification.Name("ActivityPlusSelectPage")

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["ACTIVITYPLUS_SNAPSHOTS"] else { return }
        let pages = (ProcessInfo.processInfo.environment["ACTIVITYPLUS_PAGES"] ?? "overview,metric:cpu,metric:memory,metric:gpu,metric:disk,metric:network,metric:energy,battery,sensors,projects,history,alerts,sound,diagnosis,startup,storage")
            .split(separator: ",").map(String.init)
        let warmup = Double(ProcessInfo.processInfo.environment["ACTIVITYPLUS_WARMUP"] ?? "12") ?? 12
        Task { @MainActor in
            // Long-running scans start right away so their results are on screen by snapshot time.
            if pages.contains("storage") { AppServices.shared.scanStorage() }
            if pages.contains("startup") || pages.contains("diagnosis") { AppServices.shared.scanStartupItems() }
            try? await Task.sleep(for: .seconds(warmup))
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for page in pages {
                NotificationCenter.default.post(name: selectNotification, object: page)
                try? await Task.sleep(for: .seconds(2))
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
            for dark in [false, true] {
                if let png = ShareCard.pngData(Monitor.shared.snapshot, dark: dark) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/sharecard-\(dark ? "dark" : "light").png"))
                }
            }
            NSApp.terminate(nil)
        }
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

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
