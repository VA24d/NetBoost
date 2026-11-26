import Foundation

// MARK: - Navigation Tab Definition

public enum AppNavigationTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard = "Dashboard"
    case hotspot = "Hotspot"
    case dispatcher = "Dispatcher"
    case vpn = "VPN & Routing"
    case accelerator = "Accelerator"
    case doctor = "Network Doctor"
    case aiDoctor = "AI Doctor"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .hotspot: return "personalhotspot"
        case .dispatcher: return "arrow.triangle.branch"
        case .vpn: return "lock.shield"
        case .accelerator: return "bolt.horizontal"
        case .doctor: return "cross.case"
        case .aiDoctor: return "cpu"
        }
    }
}

// MARK: - AI Tool Execution Log

public struct ToolExecutionLog: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let toolName: String
    public let arguments: String
    public let success: Bool
    public let output: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        toolName: String,
        arguments: String,
        success: Bool,
        output: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.toolName = toolName
        self.arguments = arguments
        self.success = success
        self.output = output
    }
}

// MARK: - Menu Bar & Icon Styles

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case iconAndSpeed = "Icon + Speed"
    case compactSpeed = "Compact Speed"
    case minimalBadge = "Minimal Badge"

    public var id: String { rawValue }
}

public enum AppLogoStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case sapphireLightning = "LAN Bridge"
    case liquidWaveform = "Signal Arcs"
    case networkCore = "Network Core"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .sapphireLightning: return "cable.connector"
        case .liquidWaveform: return "dot.radiowaves.left.and.right"
        case .networkCore: return "bolt.horizontal.circle.fill"
        }
    }
}
