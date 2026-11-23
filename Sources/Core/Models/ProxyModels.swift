import Foundation

public enum ProxyProtocolType: String, Codable, Sendable, CaseIterable {
    case socks5
    case httpConnect
    case httpDirect
}

public enum ProxyPortMode: String, Codable, Sendable, CaseIterable {
    case direct
    case loadBalanced
}

public struct ProxyPortConfiguration: Codable, Sendable, Identifiable, Equatable {
    public var id: Int { port }
    public let port: Int
    public let targetInterface: String // "en10", "en0", "auto"
    public let mode: ProxyPortMode
    public let label: String

    public init(port: Int, targetInterface: String, mode: ProxyPortMode = .direct, label: String = "") {
        self.port = port
        self.targetInterface = targetInterface
        self.mode = mode
        self.label = label
    }
}

public struct ProxyConnectionInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let port: Int
    public let clientAddress: String
    public let targetHost: String
    public let targetPort: Int
    public let egressInterface: String
    public let protocolType: ProxyProtocolType
    public let bytesRead: Int64
    public let bytesWritten: Int64
    public let startTime: Date
    public var duration: TimeInterval { Date().timeIntervalSince(startTime) }

    public init(
        id: UUID = UUID(),
        port: Int,
        clientAddress: String,
        targetHost: String,
        targetPort: Int,
        egressInterface: String,
        protocolType: ProxyProtocolType,
        bytesRead: Int64 = 0,
        bytesWritten: Int64 = 0,
        startTime: Date = Date()
    ) {
        self.id = id
        self.port = port
        self.clientAddress = clientAddress
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.egressInterface = egressInterface
        self.protocolType = protocolType
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.startTime = startTime
    }
}

public protocol ProxyDispatcherProtocol: Sendable {
    func start(ports: [Int: String]) async throws
    func stop() async throws
    var activeConnections: [ProxyConnectionInfo] { get }
    func generateShellSnippet(port: Int) -> String
}

public struct PinnedRoute: Codable, Sendable, Identifiable, Equatable {
    public var id: String { subnet }
    public let subnet: String
    public let netmask: String
    public let gateway: String
    public let interface: String
    public let isActive: Bool

    public init(subnet: String, netmask: String = "255.255.0.0", gateway: String, interface: String, isActive: Bool = true) {
        self.subnet = subnet
        self.netmask = netmask
        self.gateway = gateway
        self.interface = interface
        self.isActive = isActive
    }
}

public struct RoutePinningResult: Codable, Sendable, Equatable {
    public let success: Bool
    public let subnet: String
    public let gateway: String
    public let interface: String
    public let message: String
    public let manualCommand: String?

    public init(success: Bool, subnet: String, gateway: String, interface: String, message: String, manualCommand: String? = nil) {
        self.success = success
        self.subnet = subnet
        self.gateway = gateway
        self.interface = interface
        self.message = message
        self.manualCommand = manualCommand
    }
}

public enum ProxyError: Error, LocalizedError, Sendable, Equatable {
    case portAlreadyInUse(Int)
    case bindFailed(port: Int, errno: Int32)
    case invalidSOCKSVersion(UInt8)
    case unsupportedAuthMethod
    case connectionFailed(String)
    case targetUnreachable(String)
    case timeout
    case headerTooLarge
    case malformedRequest(String)

    public var errorDescription: String? {
        switch self {
        case .portAlreadyInUse(let p):
            return "Port \(p) is already in use by another process"
        case .bindFailed(let p, let err):
            return "Failed to bind port \(p) (errno \(err))"
        case .invalidSOCKSVersion(let v):
            return "Invalid SOCKS protocol version: \(v)"
        case .unsupportedAuthMethod:
            return "No acceptable authentication methods offered"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .targetUnreachable(let host):
            return "Target unreachable: \(host)"
        case .timeout:
            return "Connection timed out"
        case .headerTooLarge:
            return "HTTP header exceeded maximum allowed size of 64KB"
        case .malformedRequest(let r):
            return "Malformed request: \(r)"
        }
    }
}

public enum ShellType: String, Codable, Sendable, CaseIterable {
    case bash
    case zsh
    case fish
}
