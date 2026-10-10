import ActivityCore
import Foundation
import Observation

/// Owns the home folder's size map for the Explore and Biggest tabs. STUB — replaced by the real model; keep the API.
@MainActor @Observable
final class DiskIndexModel {
    enum State: Equatable {
        case idle
        case scanning(fraction: Double, item: String)
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var index: DiskIndex?
    /// Bumped whenever `index` changes (scan finished, items trashed), so views can refresh.
    private(set) var generation = 0

    func loadCachedIfNeeded() {}
    func scan() {}
    func cancel() {}
    /// Moves to the Trash (FileManager.trashItem), updates the map. Callers confirm first.
    func trash(_ urls: [URL]) -> (freed: UInt64, failures: [String: String]) { (0, [:]) }
}
