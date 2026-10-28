import ActivityCore
import AppKit
import SwiftUI
import WidgetData
import WidgetUI

/// SnapshotRunner's part for the desktop widgets: every widget size with live numbers, as PNGs
/// (widget-small-<metric>.png, widget-medium.png, widget-large.png, plus -dark, -vibrant, empty and stale
/// variants), so they can be checked without installing the extension.
@MainActor
enum WidgetSnapshots {
    /// macOS widget sizes in points.
    static let small = CGSize(width: 170, height: 170)
    static let medium = CGSize(width: 364, height: 170)
    static let large = CGSize(width: 364, height: 382)

    static func render(to dir: String) {
        let live = WidgetSnapshot(Monitor.shared.snapshot, icon: { WidgetPublisher.shared.iconPNG($0) })
        var stale = live
        stale.date = Date().addingTimeInterval(-3600)
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            for metric in WidgetMetric.allCases {
                save(MetricWidgetView(snapshot: live, metric: metric), size: small, dark: dark, to: "\(dir)/widget-small-\(metric.rawValue)\(suffix).png")
            }
            save(OverviewWidgetView(snapshot: live, large: false), size: medium, dark: dark, to: "\(dir)/widget-medium\(suffix).png")
            save(OverviewWidgetView(snapshot: live, large: true), size: large, dark: dark, to: "\(dir)/widget-large\(suffix).png")
        }
        save(MetricWidgetView(snapshot: live, metric: .cpu), size: small, dark: true, vibrant: true, to: "\(dir)/widget-small-cpu-vibrant.png")
        save(OverviewWidgetView(snapshot: live, large: true), size: large, dark: true, vibrant: true, to: "\(dir)/widget-large-vibrant.png")
        save(MetricWidgetView(snapshot: nil, metric: .cpu), size: small, dark: false, to: "\(dir)/widget-small-empty.png")
        save(OverviewWidgetView(snapshot: stale, large: false), size: medium, dark: false, to: "\(dir)/widget-medium-stale.png")
    }

    /// The widget on a plain desktop-like backdrop, with the system's widget background and margins.
    private static func save<V: View>(_ view: V, size: CGSize, dark: Bool, vibrant: Bool = false, to path: String) {
        let card = view
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(vibrant ? AnyShapeStyle(Color.white.opacity(0.08)) : AnyShapeStyle(.background))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.widgetVibrantPreview, vibrant)
            .padding(20)
            .background(vibrant ? Color(red: 0.16, green: 0.2, blue: 0.28) : (dark ? Color(white: 0.22) : Color(white: 0.82)))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: NSSize(width: size.width + 40, height: size.height + 40))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
