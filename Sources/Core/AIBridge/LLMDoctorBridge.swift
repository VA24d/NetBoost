import Foundation

/// Structured analysis output returned by local LLM doctor.
public struct LLMAnalysis: Sendable, Equatable {
    public let diagnosis: String
    public let recommendedActions: [String]
    public let toolCalls: [ToolCallInvocation]
    public let rawResponse: String

    public init(
        diagnosis: String,
        recommendedActions: [String] = [],
        toolCalls: [ToolCallInvocation] = [],
        rawResponse: String = ""
    ) {
        self.diagnosis = diagnosis
        self.recommendedActions = recommendedActions
        self.toolCalls = toolCalls
        self.rawResponse = rawResponse
    }
}

/// Result of executing a remediation tool recommended by the LLM.
public struct ToolResult: Sendable, Equatable {
    public let toolName: String
    public let success: Bool
    public let output: String

    public init(toolName: String, success: Bool, output: String) {
        self.toolName = toolName
        self.success = success
        self.output = output
    }
}

/// Protocol defining the AI Doctor bridge contract.
public protocol LLMDoctorBridgeProtocol: Sendable {
    func sendTelemetry(report: NetworkTelemetryReport, endpoint: URL) async throws -> LLMAnalysis
    func executeTool(name: String, arguments: [String: Any]) async throws -> ToolResult
}

/// Message entry in multi-turn AI doctor chat history.
public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// HTTP client connecting to local LM Studio endpoint (http://localhost:1234/v1) or OpenAI-compatible servers.
public final class LLMDoctorBridge: LLMDoctorBridgeProtocol, @unchecked Sendable {

    public static let defaultChatEndpoint = URL(string: "http://localhost:1234/v1/chat/completions")!
    public static let defaultModelsEndpoint = URL(string: "http://localhost:1234/v1/models")!

    public let doctor: CampusDoctorProtocol?
    public let vpnController: (any VPNControllerProtocol)?
    public let hotspotController: (any HotspotControllerProtocol)?
    private var history: [ChatMessage] = []
    private let lock = NSLock()
    private let session: URLSession

    public init(
        doctor: CampusDoctorProtocol? = nil,
        vpnController: (any VPNControllerProtocol)? = nil,
        hotspotController: (any HotspotControllerProtocol)? = nil,
        session: URLSession? = nil
    ) {
        self.doctor = doctor
        self.vpnController = vpnController
        self.hotspotController = hotspotController
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10.0
            config.timeoutIntervalForResource = 15.0
            self.session = URLSession(configuration: config)
        }
    }

    public var conversationHistory: [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    public func resetConversation() {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
    }

    /// Queries LM Studio for available loaded models.
    public func listModels(endpoint: URL = defaultModelsEndpoint) async throws -> [String] {
        let (data, response) = try await session.data(from: endpoint)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw ToolCallError.executionFailed("Server returned HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return []
        }

        return dataArray.compactMap { $0["id"] as? String }
    }

    private func prepareMessagesPayload(systemPrompt: String, userPrompt: String) -> [[String: String]] {
        lock.withLock {
            if history.isEmpty {
                history.append(ChatMessage(role: "system", content: systemPrompt))
            }
            history.append(ChatMessage(role: "user", content: userPrompt))
            return history.map { ["role": $0.role, "content": $0.content] }
        }
    }

    private func recordAssistantResponse(_ content: String) {
        lock.withLock {
            history.append(ChatMessage(role: "assistant", content: content.isEmpty ? "Executing remediation tools" : content))
        }
    }

    /// Transmits network telemetry report to local model and parses analysis and tool calls.
    public func sendTelemetry(
        report: NetworkTelemetryReport,
        endpoint: URL = defaultChatEndpoint
    ) async throws -> LLMAnalysis {
        let telemetryJSON = try TelemetryExporter.exportJSON(report: report, pretty: true)

        let systemPrompt = "You are NetBoost AI Network Doctor. Analyze network telemetry and execute remediation tools to resolve issues."
        let userPrompt = "Network Telemetry Report:\n\(telemetryJSON)"

        let messagesPayload = prepareMessagesPayload(systemPrompt: systemPrompt, userPrompt: userPrompt)

        // Prepare tools schema payload
        let tools = ToolRegistry.allToolSchemas()
        let toolsPayload = try tools.map { tool -> [String: Any] in
            let data = try JSONEncoder().encode(tool)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        let requestBody: [String: Any] = [
            "model": "qwen2.5-coder-7b-instruct",
            "messages": messagesPayload,
            "tools": toolsPayload
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if http.statusCode != 200 {
            throw ToolCallError.executionFailed("LM Studio returned HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }

        let rawString = String(data: data, encoding: .utf8) ?? ""
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw ToolCallError.executionFailed("Malformed completions response")
        }

        let content = (message["content"] as? String) ?? ""
        var parsedToolCalls: [ToolCallInvocation] = []

        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                let id = (raw["id"] as? String) ?? UUID().uuidString
                if let funcObj = raw["function"] as? [String: Any],
                   let name = funcObj["name"] as? String {
                    var args: [String: Any] = [:]
                    if let argsStr = funcObj["arguments"] as? String,
                       let argsData = argsStr.data(using: .utf8),
                       let parsedArgs = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        args = parsedArgs
                    }
                    parsedToolCalls.append(ToolCallInvocation(id: id, name: name, arguments: args))
                }
            }
        }

        recordAssistantResponse(content)

        return LLMAnalysis(
            diagnosis: content,
            recommendedActions: parsedToolCalls.map(\.name),
            toolCalls: parsedToolCalls,
            rawResponse: rawString
        )
    }

    /// Programmatically executes a remediation tool.
    public func executeTool(name: String, arguments: [String: Any]) async throws -> ToolResult {
        let invocation = ToolCallInvocation(name: name, arguments: arguments)
        let result = try await ToolRegistry.dispatch(
            call: invocation,
            doctor: doctor,
            vpnController: vpnController,
            hotspotController: hotspotController
        )
        return ToolResult(toolName: name, success: result.success, output: result.message)
    }
}
