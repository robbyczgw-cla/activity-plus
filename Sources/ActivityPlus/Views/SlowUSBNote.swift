import ActivityCore
import SwiftUI

/// A warning on the Disk page when a USB drive runs slower than it could.
struct SlowUSBNote: View {
    @State private var slow: [USBLinkCheck.SlowLink] = []

    var body: some View {
        Group {
            if !slow.isEmpty {
                Card {
                    CardHeader(title: "Slower than it could be", systemImage: "cable.connector", tint: .orange)
                    ForEach(slow) { link in
                        StatLine(label: link.name, value: String(localized: "\(link.connected), can do \(link.supports)"))
                    }
                    Text("The drive can do USB 3 but is connected at USB 2 speed. Usually the cable only does USB 2 (charging cables often do), or a hub or port in between does. Try another cable or plug it straight into the Mac.")
                        .appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            // Drives come and go; look again every 10 seconds while the page is open.
            while !Task.isCancelled {
                slow = await Task.detached(priority: .utility) { USBLinkCheck.slowStorage() }.value
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
