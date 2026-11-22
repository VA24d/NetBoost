import Foundation

public enum VPNStatus: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error
}

public struct VPNRouteEntry: Codable, Sendable, Hashable, Equatable {
    public let destinationSubnet: String
    public let mask: String
    public let gateway: String?

    public init(destinationSubnet: String, mask: String, gateway: String? = nil) {
        self.destinationSubnet = destinationSubnet
        self.mask = mask
        self.gateway = gateway
    }
}

public struct VPNProfileInfo: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let serverAddress: String
    public let proto: String
    public let port: Int
    public let cipher: String?
    public let routes: [VPNRouteEntry]
    public let dnsServers: [String]
    public let isCampusSplit: Bool
    public let filePath: String?

    public init(
        name: String,
        serverAddress: String,
        proto: String = "udp",
        port: Int = 1194,
        cipher: String? = nil,
        routes: [VPNRouteEntry] = [],
        dnsServers: [String] = [],
        isCampusSplit: Bool = false,
        filePath: String? = nil
    ) {
        self.name = name
        self.serverAddress = serverAddress
        self.proto = proto
        self.port = port
        self.cipher = cipher
        self.routes = routes
        self.dnsServers = dnsServers
        self.isCampusSplit = isCampusSplit
        self.filePath = filePath
    }
}
