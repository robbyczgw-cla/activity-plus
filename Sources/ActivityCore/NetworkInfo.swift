import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

public struct NetworkInterfaceInfo: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable { case wifi, ethernet, cellular, vpn, other }

    public let id: String
    public let displayName: String
    public let kind: Kind
    public let isPrimary: Bool
    public let ipv4: [String]
    public let ipv6: [String]
    public let macAddress: String?
    public let isUp: Bool
}

public struct WiFiInfo: Sendable, Hashable {
    public let ssid: String?
    public let rssi: Int?
    public let noise: Int?
    public let channel: Int?
    public let band: String?
    public let transmitRateMbps: Double?
}

public enum NetworkInfo {
    private struct AddressSet {
        var ipv4: [String] = []
        var ipv6: [String] = []
        var macAddress: String?
        var flags: UInt32 = 0
    }

    public static func interfaces() -> [NetworkInterfaceInfo] {
        let primary = stringValue(dynamicValue("State:/Network/Global/IPv4", key: "PrimaryInterface"))
        var addresses: [String: AddressSet] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let namePointer = item.pointee.ifa_name,
                  let address = item.pointee.ifa_addr else { continue }
            let name = String(cString: namePointer)
            var entry = addresses[name, default: AddressSet()]
            entry.flags = item.pointee.ifa_flags
            switch Int32(address.pointee.sa_family) {
            case AF_INET, AF_INET6:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if address.pointee.sa_family == sa_family_t(AF_INET) {
                        if !entry.ipv4.contains(value) { entry.ipv4.append(value) }
                    } else if !entry.ipv6.contains(value) { entry.ipv6.append(value) }
                }
            case AF_LINK:
                let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                let count = Int(link.sdl_alen)
                if count > 0 {
                    let bytes = withUnsafePointer(to: link.sdl_data) { pointer in
                        pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: link.sdl_data)) {
                            Array(UnsafeBufferPointer(start: $0.advanced(by: Int(link.sdl_nlen)), count: min(count, MemoryLayout.size(ofValue: link.sdl_data) - Int(link.sdl_nlen))))
                        }
                    }
                    if bytes.count == count {
                        entry.macAddress = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                }
            default: break
            }
            addresses[name] = entry
        }

        let configured = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        var byBSDName: [String: SCNetworkInterface] = [:]
        for interface in configured {
            if let name = SCNetworkInterfaceGetBSDName(interface) { byBSDName[name as String] = interface }
        }

        return addresses.keys.sorted().compactMap { name in
            guard let info = addresses[name] else { return nil }
            let scInterface = byBSDName[name]
            let display = scInterface.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? fallbackName(name)
            let type = scInterface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            let kind = interfaceKind(name: name, displayName: display, type: type)
            let globalV6 = info.ipv6.filter { !$0.lowercased().hasPrefix("fe80:") }
            return NetworkInterfaceInfo(
                id: name, displayName: display, kind: kind, isPrimary: name == primary,
                ipv4: info.ipv4.sorted(), ipv6: (globalV6.isEmpty ? info.ipv6 : globalV6).sorted(),
                macAddress: info.macAddress, isUp: info.flags & UInt32(IFF_UP) != 0
            )
        }
    }

    public static func wifi() -> WiFiInfo? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let wlanChannel = interface.wlanChannel()
        let channel = wlanChannel?.channelNumber
        let band: String? = wlanChannel.flatMap {
            switch $0.channelBand {
            case .band2GHz: "2.4 GHz"
            case .band5GHz: "5 GHz"
            case .band6GHz: "6 GHz"
            case .bandUnknown: Optional<String>.none
            @unknown default: Optional<String>.none
            }
        }
        return WiFiInfo(ssid: interface.ssid(), rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
                        channel: channel, band: band, transmitRateMbps: interface.transmitRate())
    }

    public static func primaryGateway() -> String? {
        stringValue(dynamicValue("State:/Network/Global/IPv4", key: "Router"))
    }

    public static func publicIP(timeout: TimeInterval = 5) async -> String? {
        for endpoint in ["https://api.ipify.org", "https://icanhazip.com"] {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = max(0.1, timeout)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !result.isEmpty else { continue }
                return result
            } catch { continue }
        }
        return nil
    }

    public static func dnsServers() -> [String] {
        guard let dictionary = dynamicValue("State:/Network/Global/DNS", key: nil) as? [String: Any],
              let servers = dictionary[kSCPropNetDNSServerAddresses as String] as? [String] else { return [] }
        return servers
    }

    private static func dynamicValue(_ key: String, key subkey: String?) -> Any? {
        guard let store = SCDynamicStoreCreate(nil, "ActivityPlus.NetworkInfo" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { return nil }
        return subkey.flatMap { value[$0] } ?? (subkey == nil ? value : nil)
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func fallbackName(_ name: String) -> String {
        if name == "en0" { return "Wi-Fi" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "VPN" }
        if name.hasPrefix("bridge") { return "Bridge" }
        if name.hasPrefix("en") { return "Ethernet" }
        return name
    }

    private static func interfaceKind(name: String, displayName: String, type: String?) -> NetworkInterfaceInfo.Kind {
        let lower = displayName.lowercased()
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || lower.contains("vpn") { return .vpn }
        if lower.contains("iphone") || lower.contains("cellular") || lower.contains("mobile") { return .cellular }
        if type == (kSCNetworkInterfaceTypeIEEE80211 as String) || lower == "wi-fi" || lower == "wifi" { return .wifi }
        if type == (kSCNetworkInterfaceTypeEthernet as String) || lower.contains("ethernet") || lower.contains("thunderbolt") { return .ethernet }
        return .other
    }
}
