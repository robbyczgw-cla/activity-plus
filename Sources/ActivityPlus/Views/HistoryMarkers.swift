import ActivityCore
import Charts
import SwiftUI

/// Slow moments and apps macOS stopped, drawn on the History chart and listed under it.
struct HistoryMarkers: Sendable {
    var moments: [SlowMoment] = []
    var stops: [AppStop] = []
    var isEmpty: Bool { moments.isEmpty && stops.isEmpty }

    static func load(_ store: HistoryStore, range: HistoryStore.Range) async -> HistoryMarkers {
        await Task.detached(priority: .utility) {
            let since = Date().addingTimeInterval(-range.seconds)
            return HistoryMarkers(moments: store.slowMoments(since: since), stops: store.appStops(since: since))
        }.value
    }

    @ChartContentBuilder var content: some ChartContent {
        ForEach(moments) { moment in
            RuleMark(x: .value("Slow moment", moment.start))
                .foregroundStyle(SlowMomentsCard.color(moment.severity).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .annotation(position: .top, spacing: 0) {
                    Image(systemName: "tortoise.fill").appFont(size: 9).foregroundStyle(SlowMomentsCard.color(moment.severity))
                }
        }
        ForEach(stops) { stop in
            RuleMark(x: .value("Stopped by macOS", stop.date))
                .foregroundStyle(.purple.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .annotation(position: .top, spacing: 0) {
                    Image(systemName: "xmark.octagon.fill").appFont(size: 9).foregroundStyle(.purple)
                }
        }
    }

    struct Entry: Identifiable {
        let id: String
        let date: Date
        let text: String
        let symbol: String
        let tint: Color
    }

    /// Newest first: "Slow moment, 2 min: Memory ran out", "Editor stopped for using too much memory".
    @MainActor var entries: [Entry] {
        let slow = moments.map { m in
            Entry(id: "m\(m.start.timeIntervalSince1970)", date: m.start,
                  text: String(localized: "Slow for \(SlowMoment.lengthText(m.duration)): \(m.causes.map(\.title).joined(separator: ", "))"),
                  symbol: "tortoise.fill", tint: SlowMomentsCard.color(m.severity))
        }
        let stopped = stops.map { s in
            let name = BackgroundDiagnosis.displayName(s)
            let text = BackgroundDiagnosis.helperNote(s).map { String(localized: "macOS stopped \($0) of \(name) \(s.reasonPhrase)") }
                ?? String(localized: "\(name) stopped \(s.reasonPhrase)")
            return Entry(id: "s\(s.id)", date: s.date, text: text, symbol: "xmark.octagon.fill", tint: .purple)
        }
        return (slow + stopped).sorted { $0.date > $1.date }
    }
}

/// The markers on the chart as a list; a click selects the moment on the chart.
struct HistoryMarkerList: View {
    let markers: HistoryMarkers
    var select: (Date) -> Void
    @State private var showAll = false

    var body: some View {
        if !markers.isEmpty {
            let entries = markers.entries
            VStack(alignment: .leading, spacing: 3) {
                Text("Marked on the chart").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                ForEach(showAll ? entries : Array(entries.prefix(5))) { entry in
                    Button { select(entry.date) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: entry.symbol).foregroundStyle(entry.tint).frame(width: 14)
                            Text(entry.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())).monospacedDigit().foregroundStyle(.secondary)
                                .frame(minWidth: 90, alignment: .leading)
                            Text(entry.text).lineLimit(1).truncationMode(.tail)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appFont(.callout)
                }
                if entries.count > 5 {
                    Button(showAll ? String(localized: "Show fewer") : String(localized: "Show all \(entries.count)")) { showAll.toggle() }
                        .buttonStyle(.link).appFont(.caption)
                }
            }
            .padding(.top, 6)
        }
    }
}
