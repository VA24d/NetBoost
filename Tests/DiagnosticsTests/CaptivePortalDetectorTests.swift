import Testing
import Foundation
@testable import NetBoostCore

@Suite("Campus Diagnostics: CaptivePortalDetector Unit & Integration Tests")
struct CaptivePortalDetectorTests {

    @Test("Detects Apple hotspot-detect success payload as notDetected")
    func testAppleSuccessDetection() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .appleHotspotDetectSuccess
        let port = try await server.start()
        defer { server.stop() }

        let detector = CaptivePortalDetector()
        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!

        let (status, redirectURL) = try await detector.evaluate(probeURL: probeURL)
        #expect(status == .notDetected)
        #expect(redirectURL == nil)

        let statusOnly = await detector.checkStatus(probeURL: probeURL)
        #expect(statusOnly == .notDetected)
    }

    @Test("Detects HTTP 302 captive redirection and extracts portal login URL")
    func testCaptive302Redirection() async throws {
        let server = MockHTTPServer()
        let campusLogin = "http://10.4.0.10/login.php?res=notyet"
        server.captivePortalMode = .redirect302(targetURL: campusLogin)
        let port = try await server.start()
        defer { server.stop() }

        let detector = CaptivePortalDetector()
        let probeURL = URL(string: "http://127.0.0.1:\(port)/probe")!

        let (status, redirectURL) = try await detector.evaluate(probeURL: probeURL)
        #expect(status == .redirecting)
        #expect(redirectURL == campusLogin)

        let issue = detector.createIssueIfActive(status: status, redirectURL: redirectURL)
        #expect(issue != nil)
        #expect(issue?.severity == .critical)
        #expect(issue?.description.contains("10.4.0.10") == true)
        #expect(issue?.automatedFixAvailable == true)
    }

    @Test("Detects HTML login form content without redirect as detected status")
    func testCaptiveHTMLForm() async throws {
        let server = MockHTTPServer()
        let loginPage = "<html><body><h1>IIIT Hyderabad Wi-Fi Login</h1><form action='/auth'></form></body></html>"
        server.captivePortalMode = .htmlLoginForm(formHTML: loginPage)
        let port = try await server.start()
        defer { server.stop() }

        let detector = CaptivePortalDetector()
        let probeURL = URL(string: "http://127.0.0.1:\(port)/probe")!

        let (status, redirectURL) = try await detector.evaluate(probeURL: probeURL)
        #expect(status == .detected)
        #expect(redirectURL == nil)

        let issue = detector.createIssueIfActive(status: status, redirectURL: redirectURL)
        #expect(issue != nil)
        #expect(issue?.severity == .critical)
        #expect(issue?.recommendedFixAction == "open_login_page")
    }

    @Test("Handles offline or unreachable probe endpoint gracefully")
    func testOfflineProbeReturnsUnknown() async {
        let detector = CaptivePortalDetector()
        let deadURL = URL(string: "http://127.0.0.1:54321/hotspot-detect.html")!

        let status = await detector.checkStatus(probeURL: deadURL)
        #expect(status == .unknown)
    }

    @Test("CaptiveDetector static evaluate matches detector instance behavior")
    func testStaticCaptiveDetector() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .appleHotspotDetectSuccess
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let (status, redirect) = try await CaptiveDetector.evaluate(probeURL: probeURL)
        #expect(status == .notDetected)
        #expect(redirect == nil)
    }

    @Test("Repeated CaptiveDetector evaluations complete cleanly without leaking sessions")
    func testRepeatedCaptiveEvaluationsCompleteCleanly() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .appleHotspotDetectSuccess
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        for _ in 0..<5 {
            let (status, redirect) = try await CaptiveDetector.evaluate(probeURL: probeURL)
            #expect(status == .notDetected)
            #expect(redirect == nil)
        }
    }
}
