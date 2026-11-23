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

// MARK: - Network Environment State

public enum NetworkEnvironmentState: Sendable, Equatable, Hashable, Codable {
    case campusLAN(interface: String, ip: String, gateway: String, mtu: Int)
    case cellularHotspot(interface: String, ip: String, gateway: String, mtu: Int)
    case externalWiFi(interface: String, ip: String, gateway: String, mtu: Int)
    case disconnected

    public static var defaultCampusLAN: Self {
        .campusLAN(interface: "en10", ip: "10.1.36.52", gateway: "10.1.36.1", mtu: 1500)
    }

    public static var defaultCellularHotspot: Self {
        .cellularHotspot(interface: "en0", ip: "172.20.10.2", gateway: "172.20.10.1", mtu: 1280)
    }

    public static var defaultExternalWiFi: Self {
        .externalWiFi(interface: "en0", ip: "192.168.1.100", gateway: "192.168.1.1", mtu: 1500)
    }

    public static var offline: Self { .disconnected }

    public static func mobileHotspot(interface: String, ip: String, gateway: String, mtu: Int) -> Self {
        .cellularHotspot(interface: interface, ip: ip, gateway: gateway, mtu: mtu)
    }

    public var isCampusLAN: Bool {
        if case .campusLAN = self { return true }
        return false
    }

    public var isCellular: Bool {
        if case .cellularHotspot = self { return true }
        return false
    }

    public var isConnected: Bool {
        if case .disconnected = self { return false }
        return true
    }

    public var primaryInterface: String? {
        switch self {
        case .campusLAN(let iface, _, _, _): return iface
        case .cellularHotspot(let iface, _, _, _): return iface
        case .externalWiFi(let iface, _, _, _): return iface
        case .disconnected: return nil
        }
    }

    public var mtu: Int {
        switch self {
        case .campusLAN(_, _, _, let m): return m
        case .cellularHotspot(_, _, _, let m): return m
        case .externalWiFi(_, _, _, let m): return m
        case .disconnected: return 0
        }
    }
}

// MARK: - VPN Service Profile Model (scutil --nc list)

public struct VPNServiceProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: String { serviceID }
    public let serviceID: String
    public let name: String
    public let status: VPNStatus
    public let isDefault: Bool
    public let serviceType: String

    public init(serviceID: String, name: String, status: VPNStatus, isDefault: Bool = false, serviceType: String = "VPN") {
        self.serviceID = serviceID
        self.name = name
        self.status = status
        self.isDefault = isDefault
        self.serviceType = serviceType
    }
}

// MARK: - VPN Rule Action & Policy

public enum VPNAction: Equatable, Sendable {
    case connect(profile: String)
    case disconnect(profile: String)
    case quarantine(profile: String, reason: String)
    case none
}

public struct VPNRulePolicy: Sendable, Equatable {
    public var autoConnectEnabled: Bool
    public var promptBeforeDisconnect: Bool
    public var conflictOverride: Bool
    public var manualOverrideActive: Bool
    public var targetProfileName: String
    public var maxRetries: Int
    public var baseBackoffDelay: TimeInterval

    public init(
        autoConnectEnabled: Bool = true,
        promptBeforeDisconnect: Bool = false,
        conflictOverride: Bool = false,
        manualOverrideActive: Bool = false,
        targetProfileName: String = "macos.ovpn",
        maxRetries: Int = 3,
        baseBackoffDelay: TimeInterval = 1.0
    ) {
        self.autoConnectEnabled = autoConnectEnabled
        self.promptBeforeDisconnect = promptBeforeDisconnect
        self.conflictOverride = conflictOverride
        self.manualOverrideActive = manualOverrideActive
        self.targetProfileName = targetProfileName
        self.maxRetries = maxRetries
        self.baseBackoffDelay = baseBackoffDelay
    }
}

// MARK: - Route Conflict Models

public struct RouteConflictWarning: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let severity: IssueSeverity
    public let title: String
    public let conflictingSubnet: String
    public let localSubnet: String
    public let affectedGateway: String?
    public let affectedInterface: String?
    public let message: String
    public let recommendedFixAction: String

    public init(
        id: UUID = UUID(),
        severity: IssueSeverity,
        title: String,
        conflictingSubnet: String,
        localSubnet: String,
        affectedGateway: String? = nil,
        affectedInterface: String? = nil,
        message: String,
        recommendedFixAction: String
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.conflictingSubnet = conflictingSubnet
        self.localSubnet = localSubnet
        self.affectedGateway = affectedGateway
        self.affectedInterface = affectedInterface
        self.message = message
        self.recommendedFixAction = recommendedFixAction
    }

    public func asDetectedIssue() -> DetectedIssue {
        DetectedIssue(
            id: id,
            severity: severity,
            title: title,
            description: message,
            recommendedFixAction: recommendedFixAction,
            automatedFixAvailable: true
        )
    }
}

public struct RouteConflictReport: Codable, Sendable, Equatable {
    public let profileName: String
    public let hasConflicts: Bool
    public let warnings: [RouteConflictWarning]
    public let conflictDescriptions: [String]
    public let remediationAdvice: String?

    public init(
        profileName: String,
        warnings: [RouteConflictWarning] = [],
        conflictDescriptions: [String] = [],
        remediationAdvice: String? = nil
    ) {
        self.profileName = profileName
        self.warnings = warnings
        self.conflictDescriptions = conflictDescriptions
        self.hasConflicts = !warnings.isEmpty || !conflictDescriptions.isEmpty
        self.remediationAdvice = remediationAdvice
    }
}

// MARK: - VPN Controller Protocol Contract

public protocol VPNControllerProtocol: Sendable {
    func checkStatus(profileName: String) async -> VPNStatus
    func connect(profileName: String) async throws
    func disconnect(profileName: String) async throws
    func parseProfile(url: URL) throws -> VPNProfileInfo
    func detectConflicts(profile: VPNProfileInfo, currentLAN: String) -> [String]
}

