import Foundation

/// The Prometheus text exposition format (what `/metrics` of node_exporter returns):
/// `# HELP`/`# TYPE` comments and one sample per line, `name{label="value",…} 123.4 [timestamp]`.
public enum PrometheusText {
    public struct Sample: Sendable, Hashable {
        public var name: String
        public var labels: [String: String]
        public var value: Double

        public init(name: String, labels: [String: String] = [:], value: Double) {
            self.name = name
            self.labels = labels
            self.value = value
        }
    }

    /// Every sample in the text. Lines that do not parse are skipped instead of failing the whole page.
    public static func parse(_ text: String) -> [Sample] {
        var samples: [Sample] = []
        samples.reserveCapacity(1024)
        text.enumerateLines { line, _ in
            if let sample = parseLine(Substring(line)) { samples.append(sample) }
        }
        return samples
    }

    static func parseLine(_ raw: Substring) -> Sample? {
        let line = raw.drop { $0 == " " || $0 == "\t" }
        guard let first = line.first, first != "#" else { return nil }
        var index = line.startIndex
        // Metric name: [a-zA-Z_:][a-zA-Z0-9_:]*
        while index < line.endIndex, isNameCharacter(line[index]) { index = line.index(after: index) }
        guard index > line.startIndex else { return nil }
        let name = String(line[line.startIndex..<index])
        var labels: [String: String] = [:]
        if index < line.endIndex, line[index] == "{" {
            guard let (parsed, end) = parseLabels(line, from: line.index(after: index)) else { return nil }
            labels = parsed
            index = end
        }
        let rest = line[index...].split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let valueText = rest.first, let value = parseValue(valueText) else { return nil }
        return Sample(name: name, labels: labels, value: value)
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c == "_" || c == ":" || (c.isASCII && (c.isLetter || c.isNumber))
    }

    /// Parses `label="value",…}` starting after the `{`; returns the labels and the index after the `}`.
    private static func parseLabels(_ line: Substring, from start: Substring.Index) -> ([String: String], Substring.Index)? {
        var labels: [String: String] = [:]
        var index = start
        func skipSpaces() { while index < line.endIndex, line[index] == " " || line[index] == "," { index = line.index(after: index) } }
        while true {
            skipSpaces()
            guard index < line.endIndex else { return nil }
            if line[index] == "}" { return (labels, line.index(after: index)) }
            let nameStart = index
            while index < line.endIndex, isNameCharacter(line[index]) { index = line.index(after: index) }
            let labelName = String(line[nameStart..<index])
            guard !labelName.isEmpty, index < line.endIndex, line[index] == "=" else { return nil }
            index = line.index(after: index)
            guard index < line.endIndex, line[index] == "\"" else { return nil }
            index = line.index(after: index)
            var value = ""
            var closed = false
            while index < line.endIndex {
                let c = line[index]
                if c == "\\" {
                    index = line.index(after: index)
                    guard index < line.endIndex else { return nil }
                    switch line[index] {
                    case "n": value.append("\n")
                    case "\\": value.append("\\")
                    case "\"": value.append("\"")
                    default: value.append("\\"); value.append(line[index])
                    }
                } else if c == "\"" {
                    closed = true
                    index = line.index(after: index)
                    break
                } else {
                    value.append(c)
                }
                index = line.index(after: index)
            }
            guard closed else { return nil }
            labels[labelName] = value
        }
    }

    static func parseValue(_ text: Substring) -> Double? {
        switch text {
        case "NaN": return .nan
        case "+Inf", "Inf": return .infinity
        case "-Inf": return -.infinity
        default: return Double(text)
        }
    }
}

/// What a Linux (or other) server's node_exporter reports, reduced to what a card shows.
/// Counters (CPU seconds, network bytes) only turn into rates with a second reading; see `NodeExporterRates`.
public struct NodeExporterReading: Sendable, Equatable {
    /// CPU seconds since boot, summed over all CPUs: busy (everything except idle and iowait) and total.
    public var cpuBusySeconds: Double?
    public var cpuTotalSeconds: Double?
    public var cpuCount: Int = 0
    public var memoryTotal: UInt64?
    public var memoryAvailable: UInt64?
    /// The root file system ("/").
    public var diskSize: UInt64?
    public var diskAvailable: UInt64?
    /// Bytes since boot over physical interfaces (loopback and container bridges left out).
    public var networkReceived: Double?
    public var networkTransmitted: Double?
    public var load1: Double?
    /// The hottest hardware-monitor or thermal-zone sensor, °C.
    public var temperature: Double?
    public var bootTime: Double?
    /// The server's own clock, so uptime does not depend on the two clocks agreeing.
    public var serverTime: Double?
    /// From node_uname_info / node_os_info.
    public var hostName: String?
    public var osName: String?

    public init() {}

    public var uptime: TimeInterval? {
        guard let bootTime, bootTime > 0 else { return nil }
        let now = serverTime ?? Date().timeIntervalSince1970
        return max(0, now - bootTime)
    }

    /// Interfaces that only carry traffic between containers or the host itself: counting them would count bytes twice.
    static let virtualInterfacePrefixes = ["lo", "veth", "docker", "br-", "virbr", "cni", "flannel", "cali", "lxc", "tap", "vnet", "kube"]

    public init(samples: [PrometheusText.Sample]) {
        var busy = 0.0, total = 0.0, sawCPU = false
        var cpus = Set<String>()
        var received = 0.0, transmitted = 0.0, sawNetwork = false
        var hottest: Double?
        var thermalZone: Double?
        var rootSize: UInt64?, rootAvail: UInt64?
        for sample in samples {
            switch sample.name {
            case "node_cpu_seconds_total":
                guard sample.value.isFinite else { continue }
                sawCPU = true
                total += sample.value
                if let cpu = sample.labels["cpu"] { cpus.insert(cpu) }
                let mode = sample.labels["mode"] ?? ""
                if mode != "idle", mode != "iowait" { busy += sample.value }
            case "node_memory_MemTotal_bytes":
                memoryTotal = Self.bytes(sample.value)
            case "node_memory_MemAvailable_bytes":
                memoryAvailable = Self.bytes(sample.value)
            case "node_filesystem_size_bytes", "node_filesystem_avail_bytes":
                guard sample.labels["mountpoint"] == "/", sample.labels["fstype"] != "rootfs" else { continue }
                if sample.name == "node_filesystem_size_bytes" { rootSize = Self.bytes(sample.value) } else { rootAvail = Self.bytes(sample.value) }
            case "node_network_receive_bytes_total", "node_network_transmit_bytes_total":
                let device = sample.labels["device"] ?? ""
                guard !Self.virtualInterfacePrefixes.contains(where: { device.hasPrefix($0) }) else { continue }
                sawNetwork = true
                if sample.name == "node_network_receive_bytes_total" { received += sample.value } else { transmitted += sample.value }
            case "node_load1":
                load1 = sample.value
            case "node_hwmon_temp_celsius":
                // Some chips report 0 or absurd values for unconnected inputs.
                guard sample.value > 0, sample.value < 150 else { continue }
                hottest = max(hottest ?? sample.value, sample.value)
            case "node_thermal_zone_temp":
                guard sample.value > 0, sample.value < 150 else { continue }
                thermalZone = max(thermalZone ?? sample.value, sample.value)
            case "node_boot_time_seconds":
                bootTime = sample.value
            case "node_time_seconds":
                serverTime = sample.value
            case "node_uname_info":
                hostName = sample.labels["nodename"].flatMap { $0.isEmpty ? nil : $0 }
                if osName == nil { osName = sample.labels["sysname"] }
            case "node_os_info":
                if let pretty = sample.labels["pretty_name"], !pretty.isEmpty { osName = pretty }
            default:
                continue
            }
        }
        if sawCPU {
            cpuBusySeconds = busy
            cpuTotalSeconds = total
            cpuCount = cpus.count
        }
        if sawNetwork {
            networkReceived = received
            networkTransmitted = transmitted
        }
        diskSize = rootSize
        diskAvailable = rootAvail
        temperature = hottest ?? thermalZone
    }

    public init(text: String) { self.init(samples: PrometheusText.parse(text)) }

    static func bytes(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? .max : UInt64(value)
    }
}

/// Rates from two node_exporter readings taken `interval` seconds apart.
public struct NodeExporterRates: Sendable, Equatable {
    /// 0…100 of the whole machine.
    public var cpuPercent: Double?
    public var receiveRate: Double?
    public var transmitRate: Double?

    public init(cpuPercent: Double? = nil, receiveRate: Double? = nil, transmitRate: Double? = nil) {
        self.cpuPercent = cpuPercent
        self.receiveRate = receiveRate
        self.transmitRate = transmitRate
    }

    /// A counter that went down means the server restarted (or an interface vanished): no rate this time.
    public init(previous: NodeExporterReading, current: NodeExporterReading, interval: TimeInterval) {
        if let busy0 = previous.cpuBusySeconds, let busy1 = current.cpuBusySeconds,
           let total0 = previous.cpuTotalSeconds, let total1 = current.cpuTotalSeconds,
           total1 > total0, busy1 >= busy0 {
            cpuPercent = min(100, max(0, (busy1 - busy0) / (total1 - total0) * 100))
        }
        guard interval > 0 else { return }
        if let rx0 = previous.networkReceived, let rx1 = current.networkReceived, rx1 >= rx0 {
            receiveRate = (rx1 - rx0) / interval
        }
        if let tx0 = previous.networkTransmitted, let tx1 = current.networkTransmitted, tx1 >= tx0 {
            transmitRate = (tx1 - tx0) / interval
        }
    }
}
