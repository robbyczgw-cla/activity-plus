import Foundation
import Network
import Testing
@testable import ActivityCore

@Suite("Prometheus text and node_exporter")
struct PrometheusTests {
    /// A trimmed node_exporter 1.x page of a small two-core server, written for the test.
    static let page = """
    # HELP node_boot_time_seconds Node boot time, in unixtime.
    # TYPE node_boot_time_seconds gauge
    node_boot_time_seconds 1.7e+09
    # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
    # TYPE node_cpu_seconds_total counter
    node_cpu_seconds_total{cpu="0",mode="idle"} 9000
    node_cpu_seconds_total{cpu="0",mode="iowait"} 50
    node_cpu_seconds_total{cpu="0",mode="irq"} 0
    node_cpu_seconds_total{cpu="0",mode="nice"} 10
    node_cpu_seconds_total{cpu="0",mode="softirq"} 5
    node_cpu_seconds_total{cpu="0",mode="steal"} 0
    node_cpu_seconds_total{cpu="0",mode="system"} 300
    node_cpu_seconds_total{cpu="0",mode="user"} 635
    node_cpu_seconds_total{cpu="1",mode="idle"} 9100
    node_cpu_seconds_total{cpu="1",mode="iowait"} 0
    node_cpu_seconds_total{cpu="1",mode="system"} 300
    node_cpu_seconds_total{cpu="1",mode="user"} 600
    # HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.
    # TYPE node_filesystem_avail_bytes gauge
    node_filesystem_avail_bytes{device="rootfs",fstype="rootfs",mountpoint="/"} 1
    node_filesystem_avail_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 4.0e+10
    node_filesystem_avail_bytes{device="/dev/sda15",fstype="vfat",mountpoint="/boot/efi"} 1.0e+08
    node_filesystem_size_bytes{device="/dev/sda1",fstype="ext4",mountpoint="/"} 1.0e+11
    node_filesystem_size_bytes{device="/dev/sda15",fstype="vfat",mountpoint="/boot/efi"} 1.1e+08
    # TYPE node_hwmon_temp_celsius gauge
    node_hwmon_temp_celsius{chip="platform_coretemp_0",sensor="temp1"} 48
    node_hwmon_temp_celsius{chip="platform_coretemp_0",sensor="temp2"} 52.5
    node_hwmon_temp_celsius{chip="acpi_0",sensor="temp9"} 0
    node_load1 0.42
    node_load5 0.3
    node_memory_MemAvailable_bytes 3.0e+09
    node_memory_MemTotal_bytes 8.0e+09
    node_network_receive_bytes_total{device="eth0"} 1000000
    node_network_receive_bytes_total{device="lo"} 99999999
    node_network_receive_bytes_total{device="docker0"} 5000
    node_network_receive_bytes_total{device="veth12ab"} 5000
    node_network_transmit_bytes_total{device="eth0"} 400000
    node_network_transmit_bytes_total{device="lo"} 99999999
    node_os_info{id="ubuntu",name="Ubuntu",pretty_name="Ubuntu 24.04 LTS",version_id="24.04"} 1
    node_time_seconds 1.7000864e+09
    node_uname_info{domainname="(none)",machine="x86_64",nodename="test-server",release="6.8.0",sysname="Linux",version="#1 SMP"} 1
    go_gc_duration_seconds{quantile="0.5"} NaN
    process_max_fds +Inf
    """

    @Test func parsesSamplesLabelsAndSpecialValues() {
        let samples = PrometheusText.parse(Self.page)
        #expect(samples.count == 36)
        let load = samples.first { $0.name == "node_load1" }
        #expect(load?.value == 0.42)
        #expect(load?.labels.isEmpty == true)
        let idle = samples.first { $0.name == "node_cpu_seconds_total" }
        #expect(idle?.labels == ["cpu": "0", "mode": "idle"])
        #expect(samples.first { $0.name == "go_gc_duration_seconds" }?.value.isNaN == true)
        #expect(samples.first { $0.name == "process_max_fds" }?.value == .infinity)
    }

    @Test func handlesEscapesTimestampsAndBrokenLines() {
        let text = #"""
        metric_a{path="C:\\dir",msg="say \"hi\"\nthere",empty=""} 1.5e3 1700000000000
          metric_b 7
        metric_c{unterminated="x} 1
        metric_d{a="1",} -2
        not a sample
        {nolabelname="x"} 1
        """#
        let samples = PrometheusText.parse(text)
        #expect(samples.map(\.name) == ["metric_a", "metric_b", "metric_d"])
        #expect(samples[0].labels["path"] == #"C:\dir"#)
        #expect(samples[0].labels["msg"] == "say \"hi\"\nthere")
        #expect(samples[0].labels["empty"] == "")
        #expect(samples[0].value == 1500)
        #expect(samples[2].value == -2)
    }

    @Test func readsWhatACardNeeds() {
        let reading = NodeExporterReading(text: Self.page)
        #expect(reading.cpuCount == 2)
        #expect(reading.cpuTotalSeconds == 20_000.0)
        // Everything except idle and iowait.
        #expect(reading.cpuBusySeconds == 1_850.0)
        #expect(reading.memoryTotal == 8_000_000_000)
        #expect(reading.memoryAvailable == 3_000_000_000)
        // The ext4 root, not the rootfs placeholder and not /boot/efi.
        #expect(reading.diskAvailable == 40_000_000_000)
        #expect(reading.diskSize == 100_000_000_000)
        // eth0 only: loopback and container interfaces are left out.
        #expect(reading.networkReceived == 1_000_000)
        #expect(reading.networkTransmitted == 400_000)
        #expect(reading.load1 == 0.42)
        #expect(reading.temperature == 52.5)
        #expect(reading.uptime == 86_400)
        #expect(reading.hostName == "test-server")
        #expect(reading.osName == "Ubuntu 24.04 LTS")

        let status = RemoteStatus(reading: reading, rates: nil)
        #expect(status.memoryUsed == 5_000_000_000)
        #expect(status.diskUsedFraction == 0.6)
        #expect(status.cpu == nil)
    }

    @Test func macOSAndBSDMemoryAndTunnels() {
        let text = """
        node_memory_total_bytes 3.4359738368e+10
        node_memory_free_bytes 7.0e+08
        node_memory_inactive_bytes 8.3e+09
        node_memory_purgeable_bytes 2.0e+08
        node_memory_active_bytes 8.4e+09
        node_network_receive_bytes_total{device="en0"} 500
        node_network_receive_bytes_total{device="lo0"} 900
        node_network_receive_bytes_total{device="utun3"} 400
        node_filesystem_size_bytes{device="/dev/disk3s3s1",fstype="apfs",mountpoint="/"} 4.9e+11
        """
        let reading = NodeExporterReading(text: text)
        #expect(reading.memoryTotal == 34_359_738_368)
        #expect(reading.memoryAvailable == 9_200_000_000)
        #expect(reading.networkReceived == 500)
        #expect(reading.networkTransmitted == 0)
        #expect(reading.diskSize == 490_000_000_000)
    }

    @Test func ratesFromTwoReadings() {
        var first = NodeExporterReading()
        first.cpuBusySeconds = 100
        first.cpuTotalSeconds = 1000
        first.networkReceived = 10_000
        first.networkTransmitted = 2_000
        var second = first
        // Two CPUs over 10 s = 20 CPU seconds, 5 of them busy: 25 %.
        second.cpuBusySeconds = 105
        second.cpuTotalSeconds = 1020
        second.networkReceived = 60_000
        second.networkTransmitted = 2_500
        let rates = NodeExporterRates(previous: first, current: second, interval: 10)
        #expect(rates.cpuPercent == 25)
        #expect(rates.receiveRate == 5_000)
        #expect(rates.transmitRate == 50)
    }

    @Test func aRestartedServerGivesNoRate() {
        var before = NodeExporterReading()
        before.cpuBusySeconds = 5000
        before.cpuTotalSeconds = 90000
        before.networkReceived = 1_000_000
        var after = NodeExporterReading()
        after.cpuBusySeconds = 3
        after.cpuTotalSeconds = 40
        after.networkReceived = 2_000
        let rates = NodeExporterRates(previous: before, current: after, interval: 10)
        #expect(rates.cpuPercent == nil)
        #expect(rates.receiveRate == nil)
        #expect(NodeExporterRates(previous: before, current: before, interval: 0).receiveRate == nil)
    }

    @Test func dechunksGoStyleResponses() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n7\r\nnode_lo\r\nA;ext=1\r\nad1 0.42\nx\r\n0\r\n\r\n".utf8)
        let response = try MiniHTTP.parseResponse(raw)
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8) == "node_load1 0.42\nx")
    }

    @Test func addressesPeopleType() throws {
        #expect(try RemoteMachine.parseAddress("server") == .init(host: "server", port: 9100, path: "/metrics"))
        #expect(try RemoteMachine.parseAddress(" http://10.0.0.5:9200/ ") == .init(host: "10.0.0.5", port: 9200, path: "/metrics"))
        #expect(try RemoteMachine.parseAddress("box.example:9100/custom/metrics") == .init(host: "box.example", port: 9100, path: "/custom/metrics"))
        #expect(try RemoteMachine.parseAddress("[fe80::1%en0]:9100") == .init(host: "fe80::1%en0", port: 9100, path: "/metrics"))
        #expect(try RemoteMachine.parseAddress("fd00::5") == .init(host: "fd00::5", port: 9100, path: "/metrics"))
        #expect(throws: RemoteMachine.AddressError.https) { try RemoteMachine.parseAddress("https://server:9100") }
        #expect(throws: RemoteMachine.AddressError.empty) { try RemoteMachine.parseAddress("  ") }
        #expect(throws: RemoteMachine.AddressError.invalid) { try RemoteMachine.parseAddress("server:0") }
        #expect(throws: RemoteMachine.AddressError.invalid) { try RemoteMachine.parseAddress("bad host") }
        let machine = RemoteMachine(kind: .nodeExporter, name: "x", host: "fd00::5", port: 9100, path: "/metrics")
        #expect(machine.address == "http://[fd00::5]:9100/metrics")
    }
}

@Suite("Sharing between Macs")
struct SharingTests {
    static func snapshot() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.date = Date(timeIntervalSince1970: 1_700_000_000)
        s.uptime = 3600
        s.cpu.user = 20
        s.cpu.system = 5
        s.cpu.perCore = [10, 20, 30, 40]
        s.cpu.loadAverage = (1.5, 1, 0.5)
        s.memory.total = 16 << 30
        s.memory.app = 6 << 30
        s.memory.wired = 2 << 30
        s.memory.pressure = .warning
        s.disk.total = 1_000_000_000_000
        s.disk.free = 250_000_000_000
        s.network.inRate = 1200
        s.sensors.cpuTemperature = 55
        s.thermal = .fair
        s.apps = (1...7).map { i in
            var app = AppGroup(id: "app\(i)", name: "App \(i)", kind: .app, bundlePath: nil, bundleID: nil, mainPID: nil, processes: [])
            app.cpuPercent = Double(i) * 3.14159
            app.memory = UInt64(8 - i) << 28
            return app
        }
        return s
    }

    @Test func summaryRoundTripsThroughJSON() throws {
        let summary = RemoteSummary(snapshot: Self.snapshot(), name: "Studio", model: "Mac mini", appVersion: "0.5")
        #expect(summary.cpu == 25)
        #expect(summary.cores == 4)
        #expect(summary.memory.used == 8 << 30)
        #expect(summary.memory.pressure == "warning")
        #expect(summary.thermal == "fair")
        #expect(summary.battery == nil)
        #expect(summary.topCPU.map(\.name) == ["App 7", "App 6", "App 5", "App 4", "App 3"])
        #expect(summary.topCPU.first?.cpu == 22)
        #expect(summary.topMemory.map(\.name) == ["App 1", "App 2", "App 3", "App 4", "App 5"])
        let decoded = try RemoteSummary.decode(summary.encoded())
        #expect(decoded == summary)
        let status = RemoteStatus(summary: decoded)
        #expect(status.temperature == 55)
        #expect(status.diskUsedFraction == 0.75)
        #expect(status.memoryFraction == 0.5)
    }

    @Test func summaryFromANewerAppIsRefused() throws {
        var summary = RemoteSummary(snapshot: Self.snapshot(), name: "a", model: "Mac", appVersion: "9")
        summary.schema = RemoteSummary.schema + 1
        let data = try summary.encoded()
        #expect(throws: (any Error).self) { try RemoteSummary.decode(data) }
    }

    @Test func tokensAreLongRandomAndOnlyStoredHashed() {
        let a = ShareToken.generate(), b = ShareToken.generate()
        #expect(a.count == 43)
        #expect(a != b)
        #expect(!a.contains("+") && !a.contains("/") && !a.contains("="))
        #expect(ShareToken.hash(a).count == 64)
        #expect(ShareToken.hash(a) != a)
        let viewer = PairedViewer(name: "Laptop", tokenHash: ShareToken.hash(a))
        #expect(ShareToken.viewer(for: a, in: [viewer])?.id == viewer.id)
        #expect(ShareToken.viewer(for: b, in: [viewer]) == nil)
        #expect(ShareToken.viewer(for: nil, in: [viewer]) == nil)
        #expect(ShareToken.viewer(for: "", in: [PairedViewer(name: "x", tokenHash: ShareToken.hash(""))]) == nil)
    }

    @Test func pairingCodeIsUsedOnceAndClosesAfterWrongGuesses() {
        let t0 = Date()
        var code = PairingCode(code: "042317", created: t0)
        #expect(code.check("123456", now: t0) == .wrong(remaining: 4))
        #expect(code.check("042 317", now: t0) == .accepted)
        #expect(code.check("042317", now: t0) == .closed)

        var guessed = PairingCode(code: "111111", created: t0)
        for _ in 0..<4 { _ = guessed.check("000000", now: t0) }
        #expect(guessed.check("000000", now: t0) == .closed)
        // Closed for good: even the right code no longer works.
        #expect(guessed.check("111111", now: t0) == .closed)

        var old = PairingCode(code: "222222", created: t0)
        #expect(old.check("222222", now: t0.addingTimeInterval(PairingCode.lifetime + 1)) == .closed)
        #expect(PairingCode.random().code.count == 6)
    }

    static func request(_ method: String, _ path: String, token: String? = nil, body: Data = Data()) -> MiniHTTP.Request {
        MiniHTTP.Request(method: method, path: path, headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:], body: body)
    }

    @Test func responderPairsServesAndRevokes() throws {
        let t0 = Date()
        var responder = ShareResponder(name: "Studio", appVersion: "0.5", pairing: PairingCode(code: "123456", created: t0))
        responder.makeToken = { "fixed-token-for-the-test" }
        let summary = Data(#"{"ok":true}"#.utf8)

        // No token, wrong token: nothing.
        #expect(responder.respond(to: Self.request("GET", "/v1/summary"), now: t0) { summary }.0.status == 401)
        #expect(responder.respond(to: Self.request("GET", "/v1/summary", token: "guess"), now: t0) { summary }.0.status == 401)

        let info = responder.respond(to: Self.request("GET", "/v1/info"), now: t0) { nil }.0
        #expect(try JSONDecoder().decode(ShareResponder.Info.self, from: info.body).pairing == true)

        let wrong = try JSONEncoder().encode(ShareResponder.PairRequest(code: "654321", name: "Laptop"))
        let (wrongResponse, wrongEvent) = responder.respond(to: Self.request("POST", "/v1/pair", body: wrong), now: t0) { nil }
        #expect(wrongResponse.status == 403)
        #expect(wrongEvent == .wrongCode)

        let right = try JSONEncoder().encode(ShareResponder.PairRequest(code: "123456", name: "Laptop"))
        let (paired, event) = responder.respond(to: Self.request("POST", "/v1/pair", body: right), now: t0) { nil }
        #expect(paired.status == 200)
        let answer = try JSONDecoder().decode(ShareResponder.PairResponse.self, from: paired.body)
        #expect(answer.token == "fixed-token-for-the-test")
        #expect(answer.name == "Studio")
        guard case .paired(let viewer) = event else { Issue.record("not paired"); return }
        #expect(viewer.name == "Laptop")
        #expect(viewer.tokenHash == ShareToken.hash(answer.token))
        #expect(!String(decoding: try JSONEncoder().encode(responder.viewers), as: UTF8.self).contains(answer.token))

        // The code is used up.
        #expect(responder.respond(to: Self.request("POST", "/v1/pair", body: right), now: t0) { nil }.0.status == 403)

        let (served, seen) = responder.respond(to: Self.request("GET", "/v1/summary", token: answer.token), now: t0) { summary }
        #expect(served.status == 200)
        #expect(served.body == summary)
        #expect(seen == .seen(viewer.id))

        // Removed in Settings: the token stops working.
        responder.viewers.removeAll { $0.id == viewer.id }
        #expect(responder.respond(to: Self.request("GET", "/v1/summary", token: answer.token), now: t0) { summary }.0.status == 401)
    }

    @Test func responderRefusesEverythingElse() {
        var responder = ShareResponder(name: "Studio", appVersion: "0.5")
        let pair = Data(#"{"code":"000000","name":"x"}"#.utf8)
        #expect(responder.respond(to: Self.request("POST", "/v1/pair", body: pair)) { nil }.0.status == 403)
        #expect(responder.respond(to: Self.request("DELETE", "/v1/summary")) { nil }.0.status == 405)
        #expect(responder.respond(to: Self.request("POST", "/v1/summary")) { nil }.0.status == 405)
        #expect(responder.respond(to: Self.request("GET", "/v1/kill")) { nil }.0.status == 404)
        #expect(responder.respond(to: Self.request("GET", "/")) { nil }.0.status == 404)
    }

    @Test func parsesRequestsIncrementallyAndRejectsJunk() throws {
        let full = Data("POST /v1/pair HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\nContent-Length: 4\r\n\r\nbody".utf8)
        #expect(try MiniHTTP.parseRequest(full.prefix(20)) == nil)
        #expect(try MiniHTTP.parseRequest(full.prefix(full.count - 1)) == nil)
        let request = try #require(try MiniHTTP.parseRequest(full))
        #expect(request.method == "POST")
        #expect(request.bearerToken == "abc")
        #expect(request.body == Data("body".utf8))
        #expect(throws: MiniHTTP.ParseError.malformed) { try MiniHTTP.parseRequest(Data("NONSENSE\r\n\r\n".utf8)) }
        #expect(throws: MiniHTTP.ParseError.tooLarge) { try MiniHTTP.parseRequest(Data(count: MiniHTTP.maxRequestSize + 1)) }
        #expect(throws: MiniHTTP.ParseError.tooLarge) {
            try MiniHTTP.parseRequest(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8))
        }
        let response = try MiniHTTP.parseResponse(MiniHTTP.Response.error(401, "not paired").serialized())
        #expect(response.status == 401)
        #expect(response.headers["connection"] == "close")
    }

    /// A real listener on 127.0.0.1 (loopback needs no local-network permission) and a real client.
    @Test func endToEndOverLoopback() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var responder = ShareResponder(name: "Loopback", appVersion: "test", pairing: PairingCode(code: "765432"))
        }
        let box = Box()
        let summary = try RemoteSummary(snapshot: Self.snapshot(), name: "Loopback", model: "Mac", appVersion: "test").encoded()
        let server = MiniHTTPServer { request, reply in
            box.lock.lock()
            let (response, _) = box.responder.respond(to: request) { summary }
            box.lock.unlock()
            reply(response)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once<Result<UInt16, Error>>()
            once.setHandler { continuation.resume(with: $0) }
            server.start(port: 0, loopbackOnly: true) { state in
                switch state {
                case .listening(let port): once.fire(.success(port))
                case .failed(let reason): once.fire(.failure(MiniHTTPClient.Failure.unreachable(reason)))
                default: break
                }
            }
        }
        defer { server.stop() }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let denied = try await MiniHTTPClient.send(Self.request("GET", "/v1/summary", token: "nope"), to: endpoint, host: "127.0.0.1")
        #expect(denied.status == 401)

        let body = try JSONEncoder().encode(ShareResponder.PairRequest(code: "765432", name: "Viewer"))
        let paired = try await MiniHTTPClient.send(Self.request("POST", "/v1/pair", body: body), to: endpoint, host: "127.0.0.1")
        #expect(paired.status == 200)
        let token = try JSONDecoder().decode(ShareResponder.PairResponse.self, from: paired.body).token

        let served = try await MiniHTTPClient.send(Self.request("GET", "/v1/summary", token: token), to: endpoint, host: "127.0.0.1")
        #expect(served.status == 200)
        #expect(try RemoteSummary.decode(served.body).topCPU.count == 5)

        box.lock.withLock { box.responder.viewers.removeAll() }
        let revoked = try await MiniHTTPClient.send(Self.request("GET", "/v1/summary", token: token), to: endpoint, host: "127.0.0.1")
        #expect(revoked.status == 401)
    }
}
