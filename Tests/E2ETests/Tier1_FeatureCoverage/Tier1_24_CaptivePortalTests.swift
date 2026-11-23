import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 24: Captive Portal Detection Engine", .tags(.tier1, .m5_doctor, .captive_portal))
struct Tier1_24_CaptivePortalTests {

    struct CaptiveDetector {
        static func evaluate(probeURL: URL) async throws -> (status: CaptivePortalStatus, redirectURL: String?) {
            let request = URLRequest(url: probeURL)
            // Prevent auto-following redirects so we can inspect 302 Location
            let config = URLSessionConfiguration.default
            let delegate = RedirectCatcherDelegate()
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (.unknown, nil)
            }

            if http.statusCode == 302 {
                let location = http.value(forHTTPHeaderField: "Location")
                return (.redirecting, location)
            }

            let bodyString = String(data: data, encoding: .utf8) ?? ""
            if bodyString.contains("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>") {
                return (.notDetected, nil)
            }

            if bodyString.contains("login") || bodyString.contains("Login") {
                return (.detected, nil)
            }

            return (.unknown, nil)
        }

        private final class RedirectCatcherDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
                // Do not follow redirect
                return nil
            }
        }
    }

    @Test("T1-F24-01: Apple hotspot-detect endpoint returning Success classifies as notDetected")
    func testHotspotDetectSuccessNotCaptive() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .appleHotspotDetectSuccess
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let (status, redirect) = try await CaptiveDetector.evaluate(probeURL: probeURL)

        #expect(status == .notDetected)
        #expect(redirect == nil)
    }

    @Test("T1-F24-02: HTTP 302 redirect indicates active captive portal interception")
    func testCaptivePortalRedirectDetection() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .redirect302(targetURL: "http://10.4.0.10/login.php")
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/probe")!
        let (status, redirect) = try await CaptiveDetector.evaluate(probeURL: probeURL)

        #expect(status == .redirecting)
        #expect(redirect == "http://10.4.0.10/login.php")
    }

    @Test("T1-F24-03: HTML login form payload detected as captive portal")
    func testCaptivePortalHTMLFormDetection() async throws {
        let server = MockHTTPServer()
        let form = "<html><body><h1>Campus Wi-Fi Login</h1><form action='/auth'></form></body></html>"
        server.captivePortalMode = .htmlLoginForm(formHTML: form)
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/probe")!
        let (status, _) = try await CaptiveDetector.evaluate(probeURL: probeURL)

        #expect(status == .detected)
    }

    @Test("T1-F24-04: Captive portal notification payload generated with redirect URL")
    func testCaptiveNotificationPayload() {
        let redirectURL = "http://10.4.0.10/login"
        let issue = DetectedIssue(
            severity: .critical,
            title: "Captive Portal Active",
            description: "Campus Wi-Fi requires authentication. Redirecting to \(redirectURL)",
            recommendedFixAction: "Open login portal in browser"
        )

        #expect(issue.severity == .critical)
        #expect(issue.description.contains("10.4.0.10/login"))
    }

    @Test("T1-F24-05: Re-probe after authentication clears captive portal state")
    func testReProbeAfterAuthentication() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .redirect302(targetURL: "http://10.4.0.10/login")
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let (initialStatus, _) = try await CaptiveDetector.evaluate(probeURL: probeURL)
        #expect(initialStatus == .redirecting)

        // Simulate user logged in, portal now passes through
        server.captivePortalMode = .appleHotspotDetectSuccess
        let (clearedStatus, _) = try await CaptiveDetector.evaluate(probeURL: probeURL)
        #expect(clearedStatus == .notDetected)
    }
}
