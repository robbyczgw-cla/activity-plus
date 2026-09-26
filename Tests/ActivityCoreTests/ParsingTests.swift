import Foundation
import Testing
@testable import ActivityCore

@Suite("Parsers")
struct ParsingTests {
    @Test func cpuTimeFormats() {
        #expect(ProcessSampler.parseCPUTime("0:00.50") == 0.5)
        #expect(ProcessSampler.parseCPUTime("1528:57.76") == 1528 * 60 + 57.76)
        #expect(ProcessSampler.parseCPUTime("1:02:03.00") == 3723)
        #expect(ProcessSampler.parseCPUTime("2-01:00:00.00") == 2 * 86_400 + 3600)
    }

    @Test func psLinesWithSpacesInPath() {
        let output = """
          417     1    88 1528:57.76 134576 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
          900   417   501   0:01.20   2048 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
        """
        let rows = ProcessSampler.parsePS(output)
        #expect(rows.count == 2)
        #expect(rows[0].pid == 417 && rows[0].uid == 88 && rows[0].residentBytes == 134_576 * 1024)
        #expect(rows[1].command == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        #expect(rows[1].ppid == 417)
    }

    @Test func nettopNamesWithDots() {
        let output = ",bytes_in,bytes_out,\nlaunchd.1,0,0,\ncom.apple.Safari.Web.4242,5120,880,\n"
        let parsed = ProcessNetworkSampler.parse(output)
        #expect(parsed[4242]?.0 == 5120)
        #expect(parsed[4242]?.1 == 880)
        #expect(parsed[1]?.0 == 0)
    }

    @Test func lsofListeners() {
        let output = "p4321\nf23\nn*:4321\nf24\nn127.0.0.1:4322\np88\nf5\nn[::1]:5432\n"
        let parsed = ProjectScanner.parseLsof(output)
        #expect(Set(parsed[4321]!.map(\.port)) == [4321, 4322])
        #expect(parsed[4321]!.contains { $0.address == "all interfaces" })
        #expect(parsed[88]!.first?.port == 5432)
    }

    @Test func gpuClientCreator() {
        #expect(GPUSampler.pid(fromCreator: "pid 417, WindowServer") == 417)
        #expect(GPUSampler.pid(fromCreator: "kernel") == nil)
    }

    @Test func formatting() {
        #expect(Format.memory(1_073_741_824) == "1.00 GB")
        #expect(Format.storage(994_660_000_000) == "995 GB")
        #expect(Format.rate(7_800_000) == "7.80 MB/s")
        #expect(Format.split("54.76 GB") == ("54.76", "GB"))
        #expect(Format.duration(3 * 86_400 + 4 * 3600) == "3d 4h")
    }
}

@Suite("Grouping")
struct GroupingTests {
    @Test func helpersResolveToOutermostApp() {
        let grouper = AppGrouper()
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(grouper.bundle(forExecutable: helper)?.path == "/Applications/Google Chrome.app")
        #expect(grouper.bundle(forExecutable: "/usr/bin/zsh") == nil)
    }

    @Test func systemAndToolClassification() {
        let daemon = ProcessSample(pid: 10, ppid: 1, uid: 0, name: "launchd", path: "/sbin/launchd", startTime: .now)
        let node = ProcessSample(pid: 11, ppid: 1, uid: 501, name: "node", path: "/opt/homebrew/bin/node", startTime: .now)
        #expect(AppGrouper.isSystemProcess(daemon))
        #expect(!AppGrouper.isSystemProcess(node))
    }
}

@Suite("Accessories")
struct AccessoryTests {
    @Test func airPodsAndMouseFromSystemProfiler() {
        let json = """
        {"SPBluetoothDataType":[{"controller_properties":{},
          "device_connected":[
            {"AirPods Pro":{"device_batteryLevelCase":"52%","device_batteryLevelLeft":"80%","device_batteryLevelRight":"78%","device_minorType":"Headphones"}},
            {"Magic Mouse":{"device_batteryLevelMain":"41%","device_minorType":"Mouse"}},
            {"Speaker":{"device_minorType":"Speaker"}}
          ],
          "device_not_connected":[{"Old":{"device_batteryLevelMain":"10%"}}]}]}
        """
        let devices = DeviceBatterySampler.parseBluetooth(Data(json.utf8))
        #expect(devices.count == 2)
        let pods = devices.first { $0.kind == "Headphones" }
        #expect(pods?.levels.count == 3)
        #expect(pods?.lowest == 52)
        #expect(devices.first { $0.name == "Magic Mouse" }?.levels.first?.percent == 41)
    }
}

@Suite("Connection quality")
struct ConnectionQualityTests {
    @Test func parsesPingSummary() throws {
        let out = """
        --- 10.0.0.1 ping statistics ---
        5 packets transmitted, 4 packets received, 20.0% packet loss
        round-trip min/avg/max/stddev = 2.859/27.390/76.234/34.538 ms
        """
        let r = try #require(ConnectionProbe.parse(out, target: "10.0.0.1", date: Date()))
        #expect(r.sent == 5 && r.received == 4)
        #expect(abs(r.lossPercent - 20) < 0.001)
        #expect(r.averageMs == 27.390 && r.jitterMs == 34.538)
        let down = try #require(ConnectionProbe.parse("3 packets transmitted, 0 packets received, 100.0% packet loss", target: "x", date: Date()))
        #expect(down.isOutage && down.averageMs == nil)
    }

    @Test func rejectsTargetsThatLookLikeOptions() {
        #expect(ConnectionProbe.isValidTarget("1.1.1.1"))
        #expect(ConnectionProbe.isValidTarget("fritz.box"))
        #expect(ConnectionProbe.isValidTarget("2606:4700:4700::1111"))
        for bad in ["", "-c 1000", "a b", "host;rm", "$(x)", "--flood"] { #expect(!ConnectionProbe.isValidTarget(bad)) }
    }
}

@Suite("Settings backup")
struct SettingsBackupTests {
    @Test func roundTripKeepsOwnKeysOnly() throws {
        let domain: [String: Any] = ["menuBarItems": Data([1, 2, 3]), "sampleInterval": 2.0, "perf.sensors": false,
                                     "NSWindow Frame main": "0 0 100 100", "SULastCheckTime": Date(), "settingsTab": "general"]
        let data = try SettingsBackup.export(domain)
        let back = try SettingsBackup.settings(from: data)
        #expect(Set(back.keys) == ["menuBarItems", "sampleInterval", "perf.sensors"])
        #expect(back["menuBarItems"] as? Data == Data([1, 2, 3]))
        #expect(back["sampleInterval"] as? Double == 2.0)
    }

    @Test func rejectsOtherFiles() {
        let other = try! PropertyListSerialization.data(fromPropertyList: ["hello": "world"], format: .xml, options: 0)
        #expect(throws: SettingsBackup.Failure.self) { try SettingsBackup.settings(from: other) }
        #expect(throws: (any Error).self) { try SettingsBackup.settings(from: Data("not a plist".utf8)) }
    }
}

@Suite("Process attribution")
struct ProcessAttributionTests {
    @Test func commandLinesAreShortAndSecretsHidden() {
        #expect(ProcessCommand.short(arguments: ["/usr/local/bin/node", "/Users/me/app/node_modules/.bin/vite", "--port", "5173"]) == "node vite --port 5173")
        #expect(ProcessCommand.short(arguments: ["gh", "--token", "ghp_abcdefghijklmnopqrstuvwxyz123456"]) == "gh --token •••")
        #expect(ProcessCommand.short(arguments: ["env", "OPENAI_API_KEY=sk-123", "python3", "run.py"]) == "env OPENAI_API_KEY=••• python3 run.py")
        #expect(ProcessCommand.short(arguments: ["curl", "https://bob:hunter2@example.com/x"]) == "curl https://•••@example.com/x")
        #expect(ProcessCommand.short(arguments: ["tool", "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8"]) == "tool •••")
        #expect(ProcessCommand.short(arguments: ["cargo", "build", "--release"]) == "cargo build --release")
        // Electron/Chromium helpers: keep the process type, drop paths and long flag values.
        #expect(ProcessCommand.short(arguments: ["/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
                                                 "--type=gpu-process", "--user-data-dir=/Users/me/Library/Application Support/Paseo",
                                                 "--enable-features=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,BBBB", "--lang=de"])
                == "Paseo Helper --type=gpu-process --user-data-dir=… --enable-features=… --lang=de")
    }

    @Test func historyTracesAnAppBackToItsChildProcess() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activityplus-procs-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let start = Date().addingTimeInterval(-900)
        // 6 minutes of Terminal with two children: node busy, zsh idle-ish.
        for step in 0..<180 {
            var s = SystemSnapshot()
            s.date = start.addingTimeInterval(Double(step) * 2)
            s.interval = 2
            var node = ProcessSample(pid: 900_001, ppid: 1, uid: 501, name: "node", path: "/usr/local/bin/node", startTime: .distantPast)
            node.cpuPercent = 120
            node.memory = 400_000_000
            var zsh = ProcessSample(pid: 900_002, ppid: 1, uid: 501, name: "zsh", path: "/bin/zsh", startTime: .distantPast)
            zsh.cpuPercent = 2
            zsh.memory = 10_000_000
            s.apps = [AppGroup(id: "/System/Applications/Utilities/Terminal.app", name: "Terminal", kind: .app,
                               bundlePath: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal", mainPID: nil, processes: [node, zsh])]
            store.record(s)
        }
        store.flush()
        let top = store.topProcesses(appID: "/System/Applications/Utilities/Terminal.app", from: start.addingTimeInterval(-60), to: Date())
        let first = try #require(top.first)
        #expect(first.name == "node")
        #expect(first.appName == "Terminal")
        #expect(first.averageCPU > 100)
        #expect(top.contains { $0.name == "zsh" })
        // flush() stamps the window with the current time.
        let around = store.processesAround(Date().addingTimeInterval(-30))
        #expect(around.first?.name == "node")
    }
}

