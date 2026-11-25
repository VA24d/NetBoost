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
    func sendChat(message: String, report: NetworkTelemetryReport?, endpoint: URL) async throws -> LLMAnalysis
    func appendToolResult(toolCallId: String, name: String, output: String)
    func executeTool(name: String, arguments: [String: Any]) async throws -> ToolResult
}

public extension LLMDoctorBridgeProtocol {
    func sendChat(message: String, report: NetworkTelemetryReport?, endpoint: URL) async throws -> LLMAnalysis {
        try await sendTelemetry(report: report ?? NetworkTelemetryReport(), endpoint: endpoint)
    }

    func appendToolResult(toolCallId: String, name: String, output: String) {}
}

/// Message entry in multi-turn AI doctor chat history.
public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public let toolCallId: String?
    public let name: String?

    public init(role: String, content: String, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.name = name
    }
}

/// HTTP client connecting to local LM Studio endpoint (http://localhost:1234/v1) or OpenAI-compatible servers.
public final class LLMDoctorBridge: LLMDoctorBridgeProtocol, @unchecked Sendable {

    public static let defaultChatEndpoint = URL(string: "http://localhost:1234/v1/chat/completions")!
    public static let defaultModelsEndpoint = URL(string: "http://localhost:1234/v1/models")!

    public let doctor: CampusDoctorProtocol?
    public let vpnController: (any VPNControllerProtocol)?
    public let hotspotController: (any HotspotControllerProtocol)?
    private var _selectedModel: String?
    private var history: [ChatMessage] = []
    private let lock = NSLock()
    private let session: URLSession

    public var selectedModel: String? {
        get { lock.withLock { _selectedModel } }
        set { lock.withLock { _selectedModel = newValue } }
    }

    public init(
        doctor: CampusDoctorProtocol? = nil,
        vpnController: (any VPNControllerProtocol)? = nil,
        hotspotController: (any HotspotControllerProtocol)? = nil,
        selectedModel: String? = nil,
        session: URLSession? = nil
    ) {
        self.doctor = doctor
        self.vpnController = vpnController
        self.hotspotController = hotspotController
        self._selectedModel = selectedModel
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

    /// Feeds an approved tool execution result back into the multi-turn conversation history.
    public func appendToolResult(toolCallId: String, name: String, output: String) {
        lock.withLock {
            history.append(ChatMessage(role: "tool", content: output, toolCallId: toolCallId, name: name))
        }
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

    private func modelsEndpoint(for chatEndpoint: URL) -> URL {
        guard var components = URLComponents(url: chatEndpoint, resolvingAgainstBaseURL: false) else {
            return Self.defaultModelsEndpoint
        }
        if components.path.hasSuffix("/chat/completions") {
            components.path = String(components.path.dropLast("/chat/completions".count)) + "/models"
            if let derived = components.url {
                return derived
            }
        }
        return Self.defaultModelsEndpoint
    }

    private func resolveModel(for chatEndpoint: URL) async -> String {
        if let configured = selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }
        let modelsURL = modelsEndpoint(for: chatEndpoint)
        if let models = try? await listModels(endpoint: modelsURL),
           let first = models.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return first
        }
        return "local-model"
    }

    private func prepareMessagesPayload(systemPrompt: String, userPrompt: String) -> [[String: Any]] {
        lock.withLock {
            if history.isEmpty {
                history.append(ChatMessage(role: "system", content: systemPrompt))
            }
            history.append(ChatMessage(role: "user", content: userPrompt))
            return history.map { msg in
                var dict: [String: Any] = [
                    "role": msg.role,
                    "content": msg.content
                ]
                if let toolCallId = msg.toolCallId {
                    dict["tool_call_id"] = toolCallId
                }
                if let name = msg.name {
                    dict["name"] = name
                }
                return dict
            }
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
        let userPrompt = "Network Telemetry Report:\n\(telemetryJSON)"
        return try await performChatCompletion(userPrompt: userPrompt, endpoint: endpoint)
    }

    /// Sends a user chat prompt (with optional current telemetry report) to LM Studio and parses the response.
    public func sendChat(
        message: String,
        report: NetworkTelemetryReport? = nil,
        endpoint: URL = defaultChatEndpoint
    ) async throws -> LLMAnalysis {
        let userPrompt: String
        if let report = report {
            let telemetryJSON = try TelemetryExporter.exportJSON(report: report, pretty: true)
            userPrompt = "\(message)\n\nCurrent Network Telemetry:\n\(telemetryJSON)"
        } else {
            userPrompt = message
        }
        return try await performChatCompletion(userPrompt: userPrompt, endpoint: endpoint)
    }

    private func performChatCompletion(
        userPrompt: String,
        endpoint: URL
    ) async throws -> LLMAnalysis {
        let systemPrompt = "You are NetBoost AI Network Doctor. Analyze network telemetry and execute remediation tools to resolve issues."
        let messagesPayload = prepareMessagesPayload(systemPrompt: systemPrompt, userPrompt: userPrompt)

        // Prepare tools schema payload
        let tools = ToolRegistry.allToolSchemas()
        let toolsPayload = try tools.map { tool -> [String: Any] in
            let data = try JSONEncoder().encode(tool)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        let modelName = await resolveModel(for: endpoint)

        let requestBody: [String: Any] = [
            "model": modelName,
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
                    if let argsDict = funcObj["arguments"] as? [String: Any] {
                        args = argsDict
                    } else if let argsStr = funcObj["arguments"] as? String,
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
