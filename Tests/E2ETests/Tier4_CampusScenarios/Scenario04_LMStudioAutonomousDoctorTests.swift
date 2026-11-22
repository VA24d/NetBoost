import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 4: Local LLM (LM Studio) Autonomous Doctor Diagnostic & Remediation", .tags(.tier4, .llm_bridge, .diagnostics, .m5_doctor))
struct Scenario04_LMStudioAutonomousDoctorTests {

    @Test("Autonomous AI Doctor loop: Telemetry ingest -> Tool calling -> Remediation execution -> Confirmation")
    func testLMStudioAutonomousDoctorRepairLoop() async throws {
        let runner = MockProcessRunner()
        let lmServer = MockLMStudioServer()

        // Configure LM Studio with specific remediation tool calls
        lmServer.responseMode = .toolCalls([
            SimulatedToolCall(
                id: "call_mtu_001",
                name: "fix_mtu",
                arguments: "{\"service\":\"Wi-Fi\",\"mtu\":1280}"
            ),
            SimulatedToolCall(
                id: "call_dns_002",
                name: "flush_dns",
                arguments: "{}"
            )
        ])

        let port = try await lmServer.start()
        defer { lmServer.stop() }

        // Step 1: Query models endpoint to ensure model availability
        let modelsURL = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let (modelsData, modelsResp) = try await URLSession.shared.data(from: modelsURL)
        guard let httpModels = modelsResp as? HTTPURLResponse, httpModels.statusCode == 200 else {
            Issue.record("Failed to query models endpoint")
            return
        }
        let modelsJSON = String(data: modelsData, encoding: .utf8) ?? ""
        #expect(modelsJSON.contains("qwen2.5-coder-7b-instruct"))

        // Step 2: Compile Telemetry Report with injected network issues
        let initialTelemetry = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", mtu: 1500, isPrimary: true)
            ],
            gatewayRTT: 185.0, // High latency / fragmentation
            campusCoreRTT: nil,
            externalEndpointsRTT: ["google.com": 0.0],
            captivePortalDetected: false,
            activeIssues: [
                DetectedIssue(
                    severity: .warning,
                    title: "Cellular Hotspot MTU Mismatch",
                    description: "Interface en0 MTU is 1500 on cellular uplink, exceeding 1280.",
                    recommendedFixAction: "fix_mtu"
                ),
                DetectedIssue(
                    severity: .warning,
                    title: "Stale DNS Cache",
                    description: "Domain resolution timeouts detected across external endpoints.",
                    recommendedFixAction: "flush_dns"
                )
            ]
        )

        // Step 3: Serialize and Send Telemetry to Chat Completions
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let telemetryJSON = try encoder.encode(initialTelemetry)
        let telemetryStr = String(data: telemetryJSON, encoding: .utf8) ?? "{}"

        let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var chatRequest = URLRequest(url: chatURL)
        chatRequest.httpMethod = "POST"
        chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatPayload = """
        {
          "model": "qwen2.5-coder-7b-instruct",
          "messages": [
            {"role": "system", "content": "You are NetBoost Autonomous Doctor."},
            {"role": "user", "content": "\(telemetryStr.replacingOccurrences(of: "\"", with: "\\\""))"}
          ]
        }
        """
        chatRequest.httpBody = Data(chatPayload.utf8)

        let (chatData, chatResp) = try await URLSession.shared.data(for: chatRequest)
        guard let httpChat = chatResp as? HTTPURLResponse, httpChat.statusCode == 200 else {
            Issue.record("Chat completion request failed")
            return
        }

        // Step 4: Parse LLM Tool Calls from Response
        let responseJSON = try JSONSerialization.jsonObject(with: chatData) as? [String: Any]
        let choices = responseJSON?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let toolCalls = message?["tool_calls"] as? [[String: Any]]

        #expect(toolCalls?.count == 2)

        // Step 5: Execute Tool Calls Programmatically via MockProcessRunner
        for toolCall in toolCalls ?? [] {
            guard let function = toolCall["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let argsStr = function["arguments"] as? String else {
                continue
            }

            switch name {
            case "fix_mtu":
                if let argsData = argsStr.data(using: .utf8),
                   let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
                   let service = args["service"] as? String,
                   let mtu = args["mtu"] as? Int {
                    let cmd = try await runner.run("networksetup", arguments: ["-setMTU", service, "\(mtu)"])
                    #expect(cmd.succeeded)
                }

            case "flush_dns":
                let flush1 = try await runner.run("dscacheutil", arguments: ["-flushcache"])
                let flush2 = try await runner.run("killall", arguments: ["-HUP", "mDNSResponder"])
                #expect(flush1.succeeded)
                #expect(flush2.succeeded)

            default:
                Issue.record("Unknown tool call: \(name)")
            }
        }

        // Verify Process Runner intercepted both remediations
        #expect(runner.didExecute(commandContaining: "networksetup -setMTU Wi-Fi 1280"))
        #expect(runner.didExecute(commandContaining: "dscacheutil -flushcache"))
        #expect(runner.didExecute(commandContaining: "killall -HUP mDNSResponder"))

        // Step 6: Final Turn Confirmation
        lmServer.responseMode = .text("Network health fully restored: MTU set to 1280 and DNS caches flushed.")
        var confirmRequest = URLRequest(url: chatURL)
        confirmRequest.httpMethod = "POST"
        confirmRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        confirmRequest.httpBody = Data("{\"model\":\"qwen2.5-coder-7b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Remediations applied successfully.\"}]}".utf8)

        let (confirmData, _) = try await URLSession.shared.data(for: confirmRequest)
        let confirmStr = String(data: confirmData, encoding: .utf8) ?? ""
        #expect(confirmStr.contains("Network health fully restored"))
    }
}
