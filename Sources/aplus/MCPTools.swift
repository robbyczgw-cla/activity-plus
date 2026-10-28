import ActivityCore
import AppKit
import Foundation

/// The MCP tools for the storage, health and privacy features. All of them are strictly read-only: they read the
/// app's cached size map, its scan summaries and history database, or ask macOS's own read-only tools. None scans
/// the disk for the map (a scan from another process could raise privacy prompts for the agent's host app), moves
/// anything to the Trash, runs `mdutil -E`, `launchctl` or a `tmutil` write, or opens the microphone or camera.
enum MCPTools {
    static let noMapMessage = "No map yet: open Activity+ → Storage → Explore and scan once."

    // MARK: Definitions

    private static let rootProperty: [String: Any] = [
        "type": "string", "default": "home",
        "description": "Which cached map: \"home\" (default), \"startup\" (whole startup disk) or the mount point of a volume such as /Volumes/Backup. Only maps the app has already made are available.",
    ]

    static let definitions: [[String: Any]] = [
        MCPServer.tool("storage_map",
                       "Read-only. The app's cached disk map (Storage → Explore): total size, file count and breakdown by kind of a folder, and its largest children. Never scans; it reads the map the app saved last. Returns available=false with a message when there is no map yet (the user must scan once in the app).",
                       ["root": rootProperty,
                        "path": ["type": "string", "description": "Folder inside the root, absolute or relative to the root. Default: the root itself."],
                        "limit": ["type": "integer", "default": 20, "description": "Largest children to list (1-100)."]]),
        MCPServer.tool("what_grew",
                       "Read-only. Which folders grew or shrank the most between the newest scan and the previous one (or an older one), like the app's \"What grew\" card. Needs at least two scans of the root; otherwise returns available=false with a message.",
                       ["root": rootProperty,
                        "since": ["type": "string", "description": "ISO 8601 date-time. Compare with the latest scan at or before it (the oldest if none is that old). Default: the previous scan."],
                        "limit": ["type": "integer", "default": 8, "description": "Folders to list (1-30)."],
                        "min_mb": ["type": "integer", "default": 100, "description": "Ignore changes smaller than this many MB."]]),
        MCPServer.tool("system_data",
                       "Read-only. Names the parts of macOS's grey \"System Data\" (caches, developer data, snapshots, VM files, logs, ...) with size, safety (safe_to_clear / look_first / managed_by_macos), a plain reason and location. Measures live and can take 10-60 seconds. Nothing is touched.",
                       ["items_per_group": ["type": "integer", "default": 8, "description": "Largest items to list per group (1-50)."]]),
        MCPServer.tool("cleanup_candidates",
                       "Read-only. The app's Clean up list as data: system-data items (caches, developer data, installers) plus large and old files from the cached home map (when one exists), each with safety, reason, size, path, whether the app ticks it by default and whether the owning app is running right now. Does not trash or change anything. App caches need the app's own app scan and are not included. Without a home map only system-data items are returned and the note says so.",
                       ["limit": ["type": "integer", "default": 40, "description": "Entries to list, largest first (1-200)."],
                        "min_mb": ["type": "integer", "default": 0, "description": "Skip entries smaller than this many MB."]]),
        MCPServer.tool("find_duplicates",
                       "Read-only. Groups of identical files (same content) in the cached map, most wasted space first, from large files to small. Never deletes. Stops after about 60 seconds and then sets partial=true with the size it covered. Returns available=false when there is no cached map.",
                       ["root": rootProperty,
                        "path": ["type": "string", "description": "Search only inside this folder of the map. Default: the whole root."],
                        "min_mb": ["type": "integer", "default": 10, "description": "Smallest file to consider, in MB."],
                        "limit": ["type": "integer", "default": 30, "description": "Groups to list (1-100)."]]),
        MCPServer.tool("crashes",
                       "Read-only. Which apps crashed or froze: counts for the last 7 and 30 days per app, last date and a plain reason, from the macOS crash reports. Empty list means none were found (or the report folders are not readable).",
                       ["limit": ["type": "integer", "default": 15, "description": "Apps to list (1-50)."]]),
        MCPServer.tool("spotlight_status",
                       "Read-only. Whether Spotlight is indexing or idle, which volumes it indexes, and the CPU the Spotlight processes use right now (two samples about one second apart). Does not rebuild or change the index.",
                       [:]),
        MCPServer.tool("fan_spinups",
                       "Read-only. Times the fans ramped up, with the peak rpm and the apps that were busy just before, from the history the app records. Returns an empty list with a message when no fan data was recorded (Mac without fans, or the app has not been running).",
                       ["range": MCPServer.enumSchema(["24h", "7d"]), "limit": ["type": "integer", "default": 20]]),
        MCPServer.tool("leftover_items",
                       "Read-only. Startup items (launch agents, daemons) whose app or program no longer exists, so they do nothing: label, path, scope (user/system) and a plain explanation. Nothing is removed.",
                       [:]),
        MCPServer.tool("security_status",
                       "Read-only. FileVault, System Integrity Protection, Gatekeeper and the firewall, each with an ok flag and a one-line explanation.",
                       [:]),
        MCPServer.tool("backup_status",
                       "Read-only. Time Machine: whether it is set up, the destinations, the last backup (date and age), whether a backup is running and how far it is. Says so when Full Disk Access is needed to read it. Only reads (tmutil status/destinationinfo/latestbackup).",
                       [:]),
        MCPServer.tool("privacy_indicators",
                       "Read-only. Which apps use the microphone right now and whether a camera is running (the orange and green menu bar dots). The camera app is a guess because macOS does not say which app uses it. Never opens the microphone or camera.",
                       [:]),
    ]

    // MARK: Dispatch

    static func call(_ name: String, _ args: [String: Any]) -> Any? {
        switch name {
        case "storage_map": return storageMap(args)
        case "what_grew": return whatGrew(args)
        case "system_data": return systemData(args)
        case "cleanup_candidates": return cleanupCandidates(args)
        case "find_duplicates": return findDuplicates(args)
        case "crashes": return crashes(args)
        case "spotlight_status": return spotlightStatus()
        case "fan_spinups": return fanSpinUps(args)
        case "leftover_items": return leftoverItems()
        case "security_status": return securityStatus()
        case "backup_status": return backupStatus()
        case "privacy_indicators": return privacyIndicators()
        default: return nil
        }
    }

    // MARK: Helpers

    private static func iso(_ date: Date) -> String { MCPServer.iso(date) }
    private static func clamp(_ value: Any?, _ fallback: Int, _ low: Int, _ high: Int) -> Int { max(low, min(high, value as? Int ?? fallback)) }
    private static func unavailable(_ message: String) -> [String: Any] { ["available": false, "message": message] }
    private static func bytesObject(_ bytes: UInt64) -> [String: Any] { ["bytes": bytes, "formatted": Format.storage(bytes)] }

    /// A root name as the tools take it, resolved to the cache files the app writes for it.
    private static func location(for root: String?) -> DiskIndexCache.Location? {
        switch root?.trimmingCharacters(in: .whitespaces) {
        case nil, "", "home": return DiskIndexCache.home()
        case "startup", "/": return DiskIndexCache.startupDisk()
        case let path?:
            let standard = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
            if standard == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path { return DiskIndexCache.home() }
            return DiskIndexCache.mountedVolume(path: standard)
        }
    }

    /// The cached map of a root, only when its file exists and really covers that root.
    private static func loadMap(_ root: String?) -> (location: DiskIndexCache.Location, index: DiskIndex)? {
        guard let location = location(for: root), FileManager.default.fileExists(atPath: location.cacheURL.path),
              let index = DiskIndex.load(from: location.cacheURL),
              index.root.standardizedFileURL.path == location.root.standardizedFileURL.path else { return nil }
        return (location, index)
    }

    private static func noMap(_ root: String?) -> [String: Any] {
        if location(for: root) == nil { return unavailable("\"\(root ?? "")\" is not a mounted volume. Use \"home\", \"startup\" or the mount point of a connected drive.") }
        return unavailable(noMapMessage)
    }

    /// The node of `path` (absolute inside the root, or relative to it).
    private static func node(in index: DiskIndex, path: String?) -> DiskIndex.NodeID? {
        guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return index.rootID }
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : index.root.appendingPathComponent(expanded)
        return index.id(of: url.standardizedFileURL)
    }

    private static func ageText(_ date: Date) -> String { Format.duration(max(0, Date().timeIntervalSince(date))) }

    // MARK: storage_map

    private static func storageMap(_ args: [String: Any]) -> Any {
        let rootName = args["root"] as? String
        guard let (location, index) = loadMap(rootName) else { return noMap(rootName) }
        let path = args["path"] as? String
        guard let id = node(in: index, path: path), let folder = index.node(id) else {
            return unavailable("That folder is not in the map (it may be new since the last scan, below a folder the scan skips, or outside the root \(location.root.path)).")
        }
        let limit = clamp(args["limit"], 20, 1, 100)
        let kinds = index.kindTotals(under: id).sorted { $0.value > $1.value }
        let total = max(1, folder.bytes)
        let children = index.children(of: id, limit: limit)
        let childCount = index.childCount(of: id)
        return [
            "available": true,
            "root": location.root.path,
            "map_date": iso(index.builtAt), "map_age": ageText(index.builtAt),
            "path": index.url(of: id).path,
            "is_directory": folder.isDirectory,
            "total_bytes": folder.bytes, "formatted_total": Format.storage(folder.bytes),
            "file_count": folder.fileCount,
            "kinds": kinds.map { ["kind": $0.key.rawValue, "bytes": $0.value, "formatted_bytes": Format.storage($0.value), "share": Double($0.value) / Double(total)] as [String: Any] },
            "children": children.map { child -> [String: Any] in
                var object: [String: Any] = ["name": child.name, "kind": child.isDirectory ? "folder" : child.kind.rawValue, "is_directory": child.isDirectory,
                                             "bytes": child.bytes, "formatted_bytes": Format.storage(child.bytes), "file_count": child.fileCount]
                if child.modified.timeIntervalSince1970 > 0 { object["modified"] = iso(child.modified) }
                if child.isUnread { object["unread"] = true }
                if child.isDirectory { object["dominant_kind"] = child.kind.rawValue }
                return object
            },
            "children_total": childCount, "children_truncated": childCount > children.count,
        ] as [String: Any]
    }

    // MARK: what_grew

    private static func whatGrew(_ args: [String: Any]) -> Any {
        let rootName = args["root"] as? String
        guard let location = location(for: rootName) else { return noMap(rootName) }
        let history = DiskGrowth.History.load(from: location.growthURL)
        guard !history.summaries.isEmpty else { return noMap(rootName) }
        let since = (args["since"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        guard let (old, new) = DiskGrowth.pair(in: history.summaries, comparedTo: since) else {
            return unavailable("Only one scan of this root so far (\(iso(history.summaries[0].date))). Scan again in Activity+ → Storage → Explore later, then this shows what changed.")
        }
        let limit = clamp(args["limit"], 8, 1, 30), minMB = clamp(args["min_mb"], 100, 0, 100_000)
        let changes = DiskGrowth.changes(from: old, to: new, minChange: UInt64(minMB) * 1_000_000, limit: limit)
        let delta = Int64(clamping: new.totalBytes) - Int64(clamping: old.totalBytes)
        func signed(_ value: Int64) -> String { (value < 0 ? "-" : "+") + Format.storage(value.magnitude) }
        return [
            "available": true,
            "root": new.root,
            "from": ["date": iso(old.date), "total_bytes": old.totalBytes, "formatted_total": Format.storage(old.totalBytes), "file_count": old.fileCount],
            "to": ["date": iso(new.date), "total_bytes": new.totalBytes, "formatted_total": Format.storage(new.totalBytes), "file_count": new.fileCount],
            "total_change_bytes": delta, "formatted_total_change": signed(delta),
            "scans_available": history.summaries.count,
            "changes": changes.map { change -> [String: Any] in
                ["path": change.path, "name": change.name, "direction": change.grew ? "grew" : "shrank",
                 "old_bytes": change.oldBytes as Any? ?? NSNull(), "new_bytes": change.newBytes as Any? ?? NSNull(),
                 "delta_bytes": change.delta, "formatted_delta": signed(change.delta),
                 "status": change.isNew ? "new_or_previously_small" : change.isGone ? "gone_or_now_small" : "changed"]
            },
            "note": "Paths are relative to the root and only folders of at least \(Format.storage(old.minBytes)) down to \(DiskGrowth.defaultDepth) levels are tracked.",
        ] as [String: Any]
    }

    // MARK: system_data

    private static func safetyText(_ safety: Safety) -> String {
        switch safety { case .safeToClear: "safe_to_clear"; case .lookFirst: "look_first"; case .managedByMacOS: "managed_by_macos" }
    }

    private static func systemData(_ args: [String: Any]) -> Any {
        let perGroup = clamp(args["items_per_group"], 8, 1, 50)
        let started = Date()
        let groups = SystemDataBreakdown.measure()
        let shown = groups.filter { !$0.items.isEmpty }.sorted { $0.bytes > $1.bytes }
        let distinct = groups.reduce(UInt64(0)) { $0 + $1.distinctBytes }
        return [
            "available": true,
            "total_bytes": distinct, "formatted_total": Format.storage(distinct),
            "note": "Purgeable space is listed but not counted in the total (it overlaps with caches and snapshots).",
            "measured_in_seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
            "groups": shown.map { group -> [String: Any] in
                let items = group.items.sorted { $0.bytes > $1.bytes }
                return ["id": group.id, "title": group.title, "safety": safetyText(group.safety), "bytes": group.bytes, "formatted_bytes": Format.storage(group.bytes),
                        "item_count": items.count,
                        "items": items.prefix(perGroup).map(itemObject)]
            },
        ] as [String: Any]
    }

    private static func itemObject(_ item: ReclaimableItem) -> [String: Any] {
        var object: [String: Any] = ["id": item.id, "title": item.title, "location": item.location, "bytes": item.bytes, "formatted_bytes": Format.storage(item.bytes),
                                     "safety": safetyText(item.safety), "reason": item.reason]
        if let path = item.urls.first?.path { object["path"] = path }
        if item.urls.count > 1 { object["path_count"] = item.urls.count }
        if let bundle = item.bundleID, !bundle.isEmpty { object["bundle_id"] = bundle }
        return object
    }

    // MARK: cleanup_candidates

    private static func cleanupCandidates(_ args: [String: Any]) -> Any {
        let limit = clamp(args["limit"], 40, 1, 200), minBytes = UInt64(clamp(args["min_mb"], 0, 0, 100_000)) * 1_000_000
        var notes: [String] = []
        let groups = SystemDataBreakdown.measure()
        var entries = CleanupPlan.entries(from: groups) + CleanupPlan.macOSInstallers()
        let home = DiskIndexCache.home()
        if let map = loadMap("home"), map.index.root.standardizedFileURL.path == home.root.path {
            let found = LargeFilesScanner().scan(index: map.index) { _, _ in }
            entries += CleanupPlan.entries(from: found)
            notes.append("Large and old files come from the home map of \(iso(map.index.builtAt)).")
        } else {
            notes.append("No home map yet, so large and old files are missing. \(noMapMessage)")
        }
        notes.append("App caches are only listed after the app's own app scan and are not included here.")
        let merged = CleanupPlan.merge(entries).filter { $0.item.bytes >= minBytes }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let ticked = CleanupPlan.defaultSelection(merged, running: running)
        let sorted = merged.sorted { $0.item.bytes > $1.item.bytes }
        let tickedBytes = CleanupPlan.totalBytes(merged, ids: ticked)
        return [
            "available": true,
            "entry_count": merged.count,
            "total_bytes": merged.reduce(UInt64(0)) { $0 + $1.item.bytes }, "formatted_total": Format.storage(merged.reduce(UInt64(0)) { $0 + $1.item.bytes }),
            "ticked_by_default_bytes": tickedBytes, "formatted_ticked_by_default": Format.storage(tickedBytes),
            "notes": notes,
            "entries": sorted.prefix(limit).map { entry -> [String: Any] in
                var object = itemObject(entry.item)
                object["section"] = entry.section.title
                object["ticked_by_default"] = ticked.contains(entry.id)
                object["app_running"] = CleanupPlan.isBlocked(entry, running: running)
                if let owner = entry.ownerName { object["app"] = owner }
                return object
            },
            "truncated": merged.count > limit,
        ] as [String: Any]
    }

    // MARK: find_duplicates

    private static func findDuplicates(_ args: [String: Any]) -> Any {
        let rootName = args["root"] as? String
        guard let (location, index) = loadMap(rootName) else { return noMap(rootName) }
        guard let start = node(in: index, path: args["path"] as? String), index.node(start)?.isDirectory == true else {
            return unavailable("That folder is not in the map.")
        }
        let minBytes = max(1, UInt64(clamp(args["min_mb"], 10, 1, 100_000)) * 1_000_000), limit = clamp(args["limit"], 30, 1, 100)
        let deadline = Date().addingTimeInterval(60)
        // Identical files have the same size, so searching from big files to small ones is complete per tier and
        // a stop at the deadline still leaves everything above the tier reached.
        let tiers = ([1_000_000_000, 250_000_000, 100_000_000, 50_000_000, 25_000_000] as [UInt64]).filter { $0 > minBytes } + [minBytes]
        var groups: [DuplicateFinder.Group] = []
        var done = Set<String>()
        var partial = false
        var completeDownTo: UInt64?
        for tier in tiers {
            if Date() >= deadline { partial = true; break }
            let fresh = DuplicateFinder.candidates(in: index, under: start, minBytes: tier).filter { done.insert($0).inserted }
            let found = DuplicateFinder.find(paths: fresh, minBytes: tier, isCancelled: { Date() >= deadline })
            if Date() >= deadline { partial = true; break }
            groups += found
            completeDownTo = tier
        }
        groups.sort { $0.wasted > $1.wasted }
        let wasted = groups.reduce(UInt64(0)) { $0 + $1.wasted }
        var result: [String: Any] = [
            "available": true,
            "root": location.root.path, "map_date": iso(index.builtAt),
            "min_bytes": minBytes, "partial": partial,
            "group_count": groups.count, "wasted_bytes": wasted, "formatted_wasted": Format.storage(wasted),
            "groups": groups.prefix(limit).map { group -> [String: Any] in
                ["size_bytes": group.size, "formatted_size": Format.storage(group.size), "copies": group.copies,
                 "wasted_bytes": group.wasted, "formatted_wasted": Format.storage(group.wasted),
                 "files": group.files.prefix(6).enumerated().map { position, file -> [String: Any] in
                     ["path": file.path, "modified": iso(file.modified), "suggested_keep": position == 0] },
                 "more_copies": max(0, group.files.count - 6)]
            },
            "truncated": groups.count > limit,
            "note": "Content is compared byte for byte; hard links and iCloud-only files are skipped. Nothing is deleted.",
        ]
        if partial {
            result["complete_for_files_from_bytes"] = completeDownTo.map { $0 as Any } ?? NSNull()
            result["message"] = "Stopped after about 60 seconds. Files of " + (completeDownTo.map { Format.storage($0) + " and larger" } ?? "no size") + " are covered; raise min_mb or pass a smaller path for the rest."
        }
        return result
    }

    // MARK: crashes

    private static func crashes(_ args: [String: Any]) -> Any {
        let limit = clamp(args["limit"], 15, 1, 50)
        let summaries = CrashReports.summarize(CrashReports.scan())
        return [
            "available": true, "app_count": summaries.count,
            "apps": summaries.prefix(limit).map { s -> [String: Any] in
                ["app": s.appName, "bundle_id": s.bundleID as Any? ?? NSNull(),
                 "crashes_7d": s.crashes7, "crashes_30d": s.crashes30, "hangs_7d": s.hangs7, "hangs_30d": s.hangs30, "resource_warnings_30d": s.resource30,
                 "last_date": iso(s.lastDate), "last_kind": s.lastKind.rawValue, "last_reason": s.lastReason]
            },
            "truncated": summaries.count > limit,
            "note": summaries.isEmpty ? "No crash or hang reports in the last 30 days." : "Reports of one app written within seconds of each other count as one incident.",
        ] as [String: Any]
    }

    // MARK: spotlight_status

    private static func spotlightStatus() -> Any {
        _ = MCPServer.queue.sync { MCPServer.sampler.sample() }
        Thread.sleep(forTimeInterval: 1)
        let snapshot = MCPServer.queue.sync { () -> SystemSnapshot in let s = MCPServer.sampler.sample(); MCPServer.latest = s; return s }
        var status = SpotlightStatus()
        status.volumes = SpotlightStatus.readVolumes()
        let usage = SpotlightStatus.usage(of: snapshot.apps.flatMap(\.processes))
        status.cpuPercent = usage.cpu; status.diskRate = usage.disk; status.processCount = usage.count
        let indexed = Set(status.indexedVolumes.map(\.path))
        return [
            "available": true,
            "state": status.isIndexing ? "indexing" : "idle",
            "indexing": status.isIndexing,
            "summary": status.isIndexing ? status.indexingTitle : "Spotlight is idle.",
            "cpu_percent": status.cpuPercent, "formatted_cpu": Format.percent(status.cpuPercent),
            "disk_bytes_per_second": status.diskRate, "formatted_disk_rate": Format.rate(status.diskRate),
            "process_count": status.processCount,
            "indexing_threshold_cpu_percent": SpotlightStatus.indexingThreshold,
            "volumes": status.volumes.map { ["path": $0.path, "name": $0.displayName, "indexing_enabled": $0.state == .on ? true : $0.state == .off ? false : NSNull() as Any, "user_volume": indexed.contains($0.path)] },
        ] as [String: Any]
    }

    // MARK: fan_spinups

    private static func fanSpinUps(_ args: [String: Any]) -> Any {
        let range = args["range"] as? String ?? "24h", limit = clamp(args["limit"], 20, 1, 100)
        let since = Date().addingTimeInterval(range == "7d" ? -7 * 86_400 : -86_400)
        let store = HistoryStore()
        let fan = store.fanSeries(from: since, to: Date())
        guard !fan.isEmpty else {
            return ["available": false, "range": range, "spinups": [Any](), "message": "No fan readings in this range: the Mac has no fans, or Activity+ was not recording."] as [String: Any]
        }
        let spinUps = store.fanSpinUps(since: since).sorted { $0.start > $1.start }
        return [
            "available": true, "range": range, "since": iso(since), "spinup_count": spinUps.count,
            "highest_rpm": fan.map(\.rpm).max() as Any? ?? NSNull(),
            "spinups": spinUps.prefix(limit).map { s -> [String: Any] in
                ["start": iso(s.start), "end": iso(s.end), "duration": Format.duration(s.end.timeIntervalSince(s.start)),
                 "peak_rpm": Int(s.peakRPM.rounded()),
                 "top_apps": s.topApps.map { ["app": $0.name, "cpu_percent": ($0.cpu * 10).rounded() / 10, "gpu_percent": ($0.gpu * 10).rounded() / 10] as [String: Any] }]
            },
            "truncated": spinUps.count > limit,
            "note": spinUps.isEmpty ? "The fans stayed at rest speed in this range." : "Top apps are the busiest ones in the 10 minutes before the fans rose.",
        ] as [String: Any]
    }

    // MARK: leftover_items

    private static func leftoverItems() -> Any {
        let items = StartupItemsScanner.scan().compactMap { item -> [String: Any]? in
            guard let orphan = item.orphan else { return nil }
            let system = item.scope == .globalAgent || item.scope == .globalDaemon
            return ["label": item.label, "scope": system ? "system" : "user", "kind": item.scope.rawValue,
                    "plist_path": item.plistPath as Any? ?? NSNull(), "program": item.program as Any? ?? NSNull(),
                    "missing_path": orphan.missingPath, "reason": orphan.badge, "explanation": orphan.explanation,
                    "running": item.isRunning, "owner": item.ownerName]
        }
        return ["available": true, "count": items.count, "items": items,
                "note": items.isEmpty ? "Every startup item still has its program." : "System-scope items need an administrator to remove; nothing is removed by this tool."] as [String: Any]
    }

    // MARK: security_status

    private static func securityStatus() -> Any {
        let checks = SecurityStatus.read()
        return [
            "available": true,
            "all_ok": checks.allSatisfy { $0.level == .good },
            "checks": checks.map { check -> [String: Any] in
                ["name": check.title, "id": check.kind.rawValue, "ok": check.level == .good,
                 "level": check.level == .good ? "good" : check.level == .warning ? "warning" : "unknown",
                 "state": check.state, "explanation": check.detail]
            },
        ] as [String: Any]
    }

    // MARK: backup_status

    private static func backupStatus() -> Any {
        let info = TimeMachine.read()
        if info.needsFullDiskAccess {
            return ["available": false, "needs_full_disk_access": true,
                    "message": "Time Machine can't be read: the host app of this MCP server needs Full Disk Access (System Settings → Privacy & Security)."] as [String: Any]
        }
        var result: [String: Any] = [
            "available": true,
            "configured": !info.destinations.isEmpty,
            "destinations": info.destinations.map { ["name": $0.name, "kind": $0.kind, "mount_point": $0.mountPoint as Any? ?? NSNull()] as [String: Any] },
            "destination_reachable": info.destinationReachable,
            "running": info.progress.running,
        ]
        if info.progress.running {
            result["phase"] = info.progress.phase as Any? ?? NSNull()
            result["progress"] = info.progress.fraction as Any? ?? NSNull()
        }
        if let last = info.lastBackup {
            result["last_backup"] = iso(last)
            result["age_days"] = TimeMachine.daysSince(last)
            result["age"] = ageText(last)
            result["stale"] = TimeMachine.isStale(info)
        } else {
            result["last_backup"] = NSNull()
        }
        result["message"] = info.destinations.isEmpty ? "Time Machine is not set up." :
            info.lastBackup == nil ? "No backup found yet." :
            info.destinationReachable ? "The backup disk is connected." : "The backup disk is not connected; the date is the last one macOS remembers."
        return result
    }

    // MARK: privacy_indicators

    private static func privacyIndicators() -> Any {
        let microphone = PrivacyReader.microphoneUsers()
        let cameras = PrivacyReader.runningCameras()
        let guess = cameras.isEmpty ? [] : PrivacyReader.cameraCandidates(microphoneUsers: microphone)
        func client(_ c: PrivacyReader.Client) -> [String: Any] { ["app": c.name, "bundle_id": c.bundleID as Any? ?? NSNull(), "pid": c.pid] }
        return [
            "available": true,
            "microphone_in_use": !microphone.isEmpty, "microphone_apps": microphone.map(client),
            "camera_in_use": !cameras.isEmpty, "cameras_running": cameras, "camera_probable_apps": guess.map(client),
            "note": "macOS does not say which app uses the camera; camera_probable_apps is a guess (apps using the microphone, or the one known camera app that is running) and may be empty.",
        ] as [String: Any]
    }
}
