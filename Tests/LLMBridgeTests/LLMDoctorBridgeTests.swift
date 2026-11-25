import Testing
import Foundation
import Network
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

    @Test("sendChat transmits custom user message with telemetry and appendToolResult feeds history")
    func testSendChatAndAppendToolResult() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .text("Applied MTU 1280 guidance.")
        let port = try await server.start()
        defer { server.stop() }

        let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        let bridge = LLMDoctorBridge()
        let report = NetworkTelemetryReport(gatewayRTT: 14.2)

        let analysis = try await bridge.sendChat(
            message: "My cellular hotspot keeps dropping TLS handshakes",
            report: report,
            endpoint: chatURL
        )
        #expect(analysis.diagnosis == "Applied MTU 1280 guidance.")

        if let bodyData = server.lastReceivedBody,
           let bodyJSON = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let messages = bodyJSON["messages"] as? [[String: Any]],
           let model = bodyJSON["model"] as? String {
            #expect(model == "qwen2.5-coder-7b-instruct") // Dynamically discovered from /v1/models
            let userMsg = messages.last(where: { ($0["role"] as? String) == "user" })?["content"] as? String ?? ""
            #expect(userMsg.contains("My cellular hotspot keeps dropping TLS handshakes"))
            #expect(userMsg.contains("14.2"))
        } else {
            Issue.record("Expected recorded JSON request body")
        }

        // Feed approved tool result back into history and send follow-up chat
        bridge.appendToolResult(toolCallId: "call_fix_1", name: "fix_mtu", output: "MTU of Wi-Fi set to 1280")
        let recordedToolMsg = bridge.conversationHistory.contains {
            $0.role == "tool" && $0.toolCallId == "call_fix_1" && $0.name == "fix_mtu"
        }
        #expect(recordedToolMsg)

        _ = try await bridge.sendChat(message: "Verify now", report: nil, endpoint: chatURL)
        if let followBody = server.lastReceivedBody,
           let json = try JSONSerialization.jsonObject(with: followBody) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]] {
            let toolEntry = messages.first(where: { ($0["role"] as? String) == "tool" })
            #expect(toolEntry?["tool_call_id"] as? String == "call_fix_1")
            #expect(toolEntry?["name"] as? String == "fix_mtu")
            #expect(toolEntry?["content"] as? String == "MTU of Wi-Fi set to 1280")
        } else {
            Issue.record("Expected follow-up JSON body with tool message")
        }
    }

    @Test("Configurable selectedModel, empty models fallback, and dictionary tool arguments parsing")
    func testSelectedModelAndDictionaryToolArguments() async throws {
        final class CustomMockServer: @unchecked Sendable {
            private let lock = NSLock()
            private var listener: NWListener?
            private var conns: [NWConnection] = []
            private(set) var capturedModels: [String] = []
            var emptyModelsList = true

            func start() async throws -> UInt16 {
                final class OnceGate: @unchecked Sendable {
                    private let lock = NSLock()
                    private var resumed = false
                    func tryEnter() -> Bool {
                        lock.withLock {
                            guard !resumed else { return false }
                            resumed = true
                            return true
                        }
                    }
                }

                return try await withCheckedThrowingContinuation { cont in
                    let gate = OnceGate()
                    do {
                        let params = NWParameters.tcp
                        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                        let l = try NWListener(using: params)
                        self.lock.withLock { self.listener = l }
                        l.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if let port = l.port?.rawValue {
                                    if gate.tryEnter() { cont.resume(returning: port) }
                                } else {
                                    l.cancel()
                                    if gate.tryEnter() {
                                        cont.resume(throwing: NSError(domain: "CustomMockServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to determine bound port"]))
                                    }
                                }
                            case .waiting(let err), .failed(let err):
                                l.cancel()
                                if gate.tryEnter() { cont.resume(throwing: err) }
                            case .cancelled:
                                if gate.tryEnter() {
                                    cont.resume(throwing: NSError(domain: "CustomMockServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Listener cancelled before ready"]))
                                }
                            default:
                                break
                            }
                        }
                        l.newConnectionHandler = { [weak self] conn in
                            self?.handle(conn)
                        }
                        l.start(queue: .global())
                        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                            if gate.tryEnter() {
                                l.cancel()
                                cont.resume(throwing: NSError(domain: "CustomMockServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Startup timed out"]))
                            }
                        }
                    } catch {
                        if gate.tryEnter() { cont.resume(throwing: error) }
                    }
                }
            }

            func stop() {
                listener?.cancel()
                lock.withLock {
                    conns.forEach { $0.cancel() }
                    conns.removeAll()
                }
            }

            private func handle(_ conn: NWConnection) {
                lock.withLock { conns.append(conn) }
                conn.start(queue: .global())
                recv(conn, acc: Data())
            }

            private func recv(_ conn: NWConnection, acc: Data) {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
                    guard let self = self else { return }
                    var buf = acc
                    if let d = data { buf.append(d) }
                    if let sep = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                        let hdrStr = String(data: buf[..<sep.lowerBound], encoding: .utf8) ?? ""
                        let body = buf[sep.upperBound...]
                        var contentLen = 0
                        for line in hdrStr.components(separatedBy: "\r\n") {
                            if line.lowercased().hasPrefix("content-length:") {
                                contentLen = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                            }
                        }
                        if body.count >= contentLen {
                            self.respond(hdrStr: hdrStr, body: Data(body.prefix(contentLen)), conn: conn)
                            return
                        }
                    }
                    if !isComplete { self.recv(conn, acc: buf) }
                }
            }

            private func respond(hdrStr: String, body: Data, conn: NWConnection) {
                let firstLine = hdrStr.components(separatedBy: "\r\n").first ?? ""
                let respJSON: String
                if firstLine.contains("/v1/models") {
                    respJSON = emptyModelsList
                        ? "{\"object\":\"list\",\"data\":[]}"
                        : "{\"object\":\"list\",\"data\":[{\"id\":\"detected-model\"}]}"
                } else {
                    if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let model = json["model"] as? String {
                        lock.withLock { capturedModels.append(model) }
                    }
                    // Return arguments as a JSON dictionary object instead of string
                    respJSON = """
                    {
                      "choices": [{
                        "message": {
                          "role": "assistant",
                          "content": "Adjusting MTU",
                          "tool_calls": [{
                            "id": "call_dict_1",
                            "type": "function",
                            "function": {
                              "name": "fix_mtu",
                              "arguments": {"interface": "Wi-Fi", "mtu": 1280}
                            }
                          }]
                        }
                      }]
                    }
                    """
                }
                let bodyData = Data(respJSON.utf8)
                let hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
                var full = Data(hdr.utf8)
                full.append(bodyData)
                conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
            }
        }

        let customServer = CustomMockServer()
        let port = try await customServer.start()
        defer { customServer.stop() }
        let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!

        let bridge = LLMDoctorBridge()
        let analysisFallback = try await bridge.sendChat(message: "Check MTU", report: nil, endpoint: chatURL)
        #expect(analysisFallback.toolCalls.count == 1)
        #expect(analysisFallback.toolCalls[0].name == "fix_mtu")
        #expect(analysisFallback.toolCalls[0].arguments["interface"] as? String == "Wi-Fi")
        #expect(analysisFallback.toolCalls[0].arguments["mtu"] as? Int == 1280)
        #expect(customServer.capturedModels.last == "local-model")

        bridge.selectedModel = "custom-mlx-7b"
        _ = try await bridge.sendChat(message: "Re-check", report: nil, endpoint: chatURL)
        #expect(customServer.capturedModels.last == "custom-mlx-7b")
    }
}
