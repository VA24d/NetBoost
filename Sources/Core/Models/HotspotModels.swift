import Foundation

public struct HotspotClient: Codable, Sendable, Identifiable, Equatable {
    public var id: String { macAddress }
    public let macAddress: String
    public let ipAddress: String
    public let hostname: String?
    public let connectedAt: Date
    public var txBytes: UInt64
    public var rxBytes: UInt64

    public init(
        macAddress: String,
        ipAddress: String,
        hostname: String? = nil,
        connectedAt: Date = Date(),
        txBytes: UInt64 = 0,
        rxBytes: UInt64 = 0
    ) {
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.hostname = hostname
        self.connectedAt = connectedAt
        self.txBytes = txBytes
        self.rxBytes = rxBytes
    }
}

public struct DHCPLease: Codable, Sendable, Identifiable, Equatable {
    public var id: String { ipAddress }
    public let ipAddress: String
    public let macAddress: String
    public let hostname: String?
    public let leaseStart: Date
    public let leaseDuration: TimeInterval

    public var expiresAt: Date {
        leaseStart.addingTimeInterval(leaseDuration)
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }

    public init(
        ipAddress: String,
        macAddress: String,
        hostname: String? = nil,
        leaseStart: Date = Date(),
        leaseDuration: TimeInterval = 86400
    ) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.hostname = hostname
        self.leaseStart = leaseStart
        self.leaseDuration = leaseDuration
    }
}

public enum HotspotSecurityType: String, Codable, Sendable, CaseIterable, Identifiable {
    case wpa3Personal = "WPA3 Personal (SAE)"
    case wpa2Wpa3Transition = "WPA2/WPA3 Transition"
    case wpa2Personal = "WPA2 Personal"

    public var id: String { rawValue }
}

public struct HotspotConfiguration: Codable, Sendable, Equatable {
    public var ssid: String
    public var password: String
    public var securityType: HotspotSecurityType
    public var subnet: String
    public var gateway: String
    public var dhcpRangeStart: String
    public var dhcpRangeEnd: String
    public var interfaceName: String
    public var upstreamInterface: String
    public var isActive: Bool

    public init(
        ssid: String = "NetBoost",
        password: String = "12345678",
        securityType: HotspotSecurityType = .wpa2Wpa3Transition,
        subnet: String = "192.168.2.0/24",
        gateway: String = "192.168.2.1",
        dhcpRangeStart: String = "192.168.2.10",
        dhcpRangeEnd: String = "192.168.2.100",
        interfaceName: String = "en0",
        upstreamInterface: String = "en10",
        isActive: Bool = false
    ) {
        self.ssid = ssid
        self.password = password
        self.securityType = securityType
        self.subnet = subnet
        self.gateway = gateway
        self.dhcpRangeStart = dhcpRangeStart
        self.dhcpRangeEnd = dhcpRangeEnd
        self.interfaceName = interfaceName
        self.upstreamInterface = upstreamInterface
        self.isActive = isActive
    }

    public static let `default` = HotspotConfiguration()
}
