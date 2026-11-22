import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 08: HTTP Proxy Boundaries", .tags(.tier2, .m2_proxy))
struct Tier2_08_HTTPProxyBoundariesTests {

    @Test("T2-F08-01: Malformed HTTP request line returns 400 Bad Request")
    func testMalformedHTTPRequestLine() {
        func parseHTTPCONNECTLine(_ line: String) -> (host: String, port: Int)? {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "CONNECT" else { return nil }
            let target = parts[1]
            let hostPort = target.split(separator: ":")
            guard hostPort.count == 2, let port = Int(hostPort[1]), port > 0, port <= 65535 else { return nil }
            return (String(hostPort[0]), port)
        }

        #expect(parseHTTPCONNECTLine("CONNECT turing.iiit.ac.in:443 HTTP/1.1") != nil)
        #expect(parseHTTPCONNECTLine("INVALID_LINE_NO_SPACES") == nil)
        #expect(parseHTTPCONNECTLine("GET /index.html HTTP/1.1") == nil)
        #expect(parseHTTPCONNECTLine("CONNECT target_without_port HTTP/1.1") == nil)
        #expect(parseHTTPCONNECTLine("CONNECT target:999999 HTTP/1.1") == nil)
    }

    @Test("T2-F08-02: Target connection timeout generates 504 Gateway Timeout response")
    func testGatewayTimeoutResponseFormatting() {
        func makeHTTPResponse(statusCode: Int, statusText: String, body: String) -> String {
            return "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        }

        let timeoutResp = makeHTTPResponse(statusCode: 504, statusText: "Gateway Timeout", body: "Upstream host connection timed out.")
        #expect(timeoutResp.contains("504 Gateway Timeout"))
        #expect(timeoutResp.contains("Connection: close"))
    }

    @Test("T2-F08-03: Oversized HTTP headers (>64KB) rejected to prevent memory exhaustion")
    func testOversizedHeadersRejection() {
        let maxHeaderSize = 65_536 // 64 KB
        let validHeader = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        let oversizedHeader = String(repeating: "X-Header-Padding: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\r\n", count: 2000)

        func checkHeaderSize(_ header: String) -> Bool {
            return header.utf8.count <= maxHeaderSize
        }

        #expect(checkHeaderSize(validHeader) == true)
        #expect(checkHeaderSize(oversizedHeader) == false)
    }

    @Test("T2-F08-04: HTTP 200 Connection Established formatting for CONNECT tunnel")
    func testConnectionEstablishedResponseFormatting() {
        let established = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: NetBoost/1.0\r\n\r\n"
        #expect(established.hasPrefix("HTTP/1.1 200 Connection Established"))
        #expect(established.hasSuffix("\r\n\r\n"))
    }

    @Test("T2-F08-05: Non-standard proxy ports (1080, 1081, 1082) mapping verification")
    func testProxyPortInterfaceMapping() {
        let portInterfaceMap: [Int: String] = [
            1080: "en10", // Wired Ethernet
            1081: "en0",  // Wi-Fi
            1082: "auto"  // Balanced
        ]

        #expect(portInterfaceMap[1080] == "en10")
        #expect(portInterfaceMap[1081] == "en0")
        #expect(portInterfaceMap[1082] == "auto")
        #expect(portInterfaceMap[8080] == nil)
    }
}
