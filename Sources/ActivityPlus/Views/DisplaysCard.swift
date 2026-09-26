import AppKit
import SwiftUI

/// What each display is actually doing: refresh rate, resolution, HDR, and a warning when a cable or
/// dock holds it below what it could do (the classic 30 Hz external monitor).
struct DisplayMode: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let refresh: Double
    let bestRefresh: Double
    let pixels: CGSize
    let looksLike: CGSize
    let hdr: Bool
    let variableRefresh: Bool
    let isBuiltIn: Bool

    /// Running noticeably below the best rate this display offers at the same resolution.
    var isHeldBack: Bool { bestRefresh - refresh > 5 || (!isBuiltIn && refresh > 0 && refresh <= 31) }

    static func current() -> [DisplayMode] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            // Built-in panels report 0 Hz for their mode; the screen knows the real rate.
            let refresh = mode.refreshRate > 0 ? mode.refreshRate : Double(screen.maximumFramesPerSecond)
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            let sameSize = modes.filter { $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight }
            let best = max(refresh, sameSize.map(\.refreshRate).max() ?? 0, mode.refreshRate > 0 ? 0 : Double(screen.maximumFramesPerSecond))
            return DisplayMode(
                id: id, name: screen.localizedName, refresh: refresh, bestRefresh: best,
                pixels: CGSize(width: mode.pixelWidth, height: mode.pixelHeight),
                looksLike: CGSize(width: mode.width, height: mode.height),
                hdr: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1,
                variableRefresh: screen.minimumRefreshInterval < screen.maximumRefreshInterval - 0.001,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }
}

struct DisplaysCard: View {
    @State private var displays = DisplayMode.current()

    var body: some View {
        Card {
            CardHeader(title: displays.count == 1 ? "Display" : "Displays", systemImage: "display.2", tint: .purple)
            ForEach(displays) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: d.isBuiltIn ? "laptopcomputer" : "display").foregroundStyle(.purple)
                        Text(d.name).fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.0f Hz", d.refresh)).monospacedDigit().foregroundStyle(d.isHeldBack ? .orange : .primary)
                    }
                    HStack(spacing: 14) {
                        Text("\(Int(d.pixels.width)) × \(Int(d.pixels.height)) pixels")
                        if d.looksLike != d.pixels { Text("looks like \(Int(d.looksLike.width)) × \(Int(d.looksLike.height))") }
                        if d.variableRefresh { Text("ProMotion / variable refresh") }
                        if d.hdr { Text("HDR") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if d.isHeldBack {
                        Label(d.bestRefresh - d.refresh > 5
                              ? String(format: "Running at %.0f Hz, %.0f Hz is available at this resolution. Check the cable, adapter or dock, or pick the rate in System Settings → Displays.", d.refresh, d.bestRefresh)
                              : String(format: "Only %.0f Hz: often a cable or adapter that cannot carry more at this resolution.", d.refresh),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayMode.current()
        }
    }
}
