import ActivityCore
import AppKit

/// Quitting apps and processes. Callers always confirm with the user first.
enum ProcessActions {
    enum Outcome {
        case done
        case denied(String)
    }

    /// Asks GUI apps to quit normally (they can save documents); signals everything else.
    @discardableResult
    static func quit(_ app: AppGroup, force: Bool) -> Outcome {
        if let bundleID = app.bundleID {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if !running.isEmpty {
                for app in running { if force { app.forceTerminate() } else { app.terminate() } }
                if force { app.processes.forEach { _ = signal($0.pid, force: true) } }
                return .done
            }
        }
        // Children first, so parents do not respawn them.
        let ordered = app.processes.sorted { $0.pid > $1.pid }
        let failures = ordered.filter { !signal($0.pid, force: force) }
        if failures.count == ordered.count, !ordered.isEmpty {
            return .denied("macOS did not allow Activity+ to stop \(app.name). It belongs to another user or to the system.")
        }
        return .done
    }

    @discardableResult
    static func quit(_ process: ProcessSample, force: Bool) -> Outcome {
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            if force { app.forceTerminate() } else { app.terminate() }
            return .done
        }
        return signal(process.pid, force: force)
            ? .done
            : .denied("macOS did not allow Activity+ to stop \(process.name) (pid \(process.pid)).")
    }

    private static func signal(_ pid: pid_t, force: Bool) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    static func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// App icons are expensive to load; keep one per bundle path.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for app: AppGroup) -> NSImage {
        let key = app.bundlePath ?? app.processes.first?.path ?? app.id
        if let icon = icons[key] { return icon }
        let icon: NSImage
        if let path = app.bundlePath {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if app.kind == .system {
            icon = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) ?? NSImage()
        } else {
            icon = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil) ?? NSImage()
        }
        icons[key] = icon
        return icon
    }
}
