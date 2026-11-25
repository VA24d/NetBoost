import Foundation
import Testing
import Network
@testable import NetBoostCore

// MARK: - Mock HTTP Server Tests

@Suite("Mock HTTP Range Server Verification", .tags(.mock, .range_206))
struct MockHTTPServerVerificationTests {

    @Test("Verify dynamic port binding on ephemeral port")
    func testDynamicPortBinding() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        #expect(port > 0)
        let isReachable = await TestAssertions.isLocalPortReachable(port: port)
        #expect(isReachable)
    }

    @Test("Verify HEAD request returns Content-Length and Accept-Ranges")
    func testHEADProbe() async throws {
        let testData = TestAssertions.generateDeterministicPayload(size: 8192)
        let server = MockHTTPServer(payload: testData)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/probe.iso")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.expectedContentLength == 8192)
        let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
        #expect(acceptRanges == "bytes")
    }

    @Test("Verify GET without Range returns full 200 OK payload")
    func testFullGET() async throws {
        let testData = TestAssertions.generateDeterministicPayload(size: 4096)
        let server = MockHTTPServer(payload: testData)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/full.bin")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        #expect(data == testData)
    }

    @Test("Verify GET with Range returns 206 Partial Content and exact byte slice")
    func testRangeGETPartialContent() async throws {
        let testData = TestAssertions.generateDeterministicPayload(size: 16384)
        let server = MockHTTPServer(payload: testData)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/slice.bin")!
        var request = URLRequest(url: url)
        request.setValue("bytes=100-299", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 206)
        #expect(data.count == 200)

        let expectedSlice = testData.subdata(in: 100..<300)
        #expect(data == expectedSlice)

        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range")
        #expect(contentRange == "bytes 100-299/16384")
    }

    @Test("Verify suffix Range request bytes=-50")
    func testRangeSuffixGET() async throws {
        let testData = TestAssertions.generateDeterministicPayload(size: 1000)
        let server = MockHTTPServer(payload: testData)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/suffix.bin")!
        var request = URLRequest(url: url)
        request.setValue("bytes=-50", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 206)
        #expect(data.count == 50)
        let expectedSlice = testData.suffix(50)
        #expect(data == expectedSlice)
    }

    @Test("Verify fault injection: 416 Range Not Satisfiable")
    func testFault416RangeNotSatisfiable() async throws {
        let server = MockHTTPServer()
        server.forceRange416 = true
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/error416.bin")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 416)
    }

    @Test("Verify fault injection: 500 Internal Server Error")
    func testFault500InternalServerError() async throws {
        let server = MockHTTPServer()
        server.force500Error = true
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/error500.bin")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 500)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("Internal Server Error"))
    }

    @Test("Verify captive portal: 302 redirect mode")
    func testCaptivePortal302Redirect() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .redirect302(targetURL: "http://login.iiit.ac.in/portal")
        let port = try await server.start()
        defer { server.stop() }

        // Use custom URLSession delegate that does not follow redirects
        final class NonRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
                return nil // Do not follow redirect
            }
        }

        let delegate = NonRedirectDelegate()
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let url = URL(string: "http://127.0.0.1:\(port)/generate_204")!
        let (_, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 302)
        let location = httpResponse.value(forHTTPHeaderField: "Location")
        #expect(location == "http://login.iiit.ac.in/portal")
    }

    @Test("Verify captive portal: HTML login form mode")
    func testCaptivePortalLoginForm() async throws {
        let server = MockHTTPServer()
        let loginForm = "<HTML><BODY><FORM action='/auth' method='POST'><INPUT name='user'></FORM></BODY></HTML>"
        server.captivePortalMode = .htmlLoginForm(formHTML: loginForm)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/detect")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.contains("text/html"))
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<FORM action='/auth'"))
    }

    @Test("Verify Apple hotspot-detect probe returns Success")
    func testAppleHotspotDetect() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<TITLE>Success</TITLE>"))
    }

    @Test("Verify request tracking captures method and path")
    func testRequestTracking() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/tracked/resource?foo=bar")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        _ = try? await session.data(from: url)

        let recorded = server.recordedRequests
        #expect(recorded.count >= 1)
        if let first = recorded.first {
            #expect(first.method == "GET")
            #expect(first.path.contains("/tracked/resource"))
        }
    }
}

// MARK: - Mock SOCKS5 Target Server Tests

@Suite("Mock SOCKS5 Target Echo Server Verification", .tags(.mock, .socks5))
struct MockSOCKS5TargetServerVerificationTests {

    @Test("Verify TCP raw echo roundtrip")
    func testRawEchoRoundtrip() async throws {
        let server = MockSOCKS5TargetServer(mode: .rawEcho)
        let port = try await server.start()
        defer { server.stop() }

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

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }

        let sentMessage = "NetBoost SOCKS5 Forwarding Verification String"
        let sentData = Data(sentMessage.utf8)
        let gate = OnceGate()

        let receivedData: Data = try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: sentData, completion: .contentProcessed { error in
                        if let error = error {
                            connection.cancel()
                            if gate.tryEnter() { continuation.resume(throwing: error) }
                            return
                        }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                            if let error = error {
                                if gate.tryEnter() { continuation.resume(throwing: error) }
                            } else if let data = data {
                                if gate.tryEnter() { continuation.resume(returning: data) }
                            } else {
                                if gate.tryEnter() { continuation.resume(returning: Data()) }
                            }
                        }
                    })
                case .waiting(let error), .failed(let error):
                    connection.cancel()
                    if gate.tryEnter() { continuation.resume(throwing: error) }
                case .cancelled:
                    if gate.tryEnter() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                if gate.tryEnter() {
                    connection.cancel()
                    continuation.resume(throwing: POSIXError(.ETIMEDOUT))
                }
            }
        }

        #expect(receivedData == sentData)
        #expect(server.totalBytesReceived >= sentData.count)
        #expect(server.totalBytesSent >= sentData.count)
    }

    @Test("Verify HTTP echo mode returns HTTP 200 OK")
    func testHTTPEchoMode() async throws {
        let server = MockSOCKS5TargetServer(mode: .httpEcho)
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/proxy-test")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let responseStr = String(data: data, encoding: .utf8) ?? ""
        #expect(responseStr.contains("Echo: Received"))
    }
}

// MARK: - Mock LM Studio Server Tests

@Suite("Mock LM Studio Server Verification", .tags(.mock, .llm_bridge))
struct MockLMStudioServerVerificationTests {

    @Test("Verify /v1/models endpoint returns models list")
    func testModelsEndpoint() async throws {
        let server = MockLMStudioServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let jsonStr = String(data: data, encoding: .utf8) ?? ""
        #expect(jsonStr.contains("qwen2.5-coder-7b-instruct"))
    }

    @Test("Verify /v1/chat/completions returns authentic OpenAI tool calls")
    func testChatCompletionsWithToolCalls() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .toolCalls([
            SimulatedToolCall(name: "fix_mtu", arguments: "{\"interface\":\"Wi-Fi\",\"mtu\":1280}"),
            SimulatedToolCall(name: "flush_dns", arguments: "{}")
        ])
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = "{\"model\":\"qwen2.5-coder-7b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Diagnose network\"}]}"
        request.httpBody = Data(requestBody.utf8)

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let jsonStr = String(data: data, encoding: .utf8) ?? ""
        #expect(jsonStr.contains("\"finish_reason\": \"tool_calls\""))
        #expect(jsonStr.contains("fix_mtu"))
        #expect(jsonStr.contains("flush_dns"))

        // Verify request payload capture
        let recorded = server.recordedRequests
        #expect(recorded.count >= 1)
        #expect(recorded.first?.path.contains("/v1/chat/completions") == true)
    }

    @Test("Verify text response mode")
    func testTextResponseMode() async throws {
        let server = MockLMStudioServer()
        server.responseMode = .text("All campus endpoints are reachable.")
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let jsonStr = String(data: data, encoding: .utf8) ?? ""
        #expect(jsonStr.contains("All campus endpoints are reachable."))
    }
}

// MARK: - Mock Process Runner Tests

@Suite("Mock Process Runner Verification", .tags(.mock, .process_runner))
struct MockProcessRunnerVerificationTests {

    @Test("Verify default networksetup MTU stub")
    func testDefaultNetworkSetupMTU() async throws {
        let runner = MockProcessRunner()
        let output = try await runner.run("networksetup", arguments: ["-getMTU", "Wi-Fi"])

        #expect(output.succeeded)
        #expect(output.stdout.contains("1500"))
        #expect(runner.didExecute(commandContaining: "networksetup"))
        #expect(runner.executionCount(commandContaining: "-getMTU") == 1)
    }

    @Test("Verify default service order inspection stub")
    func testDefaultServiceOrder() async throws {
        let runner = MockProcessRunner()
        let output = try await runner.run("networksetup", arguments: ["-listnetworkserviceorder"])

        #expect(output.succeeded)
        #expect(output.stdout.contains("USB 10/100 LAN"))
        #expect(output.stdout.contains("en10"))
        #expect(output.stdout.contains("Wi-Fi"))
        #expect(output.stdout.contains("en0"))
    }

    @Test("Verify default ARP and DNS flush stubs")
    func testDefaultFlushStubs() async throws {
        let runner = MockProcessRunner()

        let dscache = try await runner.run("dscacheutil", arguments: ["-flushcache"])
        #expect(dscache.succeeded)

        let arp = try await runner.run("arp", arguments: ["-an"])
        #expect(arp.succeeded)
        #expect(arp.stdout.contains("10.1.36.1"))
    }

    @Test("Verify custom stub registration and priority")
    func testCustomStubRegistration() async throws {
        let runner = MockProcessRunner()
        runner.registerStub(commandContaining: "pfctl -s info", stdout: "Status: Enabled for 100 days\n", exitCode: 0)

        let output = try await runner.run("pfctl", arguments: ["-s", "info"])
        #expect(output.succeeded)
        #expect(output.stdout.contains("Status: Enabled"))

        let recorded = runner.lastExecutedCommand()
        #expect(recorded?.executable == "pfctl")
        #expect(recorded?.arguments == ["-s", "info"])
    }
}

// MARK: - Mock Network Environment Tests

@Suite("Mock Network Environment Verification", .tags(.mock, .network_env))
struct MockNetworkEnvironmentVerificationTests {

    @Test("Verify initial Campus LAN state properties")
    func testInitialCampusLAN() {
        let env = MockNetworkEnvironment()
        #expect(env.currentState.isCampusLAN)
        #expect(!env.currentState.isCellular)
        #expect(env.currentState.primaryInterface == "en10")
        #expect(env.currentState.mtu == 1500)
    }

    @Test("Verify transition to cellular hotspot state")
    func testTransitionToCellularHotspot() {
        let env = MockNetworkEnvironment()
        env.transition(to: .defaultCellularHotspot)

        #expect(!env.currentState.isCampusLAN)
        #expect(env.currentState.isCellular)
        #expect(env.currentState.primaryInterface == "en0")
        #expect(env.currentState.mtu == 1280)
        #expect(env.transitionHistory.count == 2)
    }

    @Test("Verify AsyncStream receives state transitions in real time")
    func testAsyncStreamDelivery() async throws {
        let env = MockNetworkEnvironment(initialState: .disconnected)
        let stream = env.makeStateStream()

        var iterator = stream.makeAsyncIterator()

        // 1. Initial yield
        let first = await iterator.next()
        #expect(first == .disconnected)

        // 2. Transition to campusLAN
        env.transition(to: .defaultCampusLAN)
        let second = await iterator.next()
        #expect(second == .defaultCampusLAN)

        // 3. Transition to cellular
        env.transition(to: .defaultCellularHotspot)
        let third = await iterator.next()
        #expect(third == .defaultCellularHotspot)
    }
}

// MARK: - Fixtures Verification Tests

@Suite("Test Fixtures Integrity Verification", .tags(.m3_vpn, .diagnostics))
struct FixturesVerificationTests {

    @Test("Verify valid_macos.ovpn profile fixture")
    func testValidMacOSProfile() throws {
        let path = "Tests/Fixtures/Profiles/valid_macos.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)

        #expect(content.contains("client"))
        #expect(content.contains("remote vpn2.iiit.ac.in 1194"))
        #expect(content.contains("proto udp"))
        #expect(content.contains("dev tun"))
        #expect(content.contains("tun-mtu 1200"))
        #expect(content.contains("cipher AES-128-GCM"))
        #expect(content.contains("<ca>"))
        #expect(content.contains("-----END CERTIFICATE-----"))
    }

    @Test("Verify iiit_split.ovpn profile fixture contains 10.1.0.0/16 conflict")
    func testIIITSplitProfile() throws {
        let path = "Tests/Fixtures/Profiles/iiit_split.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)

        #expect(content.contains("route-nopull"))
        #expect(content.contains("route 10.1.0.0 255.255.0.0"))
        #expect(content.contains("route 10.8.0.0 255.255.240.0"))
    }

    @Test("Verify clean_split.ovpn profile fixture omits 10.1.0.0/16")
    func testCleanSplitProfile() throws {
        let path = "Tests/Fixtures/Profiles/clean_split.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)

        #expect(content.contains("route-nopull"))
        #expect(!content.contains("route 10.1.0.0 255.255.0.0"))
        #expect(content.contains("route 10.8.0.0 255.255.240.0"))
    }

    @Test("Verify malformed.ovpn profile fixture syntax error")
    func testMalformedProfile() throws {
        let path = "Tests/Fixtures/Profiles/malformed.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)

        #expect(!content.contains("remote "))
        #expect(!content.contains("</ca>"))
    }

    @Test("Verify sample_telemetry.json decodes into NetworkTelemetryReport")
    func testSampleTelemetryDecoding() throws {
        let path = "Tests/Fixtures/Telemetry/sample_telemetry.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(NetworkTelemetryReport.self, from: data)

        #expect(report.interfaces.count == 2)
        #expect(report.interfaces[0].bsdName == "en10")
        #expect(report.gatewayRTT == 0.82)
        #expect(report.campusCoreRTT == 1.74)
        #expect(report.externalEndpointsRTT["google.com"] == 14.8)
        #expect(report.activeIssues.count == 1)
        #expect(report.activeIssues[0].recommendedFixAction == "networksetup -setMTU Wi-Fi 1280")
    }

    @Test("Verify sample_tool_calls.json format")
    func testSampleToolCallsDecoding() throws {
        let path = "Tests/Fixtures/Telemetry/sample_tool_calls.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        let tools = json?["tools"] as? [[String: Any]]
        #expect(tools?.count == 4)
    }
}

// MARK: - Test Assertions Helpers Tests

@Suite("Test Assertions Utilities Verification", .tags(.mock))
struct TestAssertionsVerificationTests {

    @Test("Verify SHA-256 and MD5 hashing functions")
    func testHashing() {
        let input = Data("NetBoost".utf8)
        let sha256 = TestAssertions.sha256Hex(of: input)
        #expect(!sha256.isEmpty)
        #expect(sha256.count == 64)

        let md5 = TestAssertions.md5Hex(of: input)
        #expect(!md5.isEmpty)
        #expect(md5.count == 32)
    }

    @Test("Verify deterministic payload generation")
    func testDeterministicPayload() {
        let p1 = TestAssertions.generateDeterministicPayload(size: 1024)
        let p2 = TestAssertions.generateDeterministicPayload(size: 1024)
        #expect(p1.count == 1024)
        #expect(p1 == p2)
    }

    @Test("Verify pollUntil helper succeeds on true condition")
    func testPollUntilSuccess() async throws {
        actor Counter {
            var count = 0
            func incrementAndCheck() -> Bool {
                count += 1
                return count >= 3
            }
        }
        let counter = Counter()
        let success = try await TestAssertions.pollUntil(timeout: 1.0, interval: 0.02) {
            await counter.incrementAndCheck()
        }
        #expect(success)
    }
}
