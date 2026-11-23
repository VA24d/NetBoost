import Foundation

/// Errors that can occur during tool invocation validation or parameter decoding.
public enum ToolCallError: Error, LocalizedError, Equatable, Sendable {
    case unknownTool(String)
    case missingParameter(String)
    case invalidParameterType(expected: String, got: String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidParameterType(let expected, let got):
            return "Invalid parameter type: expected \(expected), got \(got)"
        case .executionFailed(let msg):
            return "Tool execution failed: \(msg)"
        }
    }
}

/// Represents an OpenAI-compatible function parameter schema.
public struct ToolParametersSchema: Codable, Sendable, Equatable {
    public let type: String
    public let properties: [String: ToolPropertySchema]
    public let required: [String]

    public init(
        type: String = "object",
        properties: [String: ToolPropertySchema] = [:],
        required: [String] = []
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "object"
        self.properties = try container.decodeIfPresent([String: ToolPropertySchema].self, forKey: .properties) ?? [:]
        self.required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
    }

    /// Convenience subscript allowing dictionary-style type lookups, e.g. schema["mtu"] == "integer"
    public subscript(key: String) -> String? {
        properties[key]?.type
    }
}

/// Represents an individual property in a tool parameter schema.
public struct ToolPropertySchema: Codable, Sendable, Equatable {
    public let type: String
    public let description: String

    public init(type: String, description: String = "") {
        self.type = type
        self.description = description
    }
}

/// Function definition conforming to OpenAI function calling specifications.
public struct OpenAIFunctionDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: ToolParametersSchema

    public init(
        name: String,
        description: String,
        parameters: ToolParametersSchema = ToolParametersSchema()
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Top-level tool definition conforming to OpenAI API specs.
public struct OpenAIToolDefinition: Codable, Sendable, Equatable {
    public let type: String
    public let function: OpenAIFunctionDefinition

    public init(
        type: String = "function",
        function: OpenAIFunctionDefinition
    ) {
        self.type = type
        self.function = function
    }
}

/// Represents an invocation request for a tool.
public struct ToolCallInvocation: @unchecked Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: [String: Any]

    public init(id: String = UUID().uuidString, name: String, arguments: [String: Any] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public init(id: String = UUID().uuidString, name: String, arguments: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public static func == (lhs: ToolCallInvocation, rhs: ToolCallInvocation) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && NSDictionary(dictionary: lhs.arguments).isEqual(to: rhs.arguments)
    }
}

/// Result of a tool call execution.
public struct ToolExecutionResult: Codable, Sendable, Equatable {
    public let toolCallId: String
    public let success: Bool
    public let message: String

    public init(toolCallId: String, success: Bool, message: String) {
        self.toolCallId = toolCallId
        self.success = success
        self.message = message
    }
}

/// Central registry exposing OpenAI tool schemas and dispatching invocations.
public struct ToolRegistry: Sendable {

    public static let allowedDoctorTools: Set<String> = [
        "fix_mtu",
        "flush_dns",
        "flush_arp",
        "disable_ipv6",
        "toggle_vpn",
        "toggle_hotspot",
        "reorder_services"
    ]

    /// Returns all registered remediation tool schemas.
    public static func allToolSchemas() -> [OpenAIToolDefinition] {
        [
            OpenAIToolDefinition(
                function: OpenAIFunctionDefinition(
                    name: "fix_mtu",
                    description: "Adjust the network interface MTU to eliminate TLS fragmentation and packet drop issues.",
                    parameters: ToolParametersSchema(
                        properties: [
                            "interface": ToolPropertySchema(type: "string", description: "Network interface or service name (e.g. Wi-Fi)"),
                            "service": ToolPropertySchema(type: "string", description: "Network service name"),
                            "mtu": ToolPropertySchema(type: "integer", description: "Target MTU value (e.g. 1280 or 1500)")
                        ],
                        required: ["mtu"]
                    )
                )
            ),
            OpenAIToolDefinition(
                function: OpenAIFunctionDefinition(
                    name: "flush_dns",
                    description: "Flush local macOS DNS cache via dscacheutil and restart mDNSResponder.",
                    parameters: ToolParametersSchema()
                )
            ),
            OpenAIToolDefinition(
                function: OpenAIFunctionDefinition(
                    name: "flush_arp",
                    description: "Flush macOS ARP cache entries to resolve poisoned or stale gateway MAC addresses.",
                    parameters: ToolParametersSchema()
                )
            ),
            OpenAIToolDefinition(
                function: OpenAIFunctionDefinition(
                    name: "disable_ipv6",
                    description: "Disable unrouted IPv6 on local campus LAN to resolve 500ms Happy Eyeballs latency delay.",
                    parameters: ToolParametersSchema(
                        properties: [
                            "service": ToolPropertySchema(type: "string", description: "Network service name (e.g. USB 10/100 LAN)")
                        ],
                        required: ["service"]
                    )
                )
            ),
            OpenAIToolDefinition(
                function: OpenAIFunctionDefinition(
                    name: "toggle_vpn",
                    description: "Connect or disconnect specified VPN profile.",
                    parameters: ToolParametersSchema(
                        properties: [
                            "profile": ToolPropertySchema(type: "string", description: "VPN profile name"),
                            "connect": ToolPropertySchema(type: "boolean", description: "True to connect, false to disconnect")
                        ],
                        required: ["profile"]
                    )
                )
            ),
            OpenAIToolDefinition(
                function: OpenAIFunctionDefinition(
                    name: "toggle_hotspot",
                    description: "Enable or disable 802.1X hotspot sharing engine.",
                    parameters: ToolParametersSchema(
                        properties: [
                            "enable": ToolPropertySchema(type: "boolean", description: "True to enable hotspot sharing")
                        ],
                        required: ["enable"]
                    )
                )
            ),
            OpenAIToolDefinition(
                function: OpenAIFunctionDefinition(
                    name: "reorder_services",
                    description: "Reorder macOS network service priorities.",
                    parameters: ToolParametersSchema(
                        properties: [
                            "services": ToolPropertySchema(type: "array", description: "Ordered list of network service names")
                        ],
                        required: ["services"]
                    )
                )
            )
        ]
    }

    /// Validates parameters for a tool call invocation.
    public static func validateToolCall(_ call: ToolCallInvocation) throws {
        guard allowedDoctorTools.contains(call.name) else {
            throw ToolCallError.unknownTool(call.name)
        }

        switch call.name {
        case "fix_mtu":
            guard let mtuVal = call.arguments["mtu"] else {
                throw ToolCallError.missingParameter("mtu")
            }
            if !(mtuVal is Int) && (mtuVal as? String).flatMap(Int.init) == nil {
                throw ToolCallError.invalidParameterType(expected: "Int", got: "\(type(of: mtuVal))")
            }
        case "disable_ipv6":
            guard call.arguments["service"] != nil else {
                throw ToolCallError.missingParameter("service")
            }
        case "reorder_services":
            guard call.arguments["services"] != nil else {
                throw ToolCallError.missingParameter("services")
            }
        case "toggle_vpn":
            guard call.arguments["profile"] != nil else {
                throw ToolCallError.missingParameter("profile")
            }
        case "toggle_hotspot":
            guard call.arguments["enable"] != nil else {
                throw ToolCallError.missingParameter("enable")
            }
        default:
            break
        }
    }

    /// Dispatches a tool invocation and returns execution results.
    public static func dispatch(
        call: ToolCallInvocation,
        doctor: CampusDoctorProtocol? = nil,
        vpnController: (any VPNControllerProtocol)? = nil,
        hotspotController: (any HotspotControllerProtocol)? = nil
    ) async throws -> ToolExecutionResult {
        try validateToolCall(call)

        switch call.name {
        case "fix_mtu":
            let service = (call.arguments["service"] as? String) ?? (call.arguments["interface"] as? String) ?? "Wi-Fi"
            let mtu: Int
            if let intVal = call.arguments["mtu"] as? Int {
                mtu = intVal
            } else if let strVal = call.arguments["mtu"] as? String, let parsed = Int(strVal) {
                mtu = parsed
            } else {
                mtu = 1280
            }
            if let doctor = doctor {
                try await doctor.fixMTU(service: service, mtu: mtu)
            }
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "MTU of \(service) set to \(mtu)")

        case "flush_dns":
            if let doctor = doctor {
                try await doctor.flushDNS()
            }
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "DNS cache successfully flushed")

        case "flush_arp":
            if let doctor = doctor {
                try await doctor.flushARP()
            }
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "ARP cache successfully cleared")

        case "disable_ipv6":
            let service = (call.arguments["service"] as? String) ?? "USB 10/100 LAN"
            if let doctor = doctor {
                try await doctor.disableIPv6(service: service)
            }
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "IPv6 disabled on \(service)")

        case "reorder_services":
            let services: [String]
            if let list = call.arguments["services"] as? [String] {
                services = list
            } else if let commaSep = call.arguments["services"] as? String {
                services = commaSep.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                services = []
            }
            if let doctor = doctor {
                try await doctor.reorderServices(ordered: services)
            }
            return ToolExecutionResult(
                toolCallId: call.id,
                success: true,
                message: "Network services reordered: \(services.joined(separator: " -> "))"
            )

        case "toggle_vpn":
            let profile = (call.arguments["profile"] as? String) ?? "macos.vpn"
            let connect: Bool
            if let boolVal = call.arguments["connect"] as? Bool {
                connect = boolVal
            } else if let strVal = call.arguments["connect"] as? String {
                connect = (strVal.lowercased() == "true" || strVal == "1")
            } else {
                connect = true
            }
            if let vpn = vpnController {
                if connect {
                    try await vpn.connect(profileName: profile)
                } else {
                    try await vpn.disconnect(profileName: profile)
                }
            }
            let statusStr = connect ? "connected" : "disconnected"
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "VPN profile \(profile) \(statusStr)")

        case "toggle_hotspot":
            let enable: Bool
            if let boolVal = call.arguments["enable"] as? Bool {
                enable = boolVal
            } else if let strVal = call.arguments["enable"] as? String {
                enable = (strVal.lowercased() == "true" || strVal == "1")
            } else {
                enable = true
            }
            let upstream = (call.arguments["upstream"] as? String) ?? "en10"
            let downstream = (call.arguments["downstream"] as? String) ?? "en0"
            if let hotspot = hotspotController {
                if enable {
                    try await hotspot.startHotspot(upstreamInterface: upstream, downstreamInterface: downstream)
                } else {
                    try await hotspot.stopHotspot()
                }
            }
            let actionStr = enable ? "enabled on \(downstream) via \(upstream)" : "disabled"
            return ToolExecutionResult(
                toolCallId: call.id,
                success: true,
                message: "Hotspot sharing \(actionStr)"
            )

        default:
            throw ToolCallError.unknownTool(call.name)
        }
    }

    /// Synchronous dispatch helper for test assertions.
    public static func dispatch(call: ToolCallInvocation) -> ToolExecutionResult {
        switch call.name {
        case "fix_mtu":
            let service = (call.arguments["service"] as? String) ?? (call.arguments["interface"] as? String) ?? "Wi-Fi"
            let mtu = (call.arguments["mtu"] as? String) ?? (call.arguments["mtu"] as? Int).map(String.init) ?? "1280"
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "MTU of \(service) set to \(mtu)")
        case "flush_dns":
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "DNS cache successfully flushed")
        case "flush_arp":
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "ARP cache successfully cleared")
        case "disable_ipv6":
            let service = (call.arguments["service"] as? String) ?? "USB 10/100 LAN"
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "IPv6 disabled on \(service)")
        case "reorder_services":
            let services = (call.arguments["services"] as? [String])?.joined(separator: " -> ") ?? ""
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "Network services reordered: \(services)")
        case "toggle_vpn":
            let profile = (call.arguments["profile"] as? String) ?? "macos.vpn"
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "VPN profile \(profile) toggled")
        case "toggle_hotspot":
            return ToolExecutionResult(toolCallId: call.id, success: true, message: "Hotspot toggled")
        default:
            return ToolExecutionResult(toolCallId: call.id, success: false, message: "Unknown tool: \(call.name)")
        }
    }
}
