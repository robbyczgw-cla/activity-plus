import Foundation
import Testing
@testable import ActivityCore

@Suite("Time Machine")
struct TimeMachineTests {
    @Test func parsesIdleStatus() {
        let p = TimeMachine.parseStatus("""
        Backup session status:
        {
            ClientID = "com.apple.backupd";
            Percent = "-1";
            Running = 0;
        }
        """)
        #expect(!p.running)
        #expect(p.fraction == nil)
    }

    @Test func parsesRunningStatus() {
        let p = TimeMachine.parseStatus("""
        Backup session status:
        {
            BackupPhase = Copying;
            ClientID = "com.apple.backupd";
            Percent = "0.4231";
            Running = 1;
        }
        """)
        #expect(p.running)
        #expect(p.phase == "Copying")
        #expect(abs((p.fraction ?? 0) - 0.4231) < 0.0001)
    }

    @Test func parsesDestinations() {
        let text = """
        ====================================================
        Name          : Backup Disk
        Kind          : Local
        Mount Point   : /Volumes/Backup Disk
        ID            : AAAA
        ====================================================
        Name          : NAS
        Kind          : Network
        URL           : smb://nas/tm
        ID            : BBBB
        """
        let d = TimeMachine.parseDestinations(text)
        #expect(d.map(\.name) == ["Backup Disk", "NAS"])
        #expect(d[0].mountPoint == "/Volumes/Backup Disk")
        #expect(d[1].mountPoint == nil)
        #expect(TimeMachine.parseDestinations("No destinations configured.").isEmpty)
    }

    @Test func parsesLatestBackupDate() throws {
        let classic = try #require(TimeMachine.parseLatestBackup("/Volumes/Backup/Backups.backupdb/My Mac/2026-10-09-123456\n"))
        let apfs = TimeMachine.parseLatestBackup("/Volumes/Backup/2026-10-09-123456.backup")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: classic)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 10, 9, 12, 34, 56])
        #expect(classic == apfs)
        #expect(TimeMachine.parseLatestBackup("Failed to mount backup destination, error: Domain Code=17") == nil)
        #expect(TimeMachine.parseActivity("2025-10-21-134540") != nil)
        #expect(TimeMachine.parseActivity(nil) == nil)
    }

    @Test func detectsMissingAccess() {
        #expect(TimeMachine.needsFullDiskAccess("tmutil: requires Full Disk Access privileges"))
        #expect(!TimeMachine.needsFullDiskAccess("Backup session status:"))
    }

    @Test func staleOnlyWithDestinationAndNoRunningBackup() {
        let now = Date()
        var info = TimeMachineInfo()
        info.lastBackup = now.addingTimeInterval(-9 * 86_400)
        #expect(!TimeMachine.isStale(info, now: now))   // no destination
        info.destinations = [.init(name: "Disk", kind: "Local")]
        #expect(TimeMachine.isStale(info, now: now))
        #expect(TimeMachine.daysSince(info.lastBackup!, now: now) == 9)
        info.lastBackup = now.addingTimeInterval(-6 * 86_400)
        #expect(!TimeMachine.isStale(info, now: now))
        info.lastBackup = now.addingTimeInterval(-9 * 86_400)
        info.progress = .init(running: true)
        #expect(!TimeMachine.isStale(info, now: now))
    }
}

@Suite("Security status")
struct SecurityStatusTests {
    @Test func fileVault() {
        #expect(SecurityStatus.parseFileVault("FileVault is On.").level == .good)
        #expect(SecurityStatus.parseFileVault("FileVault is Off.").level == .warning)
        #expect(SecurityStatus.parseFileVault("FileVault is On.\nEncryption in progress: Percent completed = 12").level == .warning)
        #expect(SecurityStatus.parseFileVault("").level == .unknown)
    }

    @Test func sip() {
        #expect(SecurityStatus.parseSIP("System Integrity Protection status: enabled.").level == .good)
        #expect(SecurityStatus.parseSIP("System Integrity Protection status: disabled.").level == .warning)
        #expect(SecurityStatus.parseSIP("System Integrity Protection status: enabled (Custom Configuration).").level == .warning)
        #expect(SecurityStatus.parseSIP("command not found").level == .unknown)
    }

    @Test func gatekeeper() {
        #expect(SecurityStatus.parseGatekeeper("assessments enabled").level == .good)
        #expect(SecurityStatus.parseGatekeeper("assessments disabled").level == .warning)
    }

    @Test func firewall() {
        #expect(SecurityStatus.parseFirewall("Firewall is enabled. (State = 1)").level == .good)
        #expect(SecurityStatus.parseFirewall("Firewall is enabled. (State = 2)").level == .good)
        #expect(SecurityStatus.parseFirewall("Firewall is disabled. (State = 0)").level == .warning)
        #expect(SecurityStatus.parseFirewall("???").level == .unknown)
    }
}
