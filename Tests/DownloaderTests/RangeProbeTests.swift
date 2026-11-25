import Testing
import Foundation
@testable import NetBoostCore

@Suite("Downloader: RangeProbe Unit & Integration Tests", .tags(.tier1, .m4_downloader, .range_206))
struct RangeProbeTests {

    @Test("HEAD probe parses Content-Length, Accept-Ranges, and suggested chunks")
    func testHeadProbeRangeSupported() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/largefile.iso")!
        let result = try await RangeProbe.probe(url: testURL)

        #expect(result.supportsRanges == true)
        #expect(result.contentLength == 1_048_576)
        #expect(result.suggestedChunkCount == 8)
        #expect(result.filename == "largefile.iso")
    }

    @Test("Fallback when server simulates non-range support")
    func testProbeNonRangeFallback() async throws {
        let server = MockHTTPServer()
        server.simulateNonRangeSupport = true
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/stream.bin")!
        let result = try await RangeProbe.probe(url: testURL)

        #expect(result.supportsRanges == false)
        #expect(result.suggestedChunkCount == 1)
        #expect(result.contentLength == 1_048_576)
    }

    @Test("Filename extraction parses Content-Disposition with quotes and parameters")
    func testFilenameExtraction() {
        let cd1 = "attachment; filename=\"ubuntu-24.04-desktop.iso\"; size=1234"
        let fallbackURL1 = URL(string: "https://example.com/downloads/ubuntu")!
        let extracted1 = RangeProbe.parseFilename(from: cd1, fallbackURL: fallbackURL1)
        #expect(extracted1 == "ubuntu-24.04-desktop.iso")

        let cd2 = "inline; filename=data_archive.tar.gz"
        let fallbackURL2 = URL(string: "https://example.com/data")!
        let extracted2 = RangeProbe.parseFilename(from: cd2, fallbackURL: fallbackURL2)
        #expect(extracted2 == "data_archive.tar.gz")

        let fallbackURL3 = URL(string: "https://example.com/releases/tool.dmg")!
        let extracted3 = RangeProbe.parseFilename(from: nil, fallbackURL: fallbackURL3)
        #expect(extracted3 == "tool.dmg")

        let emptyURL = URL(string: "https://example.com/")!
        let extracted4 = RangeProbe.parseFilename(from: nil, fallbackURL: emptyURL)
        #expect(extracted4 == "download.bin")
    }

    @Test("Calculate suggested chunk counts accurately")
    func testSuggestedChunkCountCalculations() {
        // Small file (<1MB) -> 1 chunk
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 500_000, supportsRanges: true) == 1)
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 1_048_575, supportsRanges: true) == 1)

        // Medium file (1MB..100MB) -> 8 chunks
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 1_048_576, supportsRanges: true) == 8)
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 50_000_000, supportsRanges: true) == 8)
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 104_857_600, supportsRanges: true) == 8)

        // Large file (>100MB) -> 16 chunks
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 104_857_601, supportsRanges: true) == 16)
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 1_000_000_000, supportsRanges: true) == 16)

        // When ranges are not supported, always 1 chunk regardless of size
        #expect(RangeProbe.calculateSuggestedChunkCount(fileSize: 500_000_000, supportsRanges: false) == 1)
    }

    @Test("Zero-byte file probe returns contentLength 0")
    func testZeroByteProbe() async throws {
        let server = MockHTTPServer(payload: Data())
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/empty.bin")!
        let result = try await RangeProbe.probe(url: testURL)

        #expect(result.contentLength == 0)
        #expect(result.suggestedChunkCount == 1)
    }

    @Test("Fault injection: server 500 error throws URLError")
    func testFaultInjection500() async throws {
        let server = MockHTTPServer()
        server.force500Error = true
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/fault500.bin")!
        await #expect(throws: Error.self) {
            _ = try await RangeProbe.probe(url: testURL)
        }
    }

    @Test("Fault injection: dropped connection throws network error")
    func testFaultInjectionDroppedConnection() async throws {
        let server = MockHTTPServer()
        server.dropConnectionImmediately = true
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/drop.bin")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        let session = URLSession(configuration: config)

        await #expect(throws: Error.self) {
            _ = try await RangeProbe.probe(url: testURL, session: session)
        }
    }

    @Test("Filename parser sanitizes path traversal, control characters, and supports RFC 5987 filename*")
    func testFilenameSanitizationAndUTF8Star() {
        let fallback = URL(string: "https://example.com/files/archive.zip")!

        let traversal1 = RangeProbe.parseFilename(from: "attachment; filename=\"../../etc/passwd\"", fallbackURL: fallback)
        #expect(traversal1 == "passwd")

        let traversal2 = RangeProbe.parseFilename(from: "attachment; filename=\"..\\\\..\\\\evil.sh\"", fallbackURL: fallback)
        #expect(traversal2 == "evil.sh")

        let dotDotOnly = RangeProbe.parseFilename(from: "attachment; filename=\"..\"", fallbackURL: fallback)
        #expect(dotDotOnly == "archive.zip")

        let controlChars = RangeProbe.parseFilename(from: "attachment; filename=\"bad\0\n\rname.bin\"", fallbackURL: fallback)
        #expect(controlChars == "badname.bin")

        let rfc5987 = RangeProbe.parseFilename(
            from: "attachment; filename=\"fallback.iso\"; filename*=UTF-8''campus%20dataset%20v2.iso",
            fallbackURL: fallback
        )
        #expect(rfc5987 == "campus dataset v2.iso")

        let rfc5987Traversal = RangeProbe.parseFilename(
            from: "attachment; filename*=UTF-8''..%2F..%2Fsecret.tar.gz",
            fallbackURL: fallback
        )
        #expect(rfc5987Traversal == "secret.tar.gz")
    }

    @Test("HTTP 500 throws clean RangeProbeError.httpError(statusCode: 500)")
    func testHTTP500ThrowsRangeProbeError() async throws {
        let server = MockHTTPServer()
        server.force500Error = true
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/err500.bin")!
        do {
            _ = try await RangeProbe.probe(url: testURL)
            Issue.record("Expected RangeProbeError.httpError")
        } catch let error as RangeProbeError {
            #expect(error == .httpError(statusCode: 500))
        }
    }
}
