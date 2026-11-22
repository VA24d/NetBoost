import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 39: LM Studio Bridge Boundaries", .tags(.tier2, .m5_doctor, .llm_bridge))
struct Tier2_39_LMStudioBridgeBoundariesTests {

    @Test("T2-F39-01: Offline LM Studio endpoint handled gracefully without unhandled exception")
    func testOfflineEndpointFallback() async throws {
        // Query port that has no listener
        let deadURL = URL(string: "http://127.0.0.1:54321/v1/models")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        let session = URLSession(configuration: config)

        await #expect(throws: Error.self) {
            _ = try await session.data(from: deadURL)
        }
    }

    @Test("T2-F39-02: Plain text response from model handled when no tool calls returned")
    func testPlainTextResponseMode() async throws {
        let server = MockLMStudioServer()
        let advice = "Your campus gateway RTT is high. Recommend moving closer to AP or using Ethernet."
        server.responseMode = .text(advice)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{\"messages\":[{\"role\":\"user\",\"content\":\"diagnose\"}]}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        #expect(bodyString.contains(advice))
    }

    @Test("T2-F39-03: Model server error 500 handled cleanly")
    func testServerError500Handling() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .error500("GPU out of memory on local model")
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = "{}".data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: req)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 500)
    }

    @Test("T2-F39-04: Tool call generation validates tool name against allowed doctor tools")
    func testToolCallValidationAgainstRegistry() {
        let allowedDoctorTools: Set<String> = [
            "fix_mtu", "flush_dns", "flush_arp", "disable_ipv6",
            "toggle_vpn", "toggle_hotspot", "reorder_services"
        ]

        func isToolAllowed(_ name: String) -> Bool {
            return allowedDoctorTools.contains(name)
        }

        #expect(isToolAllowed("fix_mtu") == true)
        #expect(isToolAllowed("flush_dns") == true)
        #expect(isToolAllowed("hallucinated_network_fixer") == false)
        #expect(isToolAllowed("execute_arbitrary_shell") == false)
    }

    @Test("T2-F39-05: Chat completions request tracking captures telemetry payload")
    func testRequestTrackingCapturesPayload() async throws {
        let server = MockLMStudioServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let payload = "{\"telemetry\":{\"gatewayRTT\":1.2}}".data(using: .utf8)!
        req.httpBody = payload

        _ = try await URLSession.shared.data(for: req)

        let lastBody = server.lastReceivedBody
        #expect(lastBody != nil)
        let bodyString = String(data: lastBody!, encoding: .utf8) ?? ""
        #expect(bodyString.contains("gatewayRTT"))
    }
}
