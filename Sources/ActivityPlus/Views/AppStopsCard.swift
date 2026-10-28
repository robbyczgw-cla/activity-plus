import ActivityCore
import SwiftUI

/// Apps and background services macOS ended on its own in the last 24 hours, from the system log.
struct AppStopsCard: View {
    @Environment(AppServices.self) private var services
    private var diagnosis = BackgroundDiagnosis.shared
    @State private var groups: [AppStops.Group] = []
    @State private var loaded = false
    @State private var showAll = false

    var body: some View {
        Card {
            CardHeader(title: "Apps macOS stopped", systemImage: "xmark.octagon", tint: .red,
                       trailing: diagnosis.checkingStops ? String(localized: "reading the system log…") : String(localized: "last 24 h"))
            Text("Apps and background services that macOS ended on its own, for example for using too much memory. Activity+ reads them from the system log every 30 minutes, without admin rights.")
                .appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loaded && groups.isEmpty {
                if diagnosis.stopsCheckedAt == nil {
                    Text(diagnosis.checkingStops
                         ? String(localized: "Reading the last 24 hours of the system log. The first time takes a few minutes; later looks only read what is new.")
                         : String(localized: "The system log has not been read yet."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("macOS did not stop any app in the last 24 hours.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            let rows = showAll ? groups : Array(groups.prefix(5))
            ForEach(rows) { group in
                Divider()
                row(group)
            }
            if groups.count > 5 {
                Button(showAll ? String(localized: "Show fewer") : String(localized: "Show all \(groups.count)")) { withAnimation(.snappy) { showAll.toggle() } }
                    .buttonStyle(.link)
            }
            HStack(spacing: 8) {
                if let checked = diagnosis.stopsCheckedAt {
                    Text("Last read \(checked.formatted(date: .omitted, time: .shortened))").appFont(.caption).foregroundStyle(.tertiary)
                }
                if diagnosis.stopsCheckFailed {
                    Text("The system log could not be read.").appFont(.caption).foregroundStyle(.orange)
                }
                Button("Read now") { diagnosis.checkStops() }
                    .buttonStyle(.link).appFont(.caption)
                    .disabled(diagnosis.checkingStops)
            }
            .padding(.top, 2)
        }
        .task(id: diagnosis.revision) { await load() }
    }

    private func row(_ group: AppStops.Group) -> some View {
        let first = group.stops[0]
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = BackgroundDiagnosis.icon(first) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: first.kind == .service ? "gearshape.2" : "app.dashed").appFont(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).fontWeight(.semibold)
                Text(Self.summary(group)).appFont(.callout).fixedSize(horizontal: false, vertical: true)
                Text(group.stops.prefix(8).map { $0.date.formatted(date: .omitted, time: .shortened) }.joined(separator: ", ")
                     + (group.stops.count > 8 ? " …" : ""))
                    .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(first.explanation).appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    /// "Stopped 3 times for using too much memory" / "A web page was stopped …".
    static func summary(_ group: AppStops.Group) -> String {
        let first = group.stops[0]
        let count = group.stops.count
        if let helper = BackgroundDiagnosis.helperNote(first) {
            return count == 1
                ? String(localized: "macOS stopped \(helper) \(first.reasonPhrase).")
                : String(localized: "macOS stopped \(helper) \(count) times \(first.reasonPhrase).")
        }
        return count == 1
            ? String(localized: "Stopped \(first.reasonPhrase).")
            : String(localized: "Stopped \(count) times \(first.reasonPhrase).")
    }

    private func load() async {
        let store = services.history
        let stops = await Task.detached(priority: .utility) { store.appStops(since: Date().addingTimeInterval(-86_400)) }.value
        groups = AppStops.grouped(stops) { BackgroundDiagnosis.displayName($0) }
        loaded = true
    }
}
