import ActivityCore
import SwiftUI

/// Shown at the top of the Overview, only while the microphone or a camera is on.
struct PrivacyBanner: View {
    private var privacy = PrivacyIndicators.shared

    var body: some View {
        Group {
            if privacy.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    if !privacy.microphone.isEmpty {
                        row(symbol: "mic.fill", tint: .orange, apps: privacy.microphone) { names in
                            Text("Microphone in use by \(names)")
                        }
                    }
                    if privacy.cameraInUse {
                        let device = privacy.cameraDevices.first ?? ""
                        row(symbol: "video.fill", tint: .green, apps: privacy.camera) { names in
                            if privacy.camera.isEmpty {
                                Text("Camera in use (\(device))")
                            } else {
                                Text("Camera in use, probably by \(names)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            }
        }
        .onAppear { privacy.retain() }
        .onDisappear { privacy.release() }
    }

    private func row<Label: View>(symbol: String, tint: Color, apps: [AppRef], @ViewBuilder label: (String) -> Label) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            label(apps.map(\.name).formatted(.list(type: .and)))
                .fontWeight(.medium)
            Spacer(minLength: 8)
            HStack(spacing: -6) {
                ForEach(apps.prefix(3)) { app in
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                }
            }
        }
    }
}

/// Time Machine: when the last backup finished, or how far a running one is.
struct BackupCard: View {
    private var watcher = BackupWatcher.shared

    var body: some View {
        Card {
            CardHeader(title: "Backup", systemImage: "externaldrive.badge.timemachine", tint: tint)
            content
        }
        .onAppear { watcher.cardAppeared() }
        .onDisappear { watcher.cardDisappeared() }
    }

    /// Hidden on the Overview when Time Machine is not set up.
    static func isRelevant(_ info: TimeMachineInfo?) -> Bool {
        guard let info else { return false }
        return info.needsFullDiskAccess || !info.destinations.isEmpty
    }

    private var tint: Color {
        guard let info = watcher.info, !info.needsFullDiskAccess else { return .secondary }
        if info.progress.running { return .blue }
        return TimeMachine.isStale(info, days: 3) ? .orange : .green
    }

    @ViewBuilder private var content: some View {
        if let info = watcher.info {
            if info.needsFullDiskAccess {
                Text("Activity+ can't read the backup status. Allow it under System Settings, Privacy & Security, Full Disk Access.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if info.destinations.isEmpty {
                Text("Time Machine is not set up.").foregroundStyle(.secondary)
            } else if info.progress.running {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backing up to \(destinationName(info))").fontWeight(.medium)
                    if let fraction = info.progress.fraction {
                        ProgressView(value: fraction)
                        Text("\(Int(fraction * 100)) % done").appFont(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                        Text(info.progress.phase.map { "\($0)…" } ?? "Starting…").appFont(.callout).foregroundStyle(.secondary)
                    }
                }
            } else if let last = info.lastBackup {
                let days = TimeMachine.daysSince(last)
                VStack(alignment: .leading, spacing: 4) {
                    if days >= 3 {
                        Text("No backup for \(days) days").fontWeight(.medium).foregroundStyle(.orange)
                    } else {
                        Text("Last backup \(last.formatted(.relative(presentation: .numeric, unitsStyle: .wide))) to \(destinationName(info))")
                            .fontWeight(.medium)
                    }
                    Text(detail(info, last: last, days: days)).appFont(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("No backup has finished yet to \(destinationName(info)).").foregroundStyle(.secondary)
            }
        } else {
            Text("Checking…").foregroundStyle(.secondary)
        }
    }

    private func destinationName(_ info: TimeMachineInfo) -> String { info.destinations.first?.name ?? "Time Machine" }

    private func detail(_ info: TimeMachineInfo, last: Date, days: Int) -> String {
        var parts: [String] = []
        if days >= 3 { parts.append(String(localized: "Last backup to \(destinationName(info)) on \(last.formatted(date: .abbreviated, time: .shortened))")) }
        else { parts.append(last.formatted(date: .abbreviated, time: .shortened)) }
        if !info.destinationReachable { parts.append(String(localized: "Backup disk not connected")) }
        return parts.joined(separator: " · ")
    }
}

/// FileVault, SIP, Gatekeeper and the firewall: green when on, orange when not.
struct SecurityCard: View {
    private var model = SecurityModel.shared

    var body: some View {
        Card {
            CardHeader(title: "Security", systemImage: "lock.shield", tint: allGood ? .green : .orange)
            if model.checks.isEmpty {
                Text("Checking…").foregroundStyle(.secondary)
            }
            ForEach(model.checks) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: check.level == .good ? "checkmark.circle.fill" : (check.level == .warning ? "exclamationmark.triangle.fill" : "questionmark.circle"))
                        .foregroundStyle(check.level == .good ? Color.green : (check.level == .warning ? Color.orange : Color.secondary))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(check.title).fontWeight(.medium)
                            Spacer()
                            Text(check.state).foregroundStyle(.secondary)
                        }
                        Text(check.detail).appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private var allGood: Bool { !model.checks.isEmpty && model.checks.allSatisfy { $0.level == .good } }
}

/// The two cards under the Overview grid. Backup disappears when Time Machine is not set up.
struct OverviewStatusCards: View {
    private var watcher = BackupWatcher.shared
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            if BackupCard.isRelevant(watcher.info) || watcher.info == nil { BackupCard() }
            SecurityCard()
        }
    }
}
