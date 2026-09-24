import ActivityCore
import SwiftUI

/// The per-app figures every list can sort and display by.
enum Metric: String, CaseIterable, Identifiable, Codable {
    case cpu, memory, gpu, disk, network, energy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Energy"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .disk: "internaldrive"
        case .network: "network"
        case .energy: "bolt"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .blue
        case .memory: .purple
        case .gpu: .pink
        case .disk: .orange
        case .network: .teal
        case .energy: .green
        }
    }

    func value(_ app: AppGroup) -> Double {
        switch self {
        case .cpu: app.cpuPercent
        case .memory: Double(app.memory)
        case .gpu: app.gpuPercent
        case .disk: app.diskReadRate + app.diskWriteRate
        case .network: app.netInRate + app.netOutRate
        case .energy: app.powerWatts
        }
    }

    func value(_ process: ProcessSample) -> Double {
        switch self {
        case .cpu: process.cpuPercent
        case .memory: Double(process.memory)
        case .gpu: process.gpuPercent
        case .disk: process.diskReadRate + process.diskWriteRate
        case .network: process.netInRate + process.netOutRate
        case .energy: process.powerWatts
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu: Format.percent(value, decimals: value < 10 ? 1 : 0)
        case .memory: Format.memory(UInt64(max(0, value)))
        case .gpu: Format.percent(value, decimals: value < 10 ? 1 : 0)
        case .disk, .network: Format.rate(value)
        case .energy: Format.watts(value)
        }
    }

    /// What 100% of the bar means, so bars are comparable across rows.
    func scale(in snapshot: SystemSnapshot) -> Double {
        switch self {
        case .cpu: Double(max(1, snapshot.cpu.perCore.count)) * 100
        case .memory: Double(max(1, snapshot.memory.total))
        case .gpu: 100
        case .disk, .network, .energy:
            max(snapshot.apps.map(value).max() ?? 1, 0.000_1)
        }
    }
}
