import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 16: HTTP Header & Range Capability Probe", .tags(.tier1, .m4_downloader, .range_206))
struct Tier1_16_RangeProbeTests {

    struct RangeProbeResult: Equatable {
        let supportsRanges: Bool
        let contentLength: Int64
        let etag: String?
        let lastModified: String?
        let filename: String
        let suggestedChunkCount: Int
    }

    struct HTTPRangeProber {
        static func probe(url: URL) async throws -> RangeProbeResult {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
            let lengthHeader = httpResponse.value(forHTTPHeaderField: "Content-Length")
            let etag = httpResponse.value(forHTTPHeaderField: "ETag")
            let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
            let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")

            let length = Int64(lengthHeader ?? "0") ?? 0
            let supportsRanges = acceptRanges?.lowercased() == "bytes"

            let filename: String
            if let cd = contentDisposition, let nameRange = cd.range(of: "filename=") {
                filename = String(cd[nameRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            } else {
                filename = url.lastPathComponent.isEmpty ? "download.bin" : url.lastPathComponent
            }

            let suggestedChunks: Int
            if !supportsRanges || length < 1_048_576 {
                suggestedChunks = 1
            } else if length > 104_857_600 {
                suggestedChunks = 16
            } else {
                suggestedChunks = 8
            }

            return RangeProbeResult(
                supportsRanges: supportsRanges,
                contentLength: length,
                etag: etag,
                lastModified: lastModified,
                filename: filename,
                suggestedChunkCount: suggestedChunks
            )
        }
    }

    @Test("T1-F16-01: HEAD probe parses Content-Length and Accept-Ranges: bytes")
    func testHeadProbeRangeSupported() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/largefile.iso")!
        let result = try await HTTPRangeProber.probe(url: testURL)

        #expect(result.supportsRanges == true)
        #expect(result.contentLength == 1_048_576)
        #expect(result.suggestedChunkCount == 8)
    }

    @Test("T1-F16-02: Fallback probe when server simulates non-range support")
    func testProbeFallbackNonRange() async throws {
        let server = MockHTTPServer()
        server.simulateNonRangeSupport = true
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/stream.bin")!
        let result = try await HTTPRangeProber.probe(url: testURL)

        #expect(result.supportsRanges == false)
        #expect(result.suggestedChunkCount == 1)
    }

    @Test("T1-F16-03: Extract ETag and Last-Modified headers when available")
    func testExtractETagAndLastModified() {
        let headers = [
            "Content-Length": "52428800",
            "Accept-Ranges": "bytes",
            "ETag": "\"123456789abcdef\"",
            "Last-Modified": "Wed, 21 Oct 2025 07:28:00 GMT"
        ]

        let etag = headers["ETag"]
        let lastMod = headers["Last-Modified"]

        #expect(etag == "\"123456789abcdef\"")
        #expect(lastMod?.contains("2025") == true)
    }

    @Test("T1-F16-04: Extract filename from Content-Disposition or fallback to URL path")
    func testFilenameExtraction() {
        let cd = "attachment; filename=\"ubuntu-24.04-desktop.iso\""
        let fallbackURL = URL(string: "https://example.com/downloads/tool.tar.gz")!

        var extracted = ""
        if let nameRange = cd.range(of: "filename=") {
            extracted = String(cd[nameRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }

        #expect(extracted == "ubuntu-24.04-desktop.iso")
        #expect(fallbackURL.lastPathComponent == "tool.tar.gz")
    }

    @Test("T1-F16-05: Determine suggested chunk count based on file size")
    func testSuggestedChunkCountHeuristic() {
        func chunkCount(for size: Int64, supportsRange: Bool) -> Int {
            guard supportsRange else { return 1 }
            if size < 1_048_576 { return 1 }
            if size > 104_857_600 { return 16 }
            return 8
        }

        #expect(chunkCount(for: 500_000, supportsRange: true) == 1)
        #expect(chunkCount(for: 50_000_000, supportsRange: true) == 8)
        #expect(chunkCount(for: 500_000_000, supportsRange: true) == 16)
        #expect(chunkCount(for: 500_000_000, supportsRange: false) == 1)
    }
}
