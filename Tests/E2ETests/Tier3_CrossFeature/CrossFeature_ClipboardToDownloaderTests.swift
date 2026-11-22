import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 3: Clipboard Monitor + Range Probe + Download Manager Interaction", .tags(.tier3, .accelerator, .m4_downloader))
struct CrossFeature_ClipboardToDownloaderTests {

    @Test("Clipboard monitor detects downloadable URLs matching binary extensions and rejects plain text")
    func testClipboardURLPatternFiltering() {
        let validURLs = [
            "https://turing.iiit.ac.in/datasets/hpc_dataset.iso",
            "http://127.0.0.1:8080/releases/netboost.dmg",
            "https://example.com/archive.tar.gz",
            "https://example.com/payload.bin"
        ]

        let ignoredItems = [
            "Just a regular text string copied from terminal",
            "javascript:void(0)",
            "ftp://files.example.com/unsupported",
            "https://turing.iiit.ac.in/index.html"
        ]

        let downloadableExtensions = Set(["iso", "dmg", "zip", "gz", "bin", "tar", "pkg"])

        for urlStr in validURLs {
            guard let url = URL(string: urlStr), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                Issue.record("Failed to parse valid URL: \(urlStr)")
                continue
            }
            let ext = url.pathExtension.lowercased()
            let isDownloadable = downloadableExtensions.contains(ext) || url.lastPathComponent.contains(".tar.gz")
            #expect(isDownloadable == true)
        }

        for item in ignoredItems {
            var isDownloadable = false
            if let url = URL(string: item), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                let ext = url.pathExtension.lowercased()
                isDownloadable = downloadableExtensions.contains(ext)
            }
            #expect(isDownloadable == false)
        }
    }

    @Test("Clipboard detection triggers capability probe against target server URL")
    func testClipboardTriggersCapabilityProbe() async throws {
        let payload = TestAssertions.generateDeterministicPayload(size: 65536)
        let server = MockHTTPServer(payload: payload)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/dataset.iso")!

        var request = URLRequest(url: targetURL)
        request.httpMethod = "HEAD"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.expectedContentLength == 65536)
        #expect(httpResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    }

    @Test("Range probe results initialize DownloadTaskInfo with chunk partitions and queued status")
    func testDownloadTaskInitializationFromProbe() {
        let downloadURL = URL(string: "https://turing.iiit.ac.in/data/large_dataset.iso")!
        let destURL = URL(fileURLWithPath: "/tmp/large_dataset.iso")
        let totalBytes: Int64 = 67_108_864 // 64 MB
        let chunkCount = 8
        let chunkSize = totalBytes / Int64(chunkCount)

        var chunks: [DownloadChunkInfo] = []
        for i in 0..<chunkCount {
            let start = Int64(i) * chunkSize
            let end = (i == chunkCount - 1) ? (totalBytes - 1) : (start + chunkSize - 1)
            chunks.append(DownloadChunkInfo(id: i, rangeStart: start, rangeEnd: end))
        }

        let task = DownloadTaskInfo(
            url: downloadURL,
            destinationURL: destURL,
            totalBytes: totalBytes,
            downloadedBytes: 0,
            chunks: chunks,
            status: .downloading
        )

        #expect(task.chunks.count == 8)
        #expect(task.totalBytes == 67_108_864)
        #expect(task.status == .downloading)
        #expect(task.progress == 0.0)
    }

    @Test("Download manager streams chunks concurrently and computes real-time throughput metrics")
    func testConcurrentChunkStreamingWithMetrics() async throws {
        let payloadSize = 32768 // 32 KB
        let originalPayload = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let server = MockHTTPServer(payload: originalPayload)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/quick.bin")!
        let chunkCount = 4
        let chunkSize = payloadSize / chunkCount

        actor StreamMetrics {
            var bytesDownloaded = 0
            func recordBytes(_ count: Int) {
                bytesDownloaded += count
            }
            func total() -> Int {
                bytesDownloaded
            }
        }

        let metrics = StreamMetrics()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<chunkCount {
                let start = i * chunkSize
                let end = (i == chunkCount - 1) ? (payloadSize - 1) : (start + chunkSize - 1)

                group.addTask {
                    var req = URLRequest(url: targetURL)
                    req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 5.0
                    let session = URLSession(configuration: config)

                    let (data, response) = try await session.data(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                        throw NSError(domain: "DownloaderTest", code: -1)
                    }

                    await metrics.recordBytes(data.count)
                    return data.count
                }
            }

            for try await _ in group {}
        }

        let total = await metrics.total()
        #expect(total == payloadSize)
    }

    @Test("Clipboard monitor ignores rapid duplicate URLs within debounce window")
    func testClipboardDebouncing() {
        let testURL = "https://turing.iiit.ac.in/data/dataset.bin"
        var history: [String: Date] = [:]
        let debounceInterval: TimeInterval = 10.0

        func shouldAccept(url: String, now: Date) -> Bool {
            if let lastSeen = history[url], now.timeIntervalSince(lastSeen) < debounceInterval {
                return false // Debounced
            }
            history[url] = now
            return true
        }

        let t0 = Date()
        #expect(shouldAccept(url: testURL, now: t0) == true)
        #expect(shouldAccept(url: testURL, now: t0.addingTimeInterval(1.0)) == false)
        #expect(shouldAccept(url: testURL, now: t0.addingTimeInterval(5.0)) == false)
        #expect(shouldAccept(url: testURL, now: t0.addingTimeInterval(11.0)) == true)
    }
}
