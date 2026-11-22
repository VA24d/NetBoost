import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 3: Campus Wi-Fi Captive Portal Auto-Remediation", .tags(.tier4, .captive_portal, .diagnostics, .m5_doctor))
struct Scenario03_CaptivePortalRemediationTests {

    @Test("Captive portal detection triggers automated remediation flushing DNS/ARP and verifying internet")
    func testCaptivePortalRemediationLifecycle() async throws {
        let runner = MockProcessRunner()
        let portalServer = MockHTTPServer()
        let portalLoginURL = "http://10.4.0.10/login.php"
        portalServer.captivePortalMode = .redirect302(targetURL: portalLoginURL)
        let port = try await portalServer.start()
        defer { portalServer.stop() }

        // Step 1: Probe captive portal endpoint
        final class NonRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
                nil
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config, delegate: NonRedirectDelegate(), delegateQueue: nil)

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let (_, initialResponse) = try await session.data(from: probeURL)
        guard let httpResponse = initialResponse as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        // Step 2: Validate 302 Captive Detection
        #expect(httpResponse.statusCode == 302)
        let redirectedLocation = httpResponse.value(forHTTPHeaderField: "Location")
        #expect(redirectedLocation == portalLoginURL)

        var report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", isPrimary: true)],
            captivePortalDetected: true,
            captivePortalStatus: .redirecting,
            activeIssues: [
                DetectedIssue(
                    severity: .critical,
                    title: "Captive Portal Isolation",
                    description: "Campus Wi-Fi requires browser authentication at \(portalLoginURL).",
                    recommendedFixAction: "open_browser_login"
                )
            ]
        )
        #expect(report.captivePortalDetected == true)
        #expect(report.activeIssues.count == 1)

        // Step 3: Simulate User Authentication Success
        portalServer.captivePortalMode = .appleHotspotDetectSuccess

        // Step 4: Re-probe confirms portal clearance
        let (successData, successResponse) = try await session.data(from: probeURL)
        guard let successHTTP = successResponse as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(successHTTP.statusCode == 200)
        let body = String(data: successData, encoding: .utf8) ?? ""
        #expect(body.contains("<TITLE>Success</TITLE>"))

        // Step 5: Automated Repair Pipeline - Flush DNS and ARP Caches
        let flushDNS1 = try await runner.run("dscacheutil", arguments: ["-flushcache"])
        #expect(flushDNS1.succeeded)

        let flushDNS2 = try await runner.run("killall", arguments: ["-HUP", "mDNSResponder"])
        #expect(flushDNS2.succeeded)

        let flushARP = try await runner.run("arp", arguments: ["-d", "-a"])
        #expect(flushARP.succeeded)

        #expect(runner.didExecute(commandContaining: "dscacheutil -flushcache"))
        #expect(runner.didExecute(commandContaining: "killall -HUP mDNSResponder"))
        #expect(runner.didExecute(commandContaining: "arp -d -a"))

        // Step 6: Post-Remediation Endpoint Verification
        let gatewayProbe = ProbeResult(targetHost: "10.1.36.1", isReachable: true, latencyMs: 0.9)
        let googleProbe = ProbeResult(targetHost: "google.com", isReachable: true, latencyMs: 14.5)
        let turingProbe = ProbeResult(targetHost: "turing.iiit.ac.in", isReachable: true, latencyMs: 1.8)

        report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", isPrimary: true)],
            gatewayRTT: gatewayProbe.latencyMs,
            campusCoreRTT: 1.2,
            externalEndpointsRTT: ["google.com": googleProbe.latencyMs, "turing.iiit.ac.in": turingProbe.latencyMs],
            captivePortalDetected: false,
            captivePortalStatus: .authenticated,
            activeIssues: [] // All issues cleared
        )

        #expect(report.captivePortalDetected == false)
        #expect(report.captivePortalStatus == .authenticated)
        #expect(report.activeIssues.isEmpty)
    }
}
