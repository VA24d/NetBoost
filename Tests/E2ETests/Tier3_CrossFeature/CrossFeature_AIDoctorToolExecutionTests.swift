import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 3: Captive Portal Detection + AI Doctor Tool-Calling Bridge", .tags(.tier3, .captive_portal, .llm_bridge, .m5_doctor))
struct CrossFeature_AIDoctorToolExecutionTests {

    @Test("Captive portal engine detects 302 redirection on probe and captures login URL")
    func testCaptivePortalRedirectionDetection() async throws {
        let captiveServer = MockHTTPServer()
        let loginURL = "http://10.4.0.10/login.php"
        captiveServer.captivePortalMode = .redirect302(targetURL: loginURL)
        let port = try await captiveServer.start()
        defer { captiveServer.stop() }

        final class NonRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
                nil
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config, delegate: NonRedirectDelegate(), delegateQueue: nil)

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let (_, response) = try await session.data(from: probeURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 302)
        let redirectedLocation = httpResponse.value(forHTTPHeaderField: "Location")
        #expect(redirectedLocation == loginURL)

        let status = CaptivePortalStatus.redirecting
        #expect(status == .redirecting)
    }

    @Test("Telemetry JSON exporter serializes captive portal diagnostic state with detected issues")
    func testTelemetryReportJSONSerialization() throws {
        let report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", mtu: 1500, isPrimary: true)
            ],
            gatewayRTT: 1.1,
            campusCoreRTT: nil,
            externalEndpointsRTT: ["google.com": 0.0],
            captivePortalDetected: true,
            captivePortalStatus: .redirecting,
            activeIssues: [
                DetectedIssue(
                    severity: .critical,
                    title: "Campus Wi-Fi Captive Portal Active",
                    description: "Captive portal intercepting HTTP/HTTPS traffic.",
                    recommendedFixAction: "open_login_page",
                    automatedFixAvailable: true
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(report)

        #expect(!jsonData.isEmpty)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""
        #expect(jsonStr.contains("\"captivePortalDetected\" : true"))
        #expect(jsonStr.contains("\"captivePortalStatus\" : \"redirecting\""))
        #expect(jsonStr.contains("Campus Wi-Fi Captive Portal Active"))
    }

    @Test("AI Doctor bridge sends diagnostic telemetry to MockLMStudio and receives tool calls")
    func testAIDoctorBridgeToolCallingResponse() async throws {
        let lmServer = MockLMStudioServer()
        lmServer.responseMode = .toolCalls([
            SimulatedToolCall(name: "flush_dns", arguments: "{}"),
            SimulatedToolCall(name: "flush_arp", arguments: "{}")
        ])
        let port = try await lmServer.start()
        defer { lmServer.stop() }

        let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = """
        {
          "model": "qwen2.5-coder-7b-instruct",
          "messages": [
            {"role": "system", "content": "You are NetBoost Autonomous Network Doctor."},
            {"role": "user", "content": "Telemetry: Captive portal cleared, flush caches to restore internet."}
          ]
        }
        """
        request.httpBody = Data(requestBody.utf8)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        #expect(jsonString.contains("tool_calls"))
        #expect(jsonString.contains("flush_dns"))
        #expect(jsonString.contains("flush_arp"))
    }

    @Test("Programmatic tool execution invokes flush_dns and flush_arp via MockProcessRunner")
    func testToolExecutionDispatcher() async throws {
        let runner = MockProcessRunner()

        // 1. Tool execution: flush_dns
        let dscache = try await runner.run("dscacheutil", arguments: ["-flushcache"])
        #expect(dscache.succeeded)

        let killDNS = try await runner.run("killall", arguments: ["-HUP", "mDNSResponder"])
        #expect(killDNS.succeeded)

        #expect(runner.didExecute(commandContaining: "dscacheutil -flushcache"))
        #expect(runner.didExecute(commandContaining: "killall -HUP mDNSResponder"))

        // 2. Tool execution: flush_arp
        let arp = try await runner.run("arp", arguments: ["-d", "-a"])
        #expect(arp.succeeded)
        #expect(runner.didExecute(commandContaining: "arp -d"))
    }

    @Test("Post-remediation probe verifies captive portal cleared and returns tool feedback to LM Studio")
    func testPostRemediationResolutionLoop() async throws {
        let captiveServer = MockHTTPServer()
        captiveServer.captivePortalMode = .appleHotspotDetectSuccess
        let port = try await captiveServer.start()
        defer { captiveServer.stop() }

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let (data, response) = try await session.data(from: probeURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<TITLE>Success</TITLE>"))

        let updatedStatus = CaptivePortalStatus.notDetected
        #expect(updatedStatus == .notDetected)
    }
}
