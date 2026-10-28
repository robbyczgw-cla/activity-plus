import ActivityCore
import SwiftUI

/// Moments of the last 7 days in which the Mac struggled for 20 seconds or more, with what caused them.
struct SlowMomentsCard: View {
    @Environment(AppServices.self) private var services
    private var diagnosis = BackgroundDiagnosis.shared
    /// Opens History at a moment.
    var open: (Date) -> Void
    @State private var moments: [SlowMoment] = []
    @State private var loaded = false
    @State private var showAll = false

    init(open: @escaping (Date) -> Void) { self.open = open }

    var body: some View {
        Card {
            CardHeader(title: "Slow moments", systemImage: "tortoise", tint: .orange,
                       trailing: loaded ? String(localized: "last 7 days") : String(localized: "reading…"))
            Text("Stretches of 20 seconds or more in which the Mac struggled while Activity+ was running: memory ran out, the processor or graphics were maxed out, it was too hot, an app froze, or the disk was saturated. Click one to see it in History.")
                .appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loaded && moments.isEmpty {
                Label("No slow moments in the last 7 days.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            let rows = showAll ? moments : Array(moments.prefix(6))
            ForEach(rows) { moment in
                Divider()
                Button { open(moment.start) } label: { row(moment) }
                    .buttonStyle(.plain)
                    .help("Show this moment in History")
            }
            if moments.count > 6 {
                Button(showAll ? String(localized: "Show fewer") : String(localized: "Show all \(moments.count)")) { withAnimation(.snappy) { showAll.toggle() } }
                    .buttonStyle(.link)
            }
        }
        .task(id: diagnosis.revision) { await load() }
    }

    private func row(_ moment: SlowMoment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Self.color(moment.severity)).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Self.when(moment.start)).fontWeight(.semibold).monospacedDigit()
                    Text("for \(SlowMoment.lengthText(moment.duration))").foregroundStyle(.secondary).monospacedDigit()
                    Text(moment.severity.label).appFont(.caption).foregroundStyle(Self.color(moment.severity))
                }
                ForEach(moment.causes) { cause in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cause.title).appFont(.callout)
                        if !cause.apps.isEmpty, cause.kind != .hang || cause.apps.count > 1 {
                            Text(cause.appsLine).appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").appFont(.caption).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .contentShape(Rectangle())
    }

    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today \(date.formatted(date: .omitted, time: .shortened))") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(date.formatted(date: .omitted, time: .shortened))") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func color(_ severity: SlowMoment.Severity) -> Color {
        switch severity {
        case .noticeable: .yellow
        case .bad: .orange
        case .severe: .red
        }
    }

    private func load() async {
        let store = services.history
        let result = await Task.detached(priority: .utility) { store.slowMoments(since: Date().addingTimeInterval(-7 * 86_400)) }.value
        moments = result
        loaded = true
    }
}
