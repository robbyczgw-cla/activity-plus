import Foundation

/// What the app hands to its desktop and Notification Center widgets: a few readings, already
/// formatted with the user's units and locale, so the widget extension never samples anything itself.
/// Written as JSON into the App Group container (see `WidgetStore`).
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// One figure: the formatted value, an optional 0…1 share for rings and bars, and a short detail line.
    public struct Reading: Codable, Sendable, Equatable {
        public var text: String
        public var fraction: Double?
        public var detail: String?

        public init(text: String, fraction: Double? = nil, detail: String? = nil) {
            self.text = text
            self.fraction = fraction.map { min(1, max(0, $0)) }
            self.detail = detail
        }
    }

    public struct App: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var cpuText: String
        public var memoryText: String
        public var cpuPercent: Double
        /// A small PNG of the app's icon (64 px), so the sandboxed extension needs no file access.
        public var icon: Data?
        /// SF Symbol for groups without an icon of their own (macOS itself, command-line tools).
        public var symbol: String?

        public init(id: String, name: String, cpuText: String, memoryText: String, cpuPercent: Double,
                    icon: Data? = nil, symbol: String? = nil) {
            self.id = id
            self.name = name
            self.cpuText = cpuText
            self.memoryText = memoryText
            self.cpuPercent = cpuPercent
            self.icon = icon
            self.symbol = symbol
        }
    }

    /// Mirrors ActivityCore's MemoryPressure (1 normal, 2 elevated, 4 critical).
    public enum Pressure: Int, Codable, Sendable { case normal = 1, warning = 2, critical = 4 }

    public var date: Date
    public var cpu: Reading
    public var memory: Reading
    public var memoryPressure: Pressure
    public var gpu: Reading?
    /// Fraction is the used share of the startup disk; text is the free space.
    public var disk: Reading
    public var networkIn: Reading
    public var networkOut: Reading
    /// Fraction maps 0…100 °C, so the ring fills as the chip heats up.
    public var temperature: Reading?
    public var temperatureCelsius: Double?
    public var battery: Reading?
    public var batteryCharging: Bool
    public var topApps: [App]

    public init(date: Date, cpu: Reading, memory: Reading, memoryPressure: Pressure, gpu: Reading?, disk: Reading,
                networkIn: Reading, networkOut: Reading, temperature: Reading?, temperatureCelsius: Double?,
                battery: Reading?, batteryCharging: Bool, topApps: [App]) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.memoryPressure = memoryPressure
        self.gpu = gpu
        self.disk = disk
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.temperature = temperature
        self.temperatureCelsius = temperatureCelsius
        self.battery = battery
        self.batteryCharging = batteryCharging
        self.topApps = topApps
    }

    /// Older than this, the app has most likely quit: widgets say so instead of showing old numbers as live.
    public static let staleAfter: TimeInterval = 15 * 60

    public func isStale(at now: Date = Date()) -> Bool { now.timeIntervalSince(date) > Self.staleAfter }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// The metrics a small widget can show, chosen in the widget's configuration.
public enum WidgetMetric: String, CaseIterable, Codable, Sendable {
    case cpu, memory, gpu, disk, network, temperature, battery
}

/// Where the snapshot lives. macOS (also for Developer ID apps outside the App Store) authorizes an App
/// Group whose identifier starts with the signing team ID without a provisioning profile; the iOS-style
/// "group." prefix would need one.
public enum WidgetStore {
    public static let appGroup = "P35939S43T.at.hifiteam.activityplus"
    public static let fileName = "widget-snapshot.json"
    /// WidgetKit `kind` strings; changing one drops widgets people already placed.
    public static let metricKind = "at.hifiteam.activityplus.widget.metric"
    public static let overviewKind = "at.hifiteam.activityplus.widget.overview"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static func fileURL(in container: URL? = containerURL) -> URL? {
        container?.appendingPathComponent(fileName)
    }

    public static func read(from url: URL? = fileURL()) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? WidgetSnapshot.decode(data)
    }

    /// Atomic, so the widget never reads a half-written file.
    public static func write(_ snapshot: WidgetSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try snapshot.encoded().write(to: url, options: .atomic)
    }
}
