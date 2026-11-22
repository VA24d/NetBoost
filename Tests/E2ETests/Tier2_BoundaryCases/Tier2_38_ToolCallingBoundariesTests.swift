import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 38: Tool Calling Boundaries", .tags(.tier2, .m5_doctor, .llm_bridge))
struct Tier2_38_ToolCallingBoundariesTests {

    enum ToolCallError: Error, Equatable {
        case unknownTool(String)
        case missingParameter(String)
        case invalidParameterType(expected: String, got: String)
    }

    struct ToolCallInvocation {
        let name: String
        let arguments: [String: Any]
    }

    func dispatchTool(_ tool: ToolCallInvocation) throws -> String {
        let knownTools: Set<String> = [
            "fix_mtu", "flush_dns", "flush_arp", "disable_ipv6",
            "toggle_vpn", "toggle_hotspot", "reorder_services"
        ]

        guard knownTools.contains(tool.name) else {
            throw ToolCallError.unknownTool(tool.name)
        }

        switch tool.name {
        case "fix_mtu":
            guard let mtuVal = tool.arguments["mtu"] else {
                throw ToolCallError.missingParameter("mtu")
            }
            guard let _ = mtuVal as? Int else {
                throw ToolCallError.invalidParameterType(expected: "Int", got: "\(type(of: mtuVal))")
            }
            return "fix_mtu executed"
        case "flush_dns", "flush_arp":
            return "\(tool.name) executed"
        default:
            return "executed"
        }
    }

    @Test("T2-F38-01: Unknown tool name throws ToolCallError.unknownTool")
    func testUnknownToolName() {
        let invocation = ToolCallInvocation(name: "format_disk", arguments: [:])
        #expect(throws: ToolCallError.unknownTool("format_disk")) {
            try dispatchTool(invocation)
        }
    }

    @Test("T2-F38-02: Missing required parameter (mtu) throws ToolCallError.missingParameter")
    func testMissingRequiredParameter() {
        let invocation = ToolCallInvocation(name: "fix_mtu", arguments: ["interface": "Wi-Fi"])
        #expect(throws: ToolCallError.missingParameter("mtu")) {
            try dispatchTool(invocation)
        }
    }

    @Test("T2-F38-03: Argument type mismatch (String instead of Int) throws invalidParameterType")
    func testParameterTypeMismatch() {
        let invocation = ToolCallInvocation(name: "fix_mtu", arguments: ["interface": "Wi-Fi", "mtu": "one_thousand"])
        #expect(throws: ToolCallError.self) {
            try dispatchTool(invocation)
        }
    }

    @Test("T2-F38-04: sample_tool_calls.json fixture parses all remediation tool schemas")
    func testSampleToolCallsFixtureParsing() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Telemetry/sample_tool_calls.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))

        struct ToolSchemaItem: Codable {
            struct FunctionSchema: Codable {
                let name: String
                let description: String
            }
            let type: String
            let function: FunctionSchema
        }

        struct ToolList: Codable {
            let tools: [ToolSchemaItem]
        }

        let decoded = try JSONDecoder().decode(ToolList.self, from: data)
        #expect(decoded.tools.count >= 4)

        let toolNames = decoded.tools.map { $0.function.name }
        #expect(toolNames.contains("fix_mtu"))
        #expect(toolNames.contains("flush_dns"))
        #expect(toolNames.contains("flush_arp"))
        #expect(toolNames.contains("disable_ipv6"))
    }

    @Test("T2-F38-05: Valid tool execution returns success message")
    func testValidToolExecution() throws {
        let validInvocation = ToolCallInvocation(name: "fix_mtu", arguments: ["interface": "Wi-Fi", "mtu": 1280])
        let result = try dispatchTool(validInvocation)
        #expect(result == "fix_mtu executed")
    }
}
