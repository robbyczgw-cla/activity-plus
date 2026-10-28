import AppIntents
import SwiftUI
import WidgetData
import WidgetKit
import WidgetUI

// The widget extension (Contents/PlugIns/ActivityPlusWidgets.appex). It never samples: it shows the
// snapshot the app writes into the shared App Group container about once a minute.

@main
struct ActivityPlusWidgetBundle: WidgetBundle {
    var body: some Widget {
        MetricWidget()
        OverviewWidget()
    }
}

// MARK: - Configuration

enum MetricOption: String, AppEnum {
    case cpu, memory, gpu, disk, network, temperature, battery

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"
    static let caseDisplayRepresentations: [MetricOption: DisplayRepresentation] = [
        .cpu: "CPU",
        .memory: "Memory",
        .gpu: "GPU",
        .disk: "Disk",
        .network: "Network",
        .temperature: "Temperature",
        .battery: "Battery",
    ]

    var metric: WidgetMetric { WidgetMetric(rawValue: rawValue) ?? .cpu }
}

struct SelectMetricIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Metric"
    static let description = IntentDescription("Pick what the widget shows.")

    @Parameter(title: "Metric", default: .cpu)
    var metric: MetricOption

    init() {}
    init(metric: MetricOption) { self.metric = metric }
}

// MARK: - Timelines

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var metric: WidgetMetric = .cpu
}

/// One entry, refreshed every 15 minutes at the latest; the app asks for reloads in between.
/// A second entry marks the moment the numbers count as old, so a quit app shows as such.
private func makeTimeline(_ entry: SnapshotEntry) -> Timeline<SnapshotEntry> {
    var entries = [entry]
    if let snapshot = entry.snapshot, !snapshot.isStale(at: entry.date) {
        var stale = entry
        stale.date = snapshot.date.addingTimeInterval(WidgetSnapshot.staleAfter + 1)
        entries.append(stale)
    }
    return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(15 * 60)))
}

struct MetricProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    func snapshot(for configuration: SelectMetricIntent, in context: Context) async -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetStore.read() ?? .sample, metric: configuration.metric.metric)
    }

    func timeline(for configuration: SelectMetricIntent, in context: Context) async -> Timeline<SnapshotEntry> {
        makeTimeline(SnapshotEntry(date: Date(), snapshot: WidgetStore.read(), metric: configuration.metric.metric))
    }

    func recommendations() -> [AppIntentRecommendation<SelectMetricIntent>] {
        MetricOption.allCases.map { AppIntentRecommendation(intent: SelectMetricIntent(metric: $0), description: Text($0.metric.title)) }
    }
}

struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetStore.read() ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(makeTimeline(SnapshotEntry(date: Date(), snapshot: WidgetStore.read())))
    }
}

// MARK: - Widgets

struct MetricWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStore.metricKind, intent: SelectMetricIntent.self, provider: MetricProvider()) { entry in
            MetricWidgetView(snapshot: entry.snapshot, metric: entry.metric, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Metric")
        .description("One live figure: CPU, memory, GPU, disk, network, temperature or battery.")
        .supportedFamilies([.systemSmall])
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.overviewKind, provider: OverviewProvider()) { entry in
            OverviewWidgetLayout(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Overview")
        .description("CPU, memory, GPU and disk at a glance, with the busiest apps.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct OverviewWidgetLayout: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        OverviewWidgetView(snapshot: entry.snapshot, large: family == .systemLarge, now: entry.date)
    }
}
