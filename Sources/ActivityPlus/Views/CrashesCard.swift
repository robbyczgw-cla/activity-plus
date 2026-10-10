import ActivityCore
import AppKit
import SwiftUI

/// Crash and freeze history read from the diagnostic reports; shared so the Diagnosis verdict can use it too.
@MainActor @Observable
final class CrashStore {
    static let shared = CrashStore()
    private(set) var summaries: [CrashSummary] = []
    private(set) var loaded = false

    func refresh() async {
        let result = await Task.detached(priority: .utility) { CrashReports.summarize(CrashReports.scan()) }.value
        summaries = result
        loaded = true
    }

    /// Opens a report in Console, which shows the readable crash log; falls back to the default app.
    static func show(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

struct CrashesCard: View {
    private var store = CrashStore.shared
    @State private var showAll = false

    var body: some View {
        Card {
            CardHeader(title: "Crashes and freezes", systemImage: "exclamationmark.bubble", tint: .orange,
                       trailing: store.loaded ? nil : "reading…")
            Text("Reports macOS writes when an app quits unexpectedly or stops responding, for the last 30 days. Reports written within seconds of each other count once.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.loaded && store.summaries.isEmpty {
                Label("No crashes or freezes in the last 30 days.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            let rows = showAll ? store.summaries : Array(store.summaries.prefix(5))
            ForEach(rows) { summary in
                Divider()
                CrashRow(summary: summary)
            }
            if store.summaries.count > 5 {
                Button(showAll ? "Show fewer" : "Show all \(store.summaries.count) apps") { withAnimation(.snappy) { showAll.toggle() } }
                    .buttonStyle(.link)
            }
        }
        .task { await store.refresh() }
    }
}

private struct CrashRow: View {
    let summary: CrashSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.appName).fontWeight(.semibold)
                if summary.crashes30 > 0 {
                    Text("Crashes: \(summary.crashes7) in 7 days, \(summary.crashes30) in 30 days").font(.callout).monospacedDigit()
                }
                if summary.hangs30 > 0 {
                    Text("Freezes: \(summary.hangs7) in 7 days, \(summary.hangs30) in 30 days").font(.callout).monospacedDigit()
                }
                Text("Last \(summary.lastKind == .hang ? String(localized: "freeze") : String(localized: "crash")): \(summary.lastDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(summary.lastReason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show report") { CrashStore.show(summary.latestReportPath) }
                .help("Opens the newest report in Console")
        }
    }

    @ViewBuilder private var icon: some View {
        if let id = summary.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").font(.title2).foregroundStyle(.secondary)
        }
    }
}
