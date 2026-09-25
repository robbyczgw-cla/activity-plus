import AppKit
import Darwin
import Foundation

/// Beachball / "(Not Responding)" state, from the same WindowServer check Activity Monitor uses.
/// Symbols are loaded with dlopen/dlsym; a missing symbol disables the feature instead of crashing.
@MainActor
final class HangDetector {
    struct Hang: Identifiable, Hashable, Codable {
        let id: UUID
        let pid: pid_t
        let bundleID: String?
        let name: String
        let started: Date
        var ended: Date?
        var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }
    }

    private(set) var current: [pid_t: Hang] = [:]
    /// Finished hangs, newest first. Capped at 100 and written to Application Support.
    private(set) var recent: [Hang] = []
    var onHangEnded: ((Hang) -> Void)?

    /// Consecutive unresponsive polls. A hang starts only at 2.
    private var streaks: [pid_t: Int] = [:]
    private let storeURL: URL

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Activity+", isDirectory: true)
        storeURL = directory.appendingPathComponent("hangs.json")
        recent = Self.load(from: storeURL)
    }

    /// Called about every 2 seconds. Looks at regular GUI apps only.
    func poll() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var seen = Set<pid_t>()
        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            seen.insert(pid)
            guard let unresponsive = Self.isUnresponsive(pid: pid) else { continue }
            if unresponsive {
                let count = (streaks[pid] ?? 0) + 1
                streaks[pid] = count
                if count >= 2, current[pid] == nil {
                    current[pid] = Hang(
                        id: UUID(),
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                        started: Date(),
                        ended: nil
                    )
                }
            } else if streaks[pid] != nil || current[pid] != nil {
                streaks[pid] = nil
                finish(pid)
            }
        }
        for pid in Array(current.keys) where !seen.contains(pid) {
            streaks[pid] = nil
            finish(pid)
        }
        streaks = streaks.filter { seen.contains($0.key) }
    }

    /// Nil when WindowServer or `GetProcessForPID` is unavailable for this pid.
    static func isUnresponsive(pid: pid_t) -> Bool? {
        WindowServerUnresponsive.check(pid: pid)
    }

    private func finish(_ pid: pid_t) {
        guard var hang = current.removeValue(forKey: pid) else { return }
        hang.ended = Date()
        recent.insert(hang, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
        save()
        onHangEnded?(hang)
    }

    private func save() {
        let directory = storeURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(recent)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // History is best-effort; a full disk must not stop sampling.
        }
    }

    private static func load(from url: URL) -> [Hang] {
        guard let data = try? Data(contentsOf: url),
              let hangs = try? JSONDecoder().decode([Hang].self, from: data) else { return [] }
        return Array(hangs.prefix(100))
    }
}

/// Carbon `ProcessSerialNumber` (two `UInt32`s). File-scope so it can cross `@convention(c)`.
private struct HangProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

/// `CGSEventIsAppUnresponsive` + `GetProcessForPID`. All lookups are optional.
private enum WindowServerUnresponsive {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias UnresponsiveFn = @convention(c) (Int32, UnsafeRawPointer) -> UInt8
    private typealias GetProcessFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private struct API {
        let connection: Int32
        let isUnresponsive: UnresponsiveFn
        let getProcess: GetProcessFn
    }

    private static let api: API? = load()

    static func check(pid: pid_t) -> Bool? {
        guard pid > 0, let api else { return nil }
        var psn = HangProcessSerialNumber()
        let status = withUnsafeMutablePointer(to: &psn) { api.getProcess(pid, UnsafeMutableRawPointer($0)) }
        guard status == 0 else { return nil }
        guard psn.highLongOfPSN != 0 || psn.lowLongOfPSN != 0 else { return nil }
        let flag = withUnsafePointer(to: &psn) { api.isUnresponsive(api.connection, UnsafeRawPointer($0)) }
        return flag != 0
    }

    private static func load() -> API? {
        let coreGraphics = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        )
        let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        let hiServices = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )
        guard
            let isUnresponsive: UnresponsiveFn = symbol("CGSEventIsAppUnresponsive", coreGraphics, skyLight),
            let getProcess: GetProcessFn = symbol("GetProcessForPID", hiServices, coreGraphics),
            let connectionFn: ConnectionFn = symbol("CGSMainConnectionID", coreGraphics, skyLight)
                ?? symbol("_CGSDefaultConnection", coreGraphics, skyLight)
        else { return nil }
        let connection = connectionFn()
        guard connection != 0 else { return nil }
        return API(connection: connection, isUnresponsive: isUnresponsive, getProcess: getProcess)
    }

    private static func symbol<T>(_ name: String, _ first: UnsafeMutableRawPointer?, _ second: UnsafeMutableRawPointer?) -> T? {
        let found = dlsym(first, name) ?? dlsym(second, name) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        guard let found else { return nil }
        return unsafeBitCast(found, to: T.self)
    }
}
