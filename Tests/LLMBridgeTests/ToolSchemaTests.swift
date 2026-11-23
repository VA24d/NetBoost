import Testing
import Foundation
@testable import NetBoostCore

@Suite("AI Doctor Bridge: ToolSchema & ToolRegistry Tests")
struct ToolSchemaTests {

    @Test("Export all expected doctor remediation tool schemas")
    func testAllToolSchemasExport() {
        let tools = ToolRegistry.allToolSchemas()
        let names = tools.map { $0.function.name }

        #expect(names.contains("fix_mtu"))
        #expect(names.contains("flush_dns"))
        #expect(names.contains("flush_arp"))
        #expect(names.contains("disable_ipv6"))
        #expect(names.contains("toggle_vpn"))
        #expect(names.contains("toggle_hotspot"))
        #expect(names.contains("reorder_services"))

        // Check parameter types
        let fixMTU = tools.first { $0.function.name == "fix_mtu" }
        #expect(fixMTU?.function.parameters["mtu"] == "integer")
    }

    @Test("Validate tool invocation catches unknown tool name")
    func testUnknownToolValidation() {
        let call = ToolCallInvocation(name: "unauthorized_command", arguments: [:])
        #expect(throws: ToolCallError.unknownTool("unauthorized_command")) {
            try ToolRegistry.validateToolCall(call)
        }
    }

    @Test("Validate tool invocation catches missing required parameter")
    func testMissingParameterValidation() {
        let call = ToolCallInvocation(name: "fix_mtu", arguments: ["interface": "Wi-Fi"])
        #expect(throws: ToolCallError.missingParameter("mtu")) {
            try ToolRegistry.validateToolCall(call)
        }
    }

    @Test("Validate tool invocation catches invalid parameter type")
    func testInvalidParameterTypeValidation() {
        let call = ToolCallInvocation(name: "fix_mtu", arguments: ["mtu": [1, 2, 3]])
        #expect(throws: ToolCallError.invalidParameterType(expected: "Int", got: "\(type(of: [1, 2, 3]))")) {
            try ToolRegistry.validateToolCall(call)
        }
    }

    @Test("Dispatch tool execution invokes correct action and returns structured result")
    func testDispatchToolExecution() async throws {
        let call = ToolCallInvocation(
            id: "call_001",
            name: "flush_dns",
            arguments: [:]
        )

        let result = try await ToolRegistry.dispatch(call: call)
        #expect(result.toolCallId == "call_001")
        #expect(result.success == true)
        #expect(result.message.contains("DNS cache successfully flushed"))
    }

    final class MockVPNController: VPNControllerProtocol, @unchecked Sendable {
        var disconnectedProfile: String?
        func checkStatus(profileName: String) async -> VPNStatus { .disconnected }
        func connect(profileName: String) async throws {}
        func disconnect(profileName: String) async throws { disconnectedProfile = profileName }
        func parseProfile(url: URL) throws -> VPNProfileInfo { throw ToolCallError.executionFailed("unused") }
        func detectConflicts(profile: VPNProfileInfo, currentLAN: String) -> [String] { [] }
    }

    final class MockHotspotController: HotspotControllerProtocol, @unchecked Sendable {
        var isStopped = false
        func startHotspot(upstreamInterface: String, downstreamInterface: String) async throws {}
        func stopHotspot() async throws { isStopped = true }
        func connectedClients() async -> [HotspotClient] { [] }
    }

    final class MockDoctor: CampusDoctorProtocol, @unchecked Sendable {
        var reordered: [String] = []
        func runFullDiagnostics() async -> NetworkTelemetryReport { NetworkTelemetryReport() }
        func pingTarget(host: String) async -> ProbeResult {
            ProbeResult(targetHost: host, isReachable: true, latencyMs: 1.0, packetLossPercent: 0.0)
        }
        func checkCaptivePortal() async -> CaptivePortalStatus { .notDetected }
        func fixMTU(service: String, mtu: Int) async throws {}
        func flushDNS() async throws {}
        func flushARP() async throws {}
        func disableIPv6(service: String) async throws {}
        func reorderServices(ordered: [String]) async throws { reordered = ordered }
    }

    @Test("Dispatch reorder_services tool executes service reordering")
    func testDispatchReorderServices() async throws {
        let mockDoctor = MockDoctor()
        let call = ToolCallInvocation(
            id: "call_reorder",
            name: "reorder_services",
            arguments: ["services": ["Wi-Fi", "iPhone USB", "Ethernet"]]
        )

        let result = try await ToolRegistry.dispatch(call: call, doctor: mockDoctor)
        #expect(result.toolCallId == "call_reorder")
        #expect(result.success == true)
        #expect(result.message.contains("Wi-Fi -> iPhone USB -> Ethernet"))
        #expect(mockDoctor.reordered == ["Wi-Fi", "iPhone USB", "Ethernet"])
    }

    @Test("Dispatch toggle_vpn tool executes VPN connection")
    func testDispatchToggleVPN() async throws {
        let mockVPN = MockVPNController()
        let call = ToolCallInvocation(
            id: "call_vpn",
            name: "toggle_vpn",
            arguments: ["profile": "macos.vpn", "connect": false]
        )

        let result = try await ToolRegistry.dispatch(call: call, vpnController: mockVPN)
        #expect(result.toolCallId == "call_vpn")
        #expect(result.success == true)
        #expect(result.message.contains("VPN profile macos.vpn disconnected"))
        #expect(mockVPN.disconnectedProfile == "macos.vpn")
    }

    @Test("Dispatch toggle_hotspot tool executes Hotspot toggle")
    func testDispatchToggleHotspot() async throws {
        let mockHotspot = MockHotspotController()
        let call = ToolCallInvocation(
            id: "call_hotspot",
            name: "toggle_hotspot",
            arguments: ["enable": false]
        )

        let result = try await ToolRegistry.dispatch(call: call, hotspotController: mockHotspot)
        #expect(result.toolCallId == "call_hotspot")
        #expect(result.success == true)
        #expect(result.message.contains("Hotspot sharing disabled"))
        #expect(mockHotspot.isStopped == true)
    }

    @Test("sample_tool_calls.json fixture parses successfully")
    func testSampleToolCallsFixture() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Telemetry/sample_tool_calls.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))

        struct ToolListFixture: Codable {
            let tools: [OpenAIToolDefinition]
        }

        let decoded = try JSONDecoder().decode(ToolListFixture.self, from: data)
        #expect(decoded.tools.count >= 4)
        let toolNames = decoded.tools.map { $0.function.name }
        #expect(toolNames.contains("fix_mtu"))
        #expect(toolNames.contains("flush_dns"))
        #expect(toolNames.contains("flush_arp"))
        #expect(toolNames.contains("disable_ipv6"))
    }
}
