import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 16: Range Capability Probe Boundaries", .tags(.tier2, .m4_downloader, .range_206))
struct Tier2_16_RangeProbeBoundariesTests {

    @Test("T2-F16-01: Server with Range support disabled returns full 200 OK without Accept-Ranges bytes")
    func testRangeUnsupportedFallback() async throws {
        let server = MockHTTPServer()
        server.simulateNonRangeSupport = true
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/no_range.bin")!
        var request = URLRequest(url: url)
        request.setValue("bytes=0-100", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200) // Returns full 200 instead of 206
    }

    @Test("T2-F16-02: Fault injection: HTTP 416 Range Not Satisfiable handled cleanly")
    func testFaultInjection416() async throws {
        let server = MockHTTPServer()
        server.forceRange416 = true
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/fault416.bin")!
        var request = URLRequest(url: url)
        request.setValue("bytes=9999999-99999999", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 416)
    }

    @Test("T2-F16-03: Fault injection: HTTP 500 Internal Server Error handled cleanly")
    func testFaultInjection500() async throws {
        let server = MockHTTPServer()
        server.force500Error = true
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/fault500.bin")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 500)
    }

    @Test("T2-F16-04: Zero-byte file probe returns Content-Length 0")
    func testZeroByteFileProbe() async throws {
        let server = MockHTTPServer(payload: Data())
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/empty.bin")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.expectedContentLength == 0)
    }

    @Test("T2-F16-05: Dropped connection immediately throws network error in client session")
    func testDroppedConnectionFaultInjection() async throws {
        let server = MockHTTPServer()
        server.dropConnectionImmediately = true
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/drop.bin")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        let session = URLSession(configuration: config)

        await #expect(throws: Error.self) {
            _ = try await session.data(from: url)
        }
    }
}
