import Testing
@testable import ActivityCore

@Suite("iCloud sync status")
struct ICloudStatusTests {
    /// Everything in step: areas have synced down and are caught up.
    static let idle = """
    3 containers matching '*'
    <com.apple.CloudDocs[1] background {client:idle server:full-sync|fetched-recents|ever-full-sync sync:has-synced-down last-sync:2026-10-25 20:39:21.369, caught-up, token:unkown-token-size:34 zoneActiveState:{rid:1} appuninstalled:(null)}>
    <com.example.notes[12] background {client:idle server:full-sync|fetched-recents sync:oob-sync-ack last-sync:2025-10-14 11:17:47.194, consistent zoneActiveState:{rid:1} appuninstalled:(null)}>
    <com.example.reader[30] foreground {client:idle server:full-sync|fetched-favorites sync:has-synced-down last-sync:2026-10-25 20:39:20.636, caught-up, zoneActiveState:{rid:1} appuninstalled:(null)}>
    Desktop & Documents: current=NO lastEnabled=(never) lastDisabled=(never)
    """

    /// Two areas have changes waiting to upload; one area belongs to an uninstalled app and must not count.
    static let pending = """
    3 containers matching '*'
    <com.apple.CloudDocs[1] background {client:needs-sync server:idle sync:idle last-sync:2026-10-25 20:39:21.369, zoneActiveState:{rid:1} appuninstalled:(null)}>
    <com.example.notes[12] background {client:needs-sync server:idle sync:idle last-sync:never zoneActiveState:{rid:1} appuninstalled:(null)}>
    <com.example.reader[30] background {client:idle server:full-sync sync:has-synced-down last-sync:2026-10-25 20:39:20.636, caught-up zoneActiveState:{rid:1} appuninstalled:(null)}>
    <com.example.oldapp[44] background {client:needs-sync|blocked-app-uninstalled server:idle sync:idle last-sync:never zoneActiveState:{(null)} appuninstalled:2026-06-30 14:24:39 +0000}>
    >>> SYNC DISABLED (app not installed)
    Desktop & Documents: current=NO lastEnabled=(never) lastDisabled=(never)
    """

    /// An area with a sync error and one with a reset that has since recovered (a past error does not count).
    static let stuck = """
    3 containers matching '*'
    <com.apple.CloudDocs[1] background {client:stalled server:idle sync:error last-sync:2026-10-20 08:12:01.000, zoneActiveState:{rid:1} appuninstalled:(null)}>
    <com.example.notes[12] background {client:idle server:full-sync sync:has-synced-down last-sync:2026-10-25 20:39:21.369, caught-up, last-reset:2026-10-11 22:29:58.113 (Der Vorgang konnte nicht abgeschlossen werden. (BRInternalErrorDomain-Fehler 1013 - crash-recovery)) zoneActiveState:{rid:57} appuninstalled:(null)}>
    """

    /// Output with terminal colour codes, as `brctl` prints it in a terminal.
    static let coloured = "\u{1B}[0;1;30mbackground\u{1B}[0m {client:\u{1B}[31mneeds-sync\u{1B}[39m server:idle sync:idle appuninstalled:(null)}\n<com.example.oldapp[44] background {client:\u{1B}[0;1mblocked-app-uninstalled\u{1B}[0m server:idle sync:idle appuninstalled:2026-06-30 14:24:39 +0000}\n\u{1B}[0;1;30mbackground\u{1B}[0m {client:idle server:full-sync sync:has-synced-down caught-up}"

    static let notSignedIn = "No iCloud account is signed in on this Mac.\n"
    static let driveOff = "iCloud Drive is turned off for this Mac.\n"

    @Test func idleOutputIsIdle() {
        let status = ICloudStatus.parse(status: Self.idle, quota: "89988765133 bytes of quota remaining in personal account\n")
        #expect(status.health == .idle)
        #expect(status.driveOn == true)
        #expect(status.containers == 3)
        #expect(status.pendingContainers == 0)
        #expect(status.stalledContainers == 0)
        #expect(status.itemsToUpload == nil)
        #expect(status.itemsToDownload == nil)
        #expect(status.needsAttention == false)
    }

    @Test func waitingAreasAreCountedButUninstalledOnesAreNot() {
        let status = ICloudStatus.parse(status: Self.pending)
        #expect(status.health == .syncing)
        #expect(status.isSyncing)
        #expect(status.containers == 4)
        #expect(status.pendingContainers == 2)
        #expect(status.disabledContainers == 1)
        #expect(status.needsAttention)
    }

    @Test func errorAreaMakesStalledAndPastResetDoesNot() {
        let status = ICloudStatus.parse(status: Self.stuck)
        #expect(status.health == .stalled)
        #expect(status.isStuck)
        #expect(status.stalledContainers == 1)
        #expect(status.pendingContainers == 0)
        #expect(status.needsAttention)
    }

    @Test func colourCodesAreIgnored() {
        let status = ICloudStatus.parse(status: Self.coloured)
        #expect(status.containers == 3)
        #expect(status.pendingContainers == 1)
        #expect(status.disabledContainers == 1)
        #expect(status.health == .syncing)
    }

    @Test func printedItemCountsAreReadWithDigitGroups() {
        let output = """
        Uploading 1 240 items to iCloud
        12 items waiting to download
        <com.apple.CloudDocs[1] background {client:idle server:full-sync sync:has-synced-down caught-up zoneActiveState:{rid:1} appuninstalled:(null)}>
        """
        let status = ICloudStatus.parse(status: output)
        #expect(status.itemsToUpload == 1240)
        #expect(status.itemsToDownload == 12)
        #expect(status.health == .syncing)
    }

    @Test func notSignedInIsReported() {
        let status = ICloudStatus.parse(status: Self.notSignedIn)
        #expect(status.health == .notSignedIn)
        #expect(status.driveOn == nil)
        #expect(status.needsAttention == false)
    }

    @Test func driveSwitchedOffIsReported() {
        let status = ICloudStatus.parse(status: Self.driveOff)
        #expect(status.health == .off)
        #expect(status.driveOn == false)
        #expect(status.needsAttention == false)
    }

    @Test func emptyAndGarbageOutputIsUnknownAndDoesNotCrash() {
        #expect(ICloudStatus.parse(status: "").health == .unknown)
        #expect(ICloudStatus.parse(status: "\u{0}\u{1}?? {{ }} |||").health == .unknown)
        #expect(ICloudStatus.parse(status: "0 containers matching '*'\n").health == .unknown)
        #expect(ICloudStatus.parse(status: "", quota: "").driveOn == nil)
        #expect(ICloudStatus.parse(status: "").needsAttention == false)
    }

    @Test func quotaIsParsedAndUnknownQuotaIsNil() {
        #expect(ICloudStatus.parseQuota("89988765133 bytes of quota remaining in personal account") == 89_988_765_133)
        #expect(ICloudStatus.parseQuota("quota unavailable") == nil)
        #expect(ICloudStatus.parseQuota("") == nil)
        #expect(ICloudStatus.parse(status: Self.idle, quota: "5368709120 bytes of quota remaining").bytesRemaining == 5_368_709_120)
    }

    @Test func disabledSyncLineDoesNotCountAsOff() {
        // "SYNC DISABLED" is printed per uninstalled app; with areas listed, iCloud Drive is on.
        let status = ICloudStatus.parse(status: Self.pending)
        #expect(status.driveOn == true)
        #expect(status.health != .off)
    }
}
