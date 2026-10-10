import ActivityCore
import AppKit
import SwiftUI

/// Shows when Spotlight is building its search index, what that costs right now, and offers a rebuild.
/// While it is idle it is a single quiet line.
struct SpotlightCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var volumes: [SpotlightStatus.Volume]?
    @State private var lastBusy: Date?
    @State private var confirmRebuild = false
    @State private var rebuildStarted = false
    @State private var errorMessage: String?

    private var status: SpotlightStatus {
        var s = SpotlightStatus()
        s.volumes = volumes ?? []
        let usage = SpotlightStatus.usage(of: monitor.snapshot.apps.flatMap(\.processes))
        s.cpuPercent = usage.cpu; s.diskRate = usage.disk; s.processCount = usage.count
        return s
    }

    var body: some View {
        let status = status
        // Keep the card for half a minute after the load drops: Spotlight works in bursts.
        let busy = status.isIndexing || (lastBusy.map { Date().timeIntervalSince($0) < 30 } ?? false)
        Group {
            if volumes == nil {
                Color.clear.frame(height: 0)
            } else if busy {
                card(status)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle").foregroundStyle(.secondary)
                    Group { if status.indexedVolumes.isEmpty { Text("Spotlight indexing is turned off") } else { Text("Spotlight index: up to date") } }
                        .appFont(.callout).foregroundStyle(.secondary)
                    if rebuildStarted { Text("· a rebuild was started and runs in the background").appFont(.callout).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 4)
            }
        }
        .onChange(of: status.isIndexing) { _, now in if !now { lastBusy = Date() } }
        .task {
            while !Task.isCancelled {
                let read = await Task.detached(priority: .utility) { SpotlightStatus.readVolumes() }.value
                volumes = read
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .confirmationDialog("Rebuild the Spotlight index?", isPresented: $confirmRebuild) {
            Button("Rebuild the Index", role: .destructive) { rebuild() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Spotlight throws away its index of your startup disk and builds it again from scratch. This needs an administrator password and takes hours. Meanwhile search is incomplete and the Mac works harder. Only do this when search is clearly broken: indexing that is running now is normal and ends by itself.")
        }
        .alert("The index was not rebuilt", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
    }

    private func card(_ status: SpotlightStatus) -> some View {
        Card {
            CardHeader(title: status.indexingTitle, systemImage: "magnifyingglass", tint: .blue)
            Text("Spotlight is reading new or changed files so search can find them. This is normal after an update or after many files changed, and it ends by itself. Meanwhile the Mac may feel slower and the fans may run.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Root processes often report no disk numbers; leave the figure out rather than show 0.
            Group {
                if status.diskRate > 0 {
                    Text("Now: \(Format.percent(status.cpuPercent)) CPU, \(Format.rate(status.diskRate)) disk, \(status.processCount) Spotlight processes")
                } else {
                    Text("Now: \(Format.percent(status.cpuPercent)) CPU across \(status.processCount) Spotlight processes")
                }
            }
            .appFont(.callout).monospacedDigit()
            HStack {
                Button("Rebuild the index…") { confirmRebuild = true }
                    .help("Only for a broken search: needs an administrator password and takes hours")
                Spacer()
            }
        }
    }

    /// Runs only after the confirmation dialog. macOS asks for the administrator password itself.
    private func rebuild() {
        var error: NSDictionary?
        _ = NSAppleScript(source: SpotlightStatus.rebuildAppleScript)?.executeAndReturnError(&error)
        if let error {
            // -128 is "User canceled": nothing went wrong.
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                errorMessage = (error[NSAppleScript.errorMessage] as? String) ?? String(localized: "macOS did not accept the command.")
            }
        } else {
            rebuildStarted = true
        }
    }
}
