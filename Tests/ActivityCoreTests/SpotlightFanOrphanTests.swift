import Foundation
import Testing
@testable import ActivityCore

@Suite("Spotlight")
struct SpotlightTests {
    static let mdutil = """
    /:
    \tIndexing enabled.
    /System/Volumes/Data:
    \tIndexing enabled.
    /System/Volumes/Preboot:
    \tIndexing enabled.
    /Users/alex/Library/Developer/CoreDevice/DeviceFS:
    \tIndexing and searching disabled.
    /Volumes/Transcend:
    \tIndexing enabled.
    """

    @Test func parsesMdutilOutput() {
        let volumes = SpotlightStatus.parseMdutil(Self.mdutil)
        #expect(volumes.count == 5)
        #expect(volumes[0] == .init(path: "/", state: .on))
        #expect(volumes[3].state == .off)
        var status = SpotlightStatus()
        status.volumes = volumes
        #expect(status.indexedVolumes.map(\.path) == ["/", "/System/Volumes/Data", "/Volumes/Transcend"])
    }

    @Test func indexingNeedsRealWork() {
        var status = SpotlightStatus()
        status.volumes = SpotlightStatus.parseMdutil(Self.mdutil)
        status.cpuPercent = 8
        #expect(!status.isIndexing)
        status.cpuPercent = 90
        #expect(status.isIndexing)
        status.volumes = [.init(path: "/", state: .off)]
        #expect(!status.isIndexing)
    }

    @Test func addsUpOnlySpotlightProcesses() {
        func process(_ name: String, cpu: Double, disk: Double) -> ProcessSample {
            var p = ProcessSample(pid: 1, ppid: 0, uid: 0, name: name, path: nil, startTime: Date())
            p.cpuPercent = cpu; p.diskReadRate = disk; p.diskWriteRate = disk
            return p
        }
        let usage = SpotlightStatus.usage(of: [process("mds_stores", cpu: 40, disk: 100), process("mdworker_shared", cpu: 30, disk: 50),
                                               process("mdnsresponder", cpu: 90, disk: 999), process("Safari", cpu: 10, disk: 1)])
        #expect(usage.cpu == 70)
        #expect(usage.disk == 300)
        #expect(usage.count == 2)
    }

    @Test func rebuildIsOnlyAScriptThatNeedsAdminRights() {
        #expect(SpotlightStatus.rebuildAppleScript.contains("with administrator privileges"))
        #expect(SpotlightStatus.rebuildAppleScript.contains("mdutil -E /"))
    }
}

@Suite("Fan spin-ups")
struct FanSpinUpTests {
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    func load(_ id: String, cpu: Double, gpu: Double = 0) -> FanSpinUps.AppLoad { .init(appID: id, name: id, cpu: cpu, gpu: gpu) }

    @Test func findsTheSpinUpAndTheBusiestApps() {
        // Fan at rest (0 rpm), up for four minutes at 20:30, quiet again.
        var fan = (0..<20).map { FanSpinUps.FanPoint(date: at(Double($0)), rpm: 0) }
        fan += [2400, 3100, 3600, 2900].enumerated().map { FanSpinUps.FanPoint(date: at(20 + Double($0.offset)), rpm: $0.element) }
        fan += (24..<30).map { FanSpinUps.FanPoint(date: at(Double($0)), rpm: 1000) }
        let windows = [
            FanSpinUps.AppWindow(end: at(15), apps: [load("Xcode", cpu: 80), load("Mail", cpu: 5)]),
            FanSpinUps.AppWindow(end: at(20), apps: [load("Xcode", cpu: 400), load("Blender", cpu: 200, gpu: 60), load("Safari", cpu: 10)]),
            FanSpinUps.AppWindow(end: at(60), apps: [load("Later", cpu: 900)]),
        ]
        let spinUps = FanSpinUps.detect(fan: fan, windows: windows, cores: 10)
        #expect(spinUps.count == 1)
        let event = spinUps[0]
        #expect(event.peakRPM == 3600)
        #expect(event.start == at(19))
        #expect(Set(event.topApps.map(\.name)) == ["Blender", "Xcode"])
        #expect(!event.topApps.contains { $0.name == "Later" || $0.name == "Safari" })
    }

    @Test func slowDriftIsNotASpinUp() {
        let fan = (0..<30).map { FanSpinUps.FanPoint(date: at(Double($0)), rpm: 1200 + Double($0) * 10) }
        #expect(FanSpinUps.detect(fan: fan, windows: [], cores: 8).isEmpty)
    }

    @Test func gapsOfAFewMinutesStayOneEvent() {
        let fan = [0, 1, 2, 3].map { FanSpinUps.FanPoint(date: at(Double($0)), rpm: 0) }
            + [FanSpinUps.FanPoint(date: at(10), rpm: 2500), FanSpinUps.FanPoint(date: at(12), rpm: 2800), FanSpinUps.FanPoint(date: at(30), rpm: 2500)]
        let spinUps = FanSpinUps.detect(fan: fan, windows: [], cores: 8)
        #expect(spinUps.count == 2)
        #expect(spinUps[0].peakRPM == 2800)
        #expect(spinUps[0].topApps.isEmpty)
    }

    @Test func noReadingsNoEvents() {
        #expect(FanSpinUps.detect(fan: [], windows: [], cores: 8).isEmpty)
    }

    @Test func historyHasTheFanColumn() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fan-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        // A fresh or older database gets the column; reading it when empty must not fail.
        #expect(store.fanSeries(from: Date(timeIntervalSinceNow: -3600), to: Date()).isEmpty)
        #expect(store.fanSpinUps(since: Date(timeIntervalSinceNow: -3600)).isEmpty)
    }
}

@Suite("Orphaned background items")
struct OrphanedItemTests {
    func exists(_ present: Set<String>) -> (String) -> Bool { { present.contains($0) } }

    @Test func existingProgramIsFine() {
        #expect(OrphanedItems.check(program: "/usr/bin/true", arguments: [], fileExists: exists(["/usr/bin/true"])) == nil)
    }

    @Test func deletedAppIsReportedAsAppMissing() {
        let program = "/Applications/Old Tool.app/Contents/MacOS/helper"
        let item = OrphanedItems.check(program: program, arguments: [program], fileExists: exists(["/Applications"]))
        #expect(item?.reason == .appMissing(bundlePath: "/Applications/Old Tool.app"))
        #expect(item?.badge == "App missing")
        #expect(item?.explanation.contains("Old Tool") == true)
    }

    @Test func missingProgramInsideAnInstalledAppIsOnlyAMissingProgram() {
        let program = "/Applications/Tool.app/Contents/MacOS/old-helper"
        let item = OrphanedItems.check(program: program, arguments: [], fileExists: exists(["/Applications/Tool.app"]))
        #expect(item?.reason == .programMissing(path: program))
    }

    @Test func unpluggedDriveIsNotAnOrphan() {
        #expect(OrphanedItems.check(program: "/Volumes/Backup/bin/sync", arguments: [], fileExists: exists([])) == nil)
        #expect(OrphanedItems.check(program: "/Volumes/Backup/bin/sync", arguments: [], fileExists: exists(["/Volumes/Backup"])) != nil)
    }

    @Test func relativeAndUnknownProgramsAreLeftAlone() {
        #expect(OrphanedItems.check(program: nil, arguments: [], fileExists: exists([])) == nil)
        #expect(OrphanedItems.check(program: "node", arguments: ["node", "x.js"], fileExists: exists([])) == nil)
        #expect(OrphanedItems.check(program: "/opt/$HOME/x", arguments: [], fileExists: exists([])) == nil)
    }

    @Test func scriptRunByAnInterpreterCounts() {
        let present: Set<String> = ["/bin/sh"]
        // "-c" takes a command string, which is not checked.
        #expect(OrphanedItems.check(program: "/bin/sh", arguments: ["/bin/sh", "-c", "/Users/me/old.sh"], fileExists: exists(present)) == nil)
        let script = OrphanedItems.check(program: "/bin/sh", arguments: ["/bin/sh", "/Users/me/start.sh"], fileExists: exists(present))
        #expect(script?.reason == .programMissing(path: "/Users/me/start.sh"))
    }

    private func item(scope: StartupItem.Scope, plist: String, orphan: Bool) -> StartupItem {
        var i = StartupItem(id: plist, label: "com.old.agent", scope: scope, plistPath: plist, program: "/Applications/Gone.app/Contents/MacOS/x", arguments: [],
                            runAtLoad: true, keepAlive: false, isDisabled: false, isRunning: false, pid: nil, ownerBundlePath: nil, ownerName: "Gone", isApple: false)
        if orphan { i.orphan = OrphanedItem(reason: .appMissing(bundlePath: "/Applications/Gone.app")) }
        return i
    }

    @Test func onlyOwnLaunchAgentsCanBeRemovedAndNothingIsTouchedOtherwise() {
        let home = "/Users/test"
        #expect(OrphanedItems.canRemove(item(scope: .userAgent, plist: home + "/Library/LaunchAgents/a.plist", orphan: true), home: home))
        #expect(!OrphanedItems.canRemove(item(scope: .userAgent, plist: home + "/Library/LaunchAgents/a.plist", orphan: false), home: home))
        #expect(!OrphanedItems.canRemove(item(scope: .globalAgent, plist: "/Library/LaunchAgents/a.plist", orphan: true), home: home))
        #expect(!OrphanedItems.canRemove(item(scope: .globalDaemon, plist: "/Library/LaunchDaemons/a.plist", orphan: true), home: home))
        #expect(!OrphanedItems.canRemove(item(scope: .userAgent, plist: "/tmp/a.plist", orphan: true), home: home))
        // trash() refuses before doing anything when the item is not removable.
        #expect(throws: OrphanedItems.RemoveError.self) { try OrphanedItems.trash(item(scope: .globalDaemon, plist: "/Library/LaunchDaemons/a.plist", orphan: true)) }
    }
}
