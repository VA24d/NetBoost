import Testing
import Foundation
@testable import NetBoostCore

@Suite("AI Doctor Bridge: LLMDoctorBridge Unit & Integration Tests")
struct LLMDoctorBridgeTests {

    @Test("List models from LM Studio /v1/models endpoint")
    func testListModels() async throws {
        let server = MockLMStudioServer()
        let port = try await server.start()
        defer { server.stop() }

        let modelsURL = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let bridge = LLMDoctorBridge()
        let models = try await bridge.listModels(endpoint: modelsURL)

        #expect(!models.isEmpty)
        #expect(models.first == "qwen2.5-coder-7b-instruct")
    }

    @Test("Send telemetry report and receive model diagnosis text")
    func testSendTelemetryTextResponse() async throws {
        let server = MockLMStudioServer()
        let diagnosisText = "Detected suboptimal MTU 1500 on cellular hotspot en0. Recommend fixing MTU to 1280."
        server.responseMode = .text(diagnosisText)
        let port = try await server.start()
        defer { server.stop() }

        let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        let bridge = LLMDoctorBridge()

        let report = NetworkTelemetryReport(
            gatewayRTT: 18.5,
            activeIssues: [
                DetectedIssue(
                    severity: .warning,
                    title: "Cellular MTU Invariant",
                    description: "MTU 1500 on cellular uplink",
                    recommendedFixAction: "networksetup -setMTU Wi-Fi 1280"
                )
            ]
        )

        let analysis = try await bridge.sendTelemetry(report: report, endpoint: chatURL)

        #expect(analysis.diagnosis.contains("suboptimal MTU 1500"))
        #expect(analysis.toolCalls.isEmpty)
        #expect(bridge.conversationHistory.count >= 2)
    }

    @Test("Send telemetry report and receive model tool calls")
    func testSendTelemetryToolCallsResponse() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .toolCalls([
            SimulatedToolCall(name: "fix_mtu", arguments: "{\"interface\":\"Wi-Fi\",\"mtu\":1280}"),
            SimulatedToolCall(name: "flush_dns", arguments: "{}")
        ])
        let port = try await server.start()
        defer { server.stop() }

        let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        let bridge = LLMDoctorBridge()

        let report = NetworkTelemetryReport(gatewayRTT: 2.0)
        let analysis = try await bridge.sendTelemetry(report: report, endpoint: chatURL)

        #expect(analysis.toolCalls.count == 2)
        #expect(analysis.toolCalls[0].name == "fix_mtu")
        #expect(analysis.toolCalls[1].name == "flush_dns")
        #expect(analysis.recommendedActions == ["fix_mtu", "flush_dns"])
    }

    @Test("Execute tool via LLM bridge executes remediation and returns result")
    func testExecuteToolViaBridge() async throws {
        let bridge = LLMDoctorBridge()
        let result = try await bridge.executeTool(name: "flush_dns", arguments: [:])

        #expect(result.toolName == "flush_dns")
        #expect(result.success == true)
        #expect(result.output.contains("DNS cache successfully flushed"))
    }

    @Test("Handles offline LM Studio endpoint gracefully with error")
    func testOfflineEndpointError() async {
        let deadURL = URL(string: "http://127.0.0.1:54321/v1/chat/completions")!
        let bridge = LLMDoctorBridge()
        let report = NetworkTelemetryReport()

        await #expect(throws: Error.self) {
            _ = try await bridge.sendTelemetry(report: report, endpoint: deadURL)
        }
    }

    @Test("Handles HTTP 500 error from LM Studio without crashing")
    func testServerError500Handling() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .error500("Internal model execution error")
        let port = try await server.start()
        defer { server.stop() }

        let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        let bridge = LLMDoctorBridge()
        let report = NetworkTelemetryReport()

        await #expect(throws: ToolCallError.self) {
            _ = try await bridge.sendTelemetry(report: report, endpoint: chatURL)
        }
    }

    @Test("Reset conversation clears chat history")
    func testResetConversation() {
        let bridge = LLMDoctorBridge()
        bridge.resetConversation()
        #expect(bridge.conversationHistory.isEmpty)
    }
}
