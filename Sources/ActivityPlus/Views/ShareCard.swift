import ActivityCore
import SwiftUI

/// A 1200 × 630 image of the current state, sized for social posts.
struct ShareCard: View {
    let snapshot: SystemSnapshot
    let dark: Bool

    var body: some View {
        let apps = snapshot.apps.filter { $0.kind != .system }.sorted { $0.memory > $1.memory }.prefix(5)
        let top = Double(apps.first?.memory ?? 1)
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Activity+").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Text("\(Self.macModel) · \(SystemSampler.chipName.replacingOccurrences(of: "Apple ", with: ""))")
                    .font(.system(size: 24, weight: .medium))
                Spacer()
                Text("Memory in use").font(.system(size: 24)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.split(Format.memory(snapshot.memory.used)).value)
                        .font(.system(size: 120, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(Format.split(Format.memory(snapshot.memory.used)).unit + " of " + Format.memory(snapshot.memory.total))
                        .font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                HStack(spacing: 34) {
                    figure("CPU", Format.percent(snapshot.cpu.total))
                    if let gpu = snapshot.gpu { figure("GPU", Format.percent(gpu.utilization)) }
                    figure("Apps", "\(snapshot.apps.count)")
                    figure("Processes", "\(snapshot.processCount)")
                }
            }
            .frame(width: 560, alignment: .leading)

            VStack(alignment: .leading, spacing: 22) {
                Text("Using the most memory").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(apps)) { app in
                    HStack(spacing: 14) {
                        Image(nsImage: IconCache.icon(for: app)).resizable().frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(app.name).font(.system(size: 22, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(Format.memory(app.memory)).font(.system(size: 22)).monospacedDigit()
                            }
                            GeometryReader { proxy in
                                Capsule().fill(Color.purple.gradient)
                                    .frame(width: max(6, proxy.size.width * Double(app.memory) / top))
                            }
                            .frame(height: 8)
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(56)
        .frame(width: 1200, height: 630)
        .foregroundStyle(dark ? Color.white : Color.black, dark ? Color.white.opacity(0.6) : Color.black.opacity(0.55))
        .background(dark ? Color(white: 0.09) : Color(white: 0.97))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 18)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    /// "MacBookPro18,4" → "MacBook Pro". Newer models report "Mac15,3", which says nothing, so those become "Mac".
    static var macModel: String {
        let model = Sys_model
        let names = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("Macmini", "Mac mini"),
                     ("iMac", "iMac"), ("MacStudio", "Mac Studio"), ("MacPro", "Mac Pro")]
        return names.first { model.hasPrefix($0.0) }?.1 ?? "Mac"
    }

    private static var Sys_model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    @MainActor static func export(_ snapshot: SystemSnapshot, dark: Bool) -> URL? {
        guard let png = pngData(snapshot, dark: dark) else { return nil }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let url = downloads.appendingPathComponent("Activity+ \(stamp)\(dark ? " dark" : "").png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    /// Renders through CGImage: going via NSImage/TIFF lost contrast in the dark variant.
    @MainActor static func pngData(_ snapshot: SystemSnapshot, dark: Bool) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(snapshot: snapshot, dark: dark))
        renderer.scale = 2
        renderer.isOpaque = true
        guard let rendered = renderer.cgImage else { return nil }
        // On XDR displays the renderer produces a 16-bit HDR (PQ) image, which most viewers and social
        // sites show with grey whites. Redraw into plain 8-bit sRGB before encoding.
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Copies the main window as an image.
    @MainActor static func copyDashboard() {
        guard let view = NSApp.windows.first(where: { $0.title == "Activity+" })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
