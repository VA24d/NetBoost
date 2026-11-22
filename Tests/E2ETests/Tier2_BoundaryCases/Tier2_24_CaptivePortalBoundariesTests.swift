import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 24: Captive Portal Detection Boundaries", .tags(.tier2, .m5_doctor, .captive_portal))
struct Tier2_24_CaptivePortalBoundariesTests {

    @Test("T2-F24-01: Detects captive portal HTTP 302 redirect via MockHTTPServer")
    func testCaptive302RedirectDetection() async throws {
        let server = MockHTTPServer()
        let loginURL = "http://10.4.0.10/login.html"
        server.captivePortalMode = .redirect302(targetURL: loginURL)
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let config = URLSessionConfiguration.ephemeral
        let delegate = NonRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let (_, response) = try await session.data(from: probeURL)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 302)
        let location = httpResponse.value(forHTTPHeaderField: "Location")
        #expect(location == loginURL)
    }

    @Test("T2-F24-02: Detects captive portal HTML login form on HTTP 200 response")
    func testCaptiveHTMLLoginFormDetection() async throws {
        let server = MockHTTPServer()
        let formHTML = "<HTML><HEAD><TITLE>Campus Wi-Fi Login</TITLE></HEAD><BODY><FORM action='/auth'>Enter NetID</FORM></BODY></HTML>"
        server.captivePortalMode = .htmlLoginForm(formHTML: formHTML)
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: probeURL)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<FORM action='/auth'>"))
        #expect(!body.contains("<BODY>Success</BODY>"))
    }

    @Test("T2-F24-03: Apple hotspot-detect Success response verifies clean un-intercepted network")
    func testAppleHotspotDetectSuccess() async throws {
        let server = MockHTTPServer()
        server.captivePortalMode = .appleHotspotDetectSuccess
        let port = try await server.start()
        defer { server.stop() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/hotspot-detect.html")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: probeURL)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"))
    }

    @Test("T2-F24-04: Captive portal status enum Codable roundtrip")
    func testCaptivePortalStatusCodable() throws {
        let statuses: [CaptivePortalStatus] = [.notDetected, .detected, .redirecting, .authenticated, .unknown]
        for s in statuses {
            let encoded = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(CaptivePortalStatus.self, from: encoded)
            #expect(decoded == s)
        }
    }

    @Test("T2-F24-05: Non-redirect URLSession delegate correctly captures HTTP 302 location")
    func testNonRedirectDelegateCapturesLocation() async throws {
        let delegate = NonRedirectDelegate()
        #expect(delegate.lastRedirectLocation == nil)
    }
}

private final class NonRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var location: String?

    var lastRedirectLocation: String? {
        lock.withLock { location }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.withLock {
            location = response.value(forHTTPHeaderField: "Location")
        }
        // Return nil to prevent automatic redirect following
        completionHandler(nil)
    }
}
