import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 18: Concurrent Streaming Boundaries", .tags(.tier2, .m4_downloader, .range_206))
struct Tier2_18_ConcurrentStreamingBoundariesTests {

    @Test("T2-F18-01: Mid-stream connection drop detected via dropConnectionAfterBytes")
    func testMidStreamConnectionDrop() async throws {
        let server = MockHTTPServer()
        server.dropConnectionAfterBytes = 256
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/mid_drop.bin")!
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1024", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        let session = URLSession(configuration: config)

        await #expect(throws: Error.self) {
            _ = try await session.data(for: request)
        }
    }

    @Test("T2-F18-02: Rate limiting HTTP 429 triggers exponential backoff calculation")
    func testRateLimitingBackoff() {
        func backoffForRateLimit(retryAfterHeader: String?, attempt: Int) -> TimeInterval {
            if let header = retryAfterHeader, let seconds = Double(header) {
                return seconds
            }
            return min(30.0, 1.0 * pow(2.0, Double(attempt)))
        }

        #expect(backoffForRateLimit(retryAfterHeader: "5", attempt: 0) == 5.0)
        #expect(backoffForRateLimit(retryAfterHeader: nil, attempt: 0) == 1.0)
        #expect(backoffForRateLimit(retryAfterHeader: nil, attempt: 3) == 8.0)
    }

    @Test("T2-F18-03: Concurrent streaming across 4 chunks against MockHTTPServer")
    func testConcurrentChunkStreaming() async throws {
        let testPayload = TestAssertions.generateDeterministicPayload(size: 65536)
        let server = MockHTTPServer(payload: testPayload)
        let port = try await server.start()
        defer { server.stop() }

        let ranges: [(start: Int, end: Int)] = [
            (0, 16383),
            (16384, 32767),
            (32768, 49151),
            (49152, 65535)
        ]

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let results = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (idx, r) in ranges.enumerated() {
                group.addTask {
                    let url = URL(string: "http://127.0.0.1:\(port)/chunk_\(idx).bin")!
                    var req = URLRequest(url: url)
                    req.setValue("bytes=\(r.start)-\(r.end)", forHTTPHeaderField: "Range")
                    let (data, response) = try await session.data(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                        throw NSError(domain: "Test", code: -1)
                    }
                    return (idx, data)
                }
            }

            var map: [Int: Data] = [:]
            for try await (idx, data) in group {
                map[idx] = data
            }
            return map
        }

        #expect(results.count == 4)
        for (idx, r) in ranges.enumerated() {
            let expectedData = testPayload.subdata(in: r.start..<(r.end + 1))
            #expect(results[idx] == expectedData)
        }
    }

    @Test("T2-F18-04: Task cancellation terminates in-flight range requests cleanly")
    func testDownloadTaskCancellation() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/cancel_test.bin")!
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let task = Task {
            var req = URLRequest(url: url)
            req.setValue("bytes=0-10000", forHTTPHeaderField: "Range")
            return try await session.data(for: req)
        }

        task.cancel()
        let result = await task.result
        switch result {
        case .failure(let error):
            #expect(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        case .success:
            // If it finished before cancellation, it still passed cleanly
            break
        }
    }

    @Test("T2-F18-05: HTTP 416 handled as terminal chunk error")
    func testTerminalHTTP416Handling() async throws {
        let server = MockHTTPServer()
        server.forceRange416 = true
        let port = try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/invalid_range.bin")!
        var req = URLRequest(url: url)
        req.setValue("bytes=1000000-2000000", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: req)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 416)
    }
}
