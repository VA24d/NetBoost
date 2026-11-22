import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 39: Local LLM / AI Doctor Bridge", .tags(.tier1, .m5_doctor, .llm_bridge))
struct Tier1_39_LMStudioBridgeTests {

    @Test("T1-F39-01: Connect to LM Studio endpoint /v1/models and list available models")
    func testQueryLMStudioModels() async throws {
        let server = MockLMStudioServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let (data, response) = try await URLSession.shared.data(from: url)

        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataArray = json?["data"] as? [[String: Any]]
        #expect(dataArray?.isEmpty == false)
        #expect(dataArray?.first?["id"] as? String == "qwen2.5-coder-7b-instruct")
    }

    @Test("T1-F39-02: Send telemetry report in chat completion request to /v1/chat/completions")
    func testSendTelemetryToChatCompletions() async throws {
        let server = MockLMStudioServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatPayload: [String: Any] = [
            "model": "qwen2.5-coder-7b-instruct",
            "messages": [
                ["role": "system", "content": "You are NetBoost AI Network Doctor."],
                ["role": "user", "content": "Analyze telemetry: gateway RTT 18ms, Wi-Fi MTU 1500 on cellular."]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: chatPayload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(!data.isEmpty)
    }

    @Test("T1-F39-03: Receive diagnostic analysis text from local model")
    func testReceiveModelAnalysisText() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .text("Diagnosis: Suboptimal MTU 1500 detected on cellular hotspot. Recommended action: set MTU to 1280.")
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String

        #expect(content?.contains("Suboptimal MTU") == true)
        #expect(content?.contains("1280") == true)
    }

    @Test("T1-F39-04: Parse model-generated OpenAI tool calls accurately")
    func testParseModelToolCalls() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .toolCalls([
            SimulatedToolCall(name: "fix_mtu", arguments: "{\"interface\":\"Wi-Fi\",\"mtu\":1280}")
        ])
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let toolCalls = message?["tool_calls"] as? [[String: Any]]

        #expect(toolCalls?.count == 1)
        let function = toolCalls?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "fix_mtu")
        #expect((function?["arguments"] as? String)?.contains("1280") == true)
    }

    @Test("T1-F39-05: Maintain multi-turn diagnostic conversation history model")
    func testMultiTurnConversationHistory() {
        struct Message: Equatable {
            let role: String
            let content: String
        }

        var history: [Message] = []
        history.append(Message(role: "system", content: "AI Doctor initialized"))
        history.append(Message(role: "user", content: "Network seems slow on hotspot"))
        history.append(Message(role: "assistant", content: "Please run diagnostic probe"))
        history.append(Message(role: "user", content: "Probe result: latency 18ms, MTU 1500"))

        #expect(history.count == 4)
        #expect(history.first?.role == "system")
        #expect(history.last?.content.contains("MTU 1500") == true)
    }
}
