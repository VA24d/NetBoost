import Foundation

public struct ProbeResult: Codable, Sendable, Identifiable, Equatable {
    public var id: String { targetHost }
    public let targetHost: String
    public let targetIP: String?
    public let isReachable: Bool
    public let latencyMs: Double
    public let packetLossPercent: Double
    public let timestamp: Date

    public init(
        targetHost: String,
        targetIP: String? = nil,
        isReachable: Bool,
        latencyMs: Double = 0.0,
        packetLossPercent: Double = 0.0,
        timestamp: Date = Date()
    ) {
        self.targetHost = targetHost
        self.targetIP = targetIP
        self.isReachable = isReachable
        self.latencyMs = latencyMs
        self.packetLossPercent = packetLossPercent
        self.timestamp = timestamp
    }
}

public enum IssueSeverity: String, Codable, Sendable, Comparable {
    case info
    case warning
    case critical

    private var priority: Int {
        switch self {
        case .info: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool {
        lhs.priority < rhs.priority
    }
}

public struct DetectedIssue: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let severity: IssueSeverity
    public let title: String
    public let description: String
    public let recommendedFixAction: String
    public let automatedFixAvailable: Bool

    public init(
        id: UUID = UUID(),
        severity: IssueSeverity,
        title: String,
        description: String,
        recommendedFixAction: String,
        automatedFixAvailable: Bool = true
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.description = description
        self.recommendedFixAction = recommendedFixAction
        self.automatedFixAvailable = automatedFixAvailable
    }
}

public enum CaptivePortalStatus: String, Codable, Sendable {
    case notDetected
    case detected
    case redirecting
    case authenticated
    case unknown
}

public struct NetworkTelemetryReport: Codable, Sendable, Identifiable, Equatable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let interfaces: [NetworkInterfaceInfo]
    public let gatewayRTT: Double?
    public let campusCoreRTT: Double?
    public let externalEndpointsRTT: [String: Double]
    public let captivePortalDetected: Bool
    public let captivePortalStatus: CaptivePortalStatus
    public let activeIssues: [DetectedIssue]

    public init(
        timestamp: Date = Date(),
        interfaces: [NetworkInterfaceInfo] = [],
        gatewayRTT: Double? = nil,
        campusCoreRTT: Double? = nil,
        externalEndpointsRTT: [String: Double] = [:],
        captivePortalDetected: Bool = false,
        captivePortalStatus: CaptivePortalStatus = .notDetected,
        activeIssues: [DetectedIssue] = []
    ) {
        self.timestamp = timestamp
        self.interfaces = interfaces
        self.gatewayRTT = gatewayRTT
        self.campusCoreRTT = campusCoreRTT
        self.externalEndpointsRTT = externalEndpointsRTT
        self.captivePortalDetected = captivePortalDetected
        self.captivePortalStatus = captivePortalStatus
        self.activeIssues = activeIssues
    }
}
