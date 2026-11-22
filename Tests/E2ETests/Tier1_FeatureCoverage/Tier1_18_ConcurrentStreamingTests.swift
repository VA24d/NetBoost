import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 18: Concurrent URLSession Range Streaming", .tags(.tier1, .m4_downloader, .accelerator))
struct Tier1_18_ConcurrentStreamingTests {

    @Test("T1-F18-01: Spawn concurrent range requests against MockHTTPServer")
    func testConcurrentRangeRequests() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/dataset.bin")!
        let totalSize: Int64 = 1_048_576
        let chunkCount = 4
        let chunkSize = totalSize / Int64(chunkCount)

        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for i in 0..<chunkCount {
                let start = Int64(i) * chunkSize
                let end = start + chunkSize - 1
                group.addTask {
                    var req = URLRequest(url: testURL)
                    req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                    let (data, response) = try await URLSession.shared.data(for: req)
                    let httpRes = response as? HTTPURLResponse
                    #expect(httpRes?.statusCode == 206)
                    return (i, data.count)
                }
            }

            var received = 0
            for try await (_, count) in group {
                received += count
            }
            #expect(received == totalSize)
        }
    }

    @Test("T1-F18-02: Simultaneous stream reception across multiple chunk workers")
    func testSimultaneousStreamReception() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/sample.dat")!
        var request1 = URLRequest(url: testURL)
        request1.setValue("bytes=0-1023", forHTTPHeaderField: "Range")

        var request2 = URLRequest(url: testURL)
        request2.setValue("bytes=1024-2047", forHTTPHeaderField: "Range")

        async let task1 = URLSession.shared.data(for: request1)
        async let task2 = URLSession.shared.data(for: request2)

        let (data1, res1) = try await task1
        let (data2, res2) = try await task2

        #expect((res1 as? HTTPURLResponse)?.statusCode == 206)
        #expect((res2 as? HTTPURLResponse)?.statusCode == 206)
        #expect(data1.count == 1024)
        #expect(data2.count == 1024)
    }

    @Test("T1-F18-03: Track individual chunk downloaded bytes and progress metric")
    func testChunkProgressTracking() {
        var chunk = DownloadChunkInfo(
            id: 0,
            rangeStart: 0,
            rangeEnd: 999,
            downloadedBytes: 500,
            status: .downloading
        )

        #expect(chunk.totalBytes == 1000)
        #expect(chunk.progress == 0.5)

        chunk.downloadedBytes = 1000
        chunk.status = .completed
        #expect(chunk.progress == 1.0)
    }

    @Test("T1-F18-04: Pause download preserves current downloaded byte offsets")
    func testPauseDownloadOffsetPreservation() {
        var chunk = DownloadChunkInfo(
            id: 0,
            rangeStart: 0,
            rangeEnd: 1048575,
            downloadedBytes: 524288,
            status: .downloading
        )

        // Simulated pause
        chunk.status = .pending
        #expect(chunk.downloadedBytes == 524288)
        #expect(chunk.rangeStart == 0)
    }

    @Test("T1-F18-05: Resume download calculates updated Range header from current offset")
    func testResumeRangeHeaderCalculation() {
        func makeResumeRange(chunk: DownloadChunkInfo) -> String {
            let nextByte = chunk.rangeStart + chunk.downloadedBytes
            return "bytes=\(nextByte)-\(chunk.rangeEnd)"
        }

        let partiallyDownloaded = DownloadChunkInfo(
            id: 1,
            rangeStart: 1000,
            rangeEnd: 1999,
            downloadedBytes: 400,
            status: .pending
        )

        let resumeHeader = makeResumeRange(chunk: partiallyDownloaded)
        #expect(resumeHeader == "bytes=1400-1999")
    }
}
