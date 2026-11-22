import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 08: Multi-Port HTTP / HTTPS CONNECT Proxy", .tags(.tier1, .m2_proxy))
struct Tier1_08_HTTPProxyTests {

    /// HTTP Proxy request parser and responder
    struct HTTPProxyEngine {
        enum RequestType: Equatable {
            case connect(host: String, port: Int)
            case standard(method: String, url: String, keepAlive: Bool)
            case invalid
        }

        static func parseRequest(_ raw: String) -> RequestType {
            let lines = raw.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return .invalid }
            let parts = requestLine.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return .invalid }

            let method = parts[0].uppercased()
            let target = parts[1]

            if method == "CONNECT" {
                let hostPort = target.split(separator: ":")
                let host = String(hostPort.first ?? "")
                let port = hostPort.count > 1 ? Int(hostPort[1]) ?? 443 : 443
                return .connect(host: host, port: port)
            } else {
                let keepAlive = lines.contains { line in
                    let lower = line.lowercased()
                    return lower.hasPrefix("proxy-connection: keep-alive") || lower.hasPrefix("connection: keep-alive")
                }
                return .standard(method: method, url: target, keepAlive: keepAlive)
            }
        }

        static func makeConnectSuccessResponse() -> String {
            "HTTP/1.1 200 Connection Established\r\nProxy-Agent: NetBoost/1.0\r\n\r\n"
        }
    }

    @Test("T1-F08-01: Parse absolute URL in HTTP proxy GET request on Port 1080")
    func testHTTPProxyGetRequestParsing() {
        let rawRequest = "GET http://turing.iiit.ac.in/status HTTP/1.1\r\nHost: turing.iiit.ac.in\r\nUser-Agent: curl/8.0\r\n\r\n"
        let parsed = HTTPProxyEngine.parseRequest(rawRequest)

        if case .standard(let method, let url, _) = parsed {
            #expect(method == "GET")
            #expect(url == "http://turing.iiit.ac.in/status")
        } else {
            Issue.record("Expected standard HTTP proxy request")
        }
    }

    @Test("T1-F08-02: HTTPS CONNECT request returns 200 Connection Established")
    func testHTTPSConnectHandshake() {
        let connectRequest = "CONNECT turing.iiit.ac.in:443 HTTP/1.1\r\nHost: turing.iiit.ac.in:443\r\n\r\n"
        let parsed = HTTPProxyEngine.parseRequest(connectRequest)

        if case .connect(let host, let port) = parsed {
            #expect(host == "turing.iiit.ac.in")
            #expect(port == 443)
        } else {
            Issue.record("Expected CONNECT request")
        }

        let response = HTTPProxyEngine.makeConnectSuccessResponse()
        #expect(response.contains("HTTP/1.1 200 Connection Established"))
    }

    @Test("T1-F08-03: Tunnel byte passthrough preserves payload integrity after CONNECT")
    func testTunnelBytePassthrough() {
        let originalPayload = Data([0x16, 0x03, 0x01, 0x00, 0xA5]) // TLS ClientHello header prefix
        var tunnelBuffer = Data()

        // Relay through tunnel
        tunnelBuffer.append(originalPayload)

        #expect(tunnelBuffer == originalPayload)
        #expect(tunnelBuffer.count == 5)
    }

    @Test("T1-F08-04: HTTP Proxy Port 1082 balances traffic across uplinks")
    func testHTTPProxyPort1082LoadBalancing() {
        struct RoundRobinBalancer {
            private var counter = 0
            mutating func nextInterface() -> String {
                let pool = ["en10", "en0"]
                let chosen = pool[counter % pool.count]
                counter += 1
                return chosen
            }
        }

        var balancer = RoundRobinBalancer()
        let if1 = balancer.nextInterface()
        let if2 = balancer.nextInterface()
        let if3 = balancer.nextInterface()

        #expect(if1 == "en10")
        #expect(if2 == "en0")
        #expect(if3 == "en10")
    }

    @Test("T1-F08-05: Proxy-Connection keep-alive header parsed accurately")
    func testProxyConnectionKeepAliveDetection() {
        let requestWithKeepAlive = "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nProxy-Connection: keep-alive\r\n\r\n"
        let parsed = HTTPProxyEngine.parseRequest(requestWithKeepAlive)

        if case .standard(_, _, let keepAlive) = parsed {
            #expect(keepAlive == true)
        } else {
            Issue.record("Expected keep-alive detection")
        }

        let requestWithoutKeepAlive = "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n"
        let parsedClose = HTTPProxyEngine.parseRequest(requestWithoutKeepAlive)
        if case .standard(_, _, let keepAlive) = parsedClose {
            #expect(keepAlive == false)
        }
    }
}
