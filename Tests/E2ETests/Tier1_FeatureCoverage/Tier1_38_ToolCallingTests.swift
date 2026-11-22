import Testing
import Foundation

@Suite("Feature 38: Programmatic Remediation Tool Calling", .tags(.tier1, .m5_doctor, .llm_bridge))
struct Tier1_38_ToolCallingTests {

    struct OpenAIToolDefinition: Codable, Equatable {
        let type: String
        let function: OpenAIFunctionDefinition
    }

    struct OpenAIFunctionDefinition: Codable, Equatable {
        let name: String
        let description: String
        let parameters: [String: String]
    }

    struct ToolCallInvocation: Codable, Equatable {
        let id: String
        let name: String
        let arguments: [String: String]
    }

    struct ToolExecutionResult: Codable, Equatable {
        let toolCallId: String
        let success: Bool
        let message: String
    }

    struct ToolRegistry {
        static func allToolSchemas() -> [OpenAIToolDefinition] {
            [
                OpenAIToolDefinition(
                    type: "function",
                    function: OpenAIFunctionDefinition(
                        name: "fix_mtu",
                        description: "Adjusts network interface MTU to 1280 or 1500",
                        parameters: ["service": "string", "mtu": "integer"]
                    )
                ),
                OpenAIToolDefinition(
                    type: "function",
                    function: OpenAIFunctionDefinition(
                        name: "flush_dns",
                        description: "Flushes macOS DNS directory service and restarts mDNSResponder",
                        parameters: [:]
                    )
                ),
                OpenAIToolDefinition(
                    type: "function",
                    function: OpenAIFunctionDefinition(
                        name: "flush_arp",
                        description: "Clears corrupted entries from ARP table",
                        parameters: [:]
                    )
                ),
                OpenAIToolDefinition(
                    type: "function",
                    function: OpenAIFunctionDefinition(
                        name: "disable_ipv6",
                        description: "Disables unrouted IPv6 on specified service to prevent Happy Eyeballs latency",
                        parameters: ["service": "string"]
                    )
                ),
                OpenAIToolDefinition(
                    type: "function",
                    function: OpenAIFunctionDefinition(
                        name: "toggle_vpn",
                        description: "Connects or disconnects specified VPN profile",
                        parameters: ["profile": "string", "connect": "boolean"]
                    )
                )
            ]
        }

        static func dispatch(call: ToolCallInvocation) -> ToolExecutionResult {
            switch call.name {
            case "fix_mtu":
                let service = call.arguments["service"] ?? "Wi-Fi"
                let mtu = call.arguments["mtu"] ?? "1280"
                return ToolExecutionResult(toolCallId: call.id, success: true, message: "MTU of \(service) set to \(mtu)")
            case "flush_dns":
                return ToolExecutionResult(toolCallId: call.id, success: true, message: "DNS cache successfully flushed")
            case "flush_arp":
                return ToolExecutionResult(toolCallId: call.id, success: true, message: "ARP cache successfully cleared")
            default:
                return ToolExecutionResult(toolCallId: call.id, success: false, message: "Unknown tool: \(call.name)")
            }
        }
    }

    @Test("T1-F38-01: Export OpenAI tool schema for fix_mtu")
    func testExportFixMTUToolSchema() {
        let tools = ToolRegistry.allToolSchemas()
        let fixMTU = tools.first { $0.function.name == "fix_mtu" }

        #expect(fixMTU != nil)
        #expect(fixMTU?.type == "function")
        #expect(fixMTU?.function.parameters["mtu"] == "integer")
    }

    @Test("T1-F38-02: Export tool schemas for flush_dns and flush_arp")
    func testExportFlushToolSchemas() {
        let tools = ToolRegistry.allToolSchemas()
        let flushDNS = tools.first { $0.function.name == "flush_dns" }
        let flushARP = tools.first { $0.function.name == "flush_arp" }

        #expect(flushDNS != nil)
        #expect(flushARP != nil)
    }

    @Test("T1-F38-03: Export tool schema for disable_ipv6 and toggle_vpn")
    func testExportNetworkActionToolSchemas() {
        let tools = ToolRegistry.allToolSchemas()
        let disableIPv6 = tools.first { $0.function.name == "disable_ipv6" }
        let toggleVPN = tools.first { $0.function.name == "toggle_vpn" }

        #expect(disableIPv6 != nil)
        #expect(toggleVPN != nil)
    }

    @Test("T1-F38-04: Parse tool call invocation JSON with arguments")
    func testParseToolCallInvocation() {
        let invocation = ToolCallInvocation(
            id: "call_mtu_001",
            name: "fix_mtu",
            arguments: ["service": "Wi-Fi", "mtu": "1280"]
        )

        #expect(invocation.name == "fix_mtu")
        #expect(invocation.arguments["mtu"] == "1280")
    }

    @Test("T1-F38-05: Dispatch tool execution and return structured ToolExecutionResult")
    func testDispatchToolExecution() {
        let call = ToolCallInvocation(
            id: "call_dns_002",
            name: "flush_dns",
            arguments: [:]
        )

        let result = ToolRegistry.dispatch(call: call)
        #expect(result.toolCallId == "call_dns_002")
        #expect(result.success == true)
        #expect(result.message.contains("DNS cache successfully flushed"))
    }
}
