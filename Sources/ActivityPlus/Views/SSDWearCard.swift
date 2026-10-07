import ActivityCore
import AppKit
import SwiftUI

/// Which apps write the most to the internal SSD, and how long it lasts at this pace.
struct SSDWearCard: View {
    @Environment(AppServices.self) private var services
    let drive: DriveInfo?
    @State private var daily: (bytesPerDay: Double, coveredDays: Double) = (0, 0)
    @State private var writers: [HistoryStore.AppWrites] = []
    @State private var countingSince: Date?

    var body: some View {
        Card {
            CardHeader(title: "What wears your SSD", systemImage: "internaldrive", tint: .brown, trailing: "last 30 days")
            if daily.bytesPerDay > 0 {
                StatLine(label: daily.coveredDays >= 6.5 ? "Written per day, last 7 days" : "Written per day so far",
                         value: Format.storage(UInt64(daily.bytesPerDay)))
            }
            if let health = drive?.nvmeHealth {
                if let projection = SSDWear.projection(percentUsed: health.percentageUsed, dataWrittenTB: health.dataWrittenTB,
                                                       bytesPerDay: daily.bytesPerDay) {
                    StatLine(label: "At this pace", value: years(projection.yearsLeft))
                    Text("The drive says \(health.percentageUsed ?? 0) % of its rated endurance is used after \(String(format: "%.0f", health.dataWrittenTB ?? 0)) TB written. Reaching 100 % does not mean it fails that day; it is the point the maker rates it for.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if health.percentageUsed == 0 {
                    Text("The drive reports less than 1 % of its rated endurance used, too little to project from.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            if writers.isEmpty {
                Text("Per-app writes are counted from version 0.3 on. The list fills up while Activity+ runs.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let top = writers.first?.bytes ?? 1
                ForEach(writers) { app in
                    HStack(spacing: 10) {
                        if let path = app.bundlePath {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "terminal").frame(width: 20, height: 20)
                        }
                        Text(app.name).lineLimit(1)
                        Spacer()
                        UsageBar(fraction: app.bytes / max(top, 1), tint: .brown).frame(width: 120)
                        Text(Format.storage(UInt64(app.bytes))).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    .font(.callout)
                }
                if let countingSince, Date().timeIntervalSince(countingSince) < 29 * 86_400 {
                    Text("Counted since \(countingSince.formatted(date: .abbreviated, time: .shortened)).").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .task {
            let store = services.history
            let result = await Task.detached(priority: .utility) {
                (store.dailyWrites(days: 7), store.topWriters(since: Date().addingTimeInterval(-30 * 86_400)))
            }.value
            daily = result.0
            writers = result.1.apps
            countingSince = result.1.countingSince
        }
    }

    private func years(_ value: Double) -> String {
        if value > 50 { return "more than 50 years" }
        if value >= 2 { return String(format: "about %.0f years", value) }
        if value >= 1 { return String(format: "about %.1f years", value) }
        return "under a year, check the apps below"
    }
}
