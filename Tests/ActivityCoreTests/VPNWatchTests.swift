import Foundation
import Testing
@testable import ActivityCore

@Suite("VPN watch")
struct VPNWatchTests {
    static let list = """
    Available network connection services in the current set (*=enabled):
    * (Connected)      A1B2C3D4-0000-4000-8000-000000000001 VPN (com.example.vpn) "Home VPN"                       [VPN:com.example.vpn]
    * (Disconnected)   11111111-2222-3333-4444-555555555555 VPN (com.wireguard.macos) "Work VPN"                           [VPN:com.wireguard.macos]
    """

    @Test func parsesNamesAndState() {
        let services = VPNWatch.parse(Self.list)
        #expect(services.map(\.name) == ["Home VPN", "Work VPN"])
        #expect(services.map(\.connected) == [true, false])
    }

    @Test func reportsOnlyADropThatLasts() {
        var watch = VPNWatch()
        let t0 = Date()
        let up = VPNWatch.Service(id: "a", name: "Work VPN", connected: true)
        let down = VPNWatch.Service(id: "a", name: "Work VPN", connected: false)
        #expect(watch.update([up], now: t0).isEmpty)
        #expect(watch.update([down], now: t0.addingTimeInterval(10)).isEmpty)
        // Back within a minute: nothing to report.
        #expect(watch.update([up], now: t0.addingTimeInterval(40)).isEmpty)
        #expect(watch.update([down], now: t0.addingTimeInterval(50)).isEmpty)
        #expect(watch.update([down], now: t0.addingTimeInterval(115)).map(\.name) == ["Work VPN"])
        // Reported once per drop.
        #expect(watch.update([down], now: t0.addingTimeInterval(200)).isEmpty)
    }

    @Test func aVPNThatWasNeverOnIsNotADrop() {
        var watch = VPNWatch()
        let off = VPNWatch.Service(id: "b", name: "Spare", connected: false)
        #expect(watch.update([off], now: Date()).isEmpty)
        #expect(watch.update([off], now: Date().addingTimeInterval(500)).isEmpty)
    }
}
