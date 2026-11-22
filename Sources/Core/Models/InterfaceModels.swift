import Foundation

public enum IPVersion: String, Codable, Sendable {
    case v4
    case v6
}

public struct IPAddress: Codable, Sendable, Hashable, Equatable {
    public let address: String
    public let version: IPVersion
    public let netmask: String?
    public let prefixLength: Int?

    public init(address: String, version: IPVersion? = nil, netmask: String? = nil, prefixLength: Int? = nil) {
        self.address = address
        if let version = version {
            self.version = version
        } else {
            self.version = address.contains(":") ? .v6 : .v4
        }
        self.netmask = netmask
        self.prefixLength = prefixLength
    }
}

public struct NetworkInterfaceInfo: Codable, Sendable, Identifiable, Hashable, Equatable {
    public var id: String { bsdName }
    public let bsdName: String
    public let displayName: String
    public let ipAddresses: [IPAddress]
    public let macAddress: String?
    public let gateway: String?
    public let mtu: Int
    public let isPrimary: Bool
    public let isUp: Bool

    public init(
        bsdName: String,
        displayName: String,
        ipAddresses: [IPAddress] = [],
        macAddress: String? = nil,
        gateway: String? = nil,
        mtu: Int = 1500,
        isPrimary: Bool = false,
        isUp: Bool = true
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.ipAddresses = ipAddresses
        self.macAddress = macAddress
        self.gateway = gateway
        self.mtu = mtu
        self.isPrimary = isPrimary
        self.isUp = isUp
    }

    public var ipv4Address: String? {
        ipAddresses.first(where: { $0.version == .v4 })?.address
    }

    public var ipv6Address: String? {
        ipAddresses.first(where: { $0.version == .v6 })?.address
    }
}
