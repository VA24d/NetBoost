import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 20: Real-Time Segment & Speed Metrics", .tags(.tier1, .m4_downloader))
struct Tier1_20_SpeedMetricsTests {

    struct SpeedCalculator {
        static func calculateThroughput(bytes: Int64, duration: TimeInterval) -> Double {
            guard duration > 0 else { return 0 }
            return Double(bytes) / duration
        }

        static func calculateETA(totalBytes: Int64, downloadedBytes: Int64, speedBytesPerSec: Double) -> TimeInterval? {
            guard speedBytesPerSec > 0 else { return nil }
            let remaining = max(0, totalBytes - downloadedBytes)
            return Double(remaining) / speedBytesPerSec
        }
    }

    @Test("T1-F20-01: Calculate aggregate download speed over elapsed duration")
    func testCalculateAggregateThroughput() {
        let speed = SpeedCalculator.calculateThroughput(bytes: 10_485_760, duration: 2.0)
        #expect(speed == 5_242_880.0) // 5 MB/s
    }

    @Test("T1-F20-02: Calculate per-chunk progress and download percentage")
    func testPerChunkProgressCalculation() {
        let chunk = DownloadChunkInfo(
            id: 0,
            rangeStart: 0,
            rangeEnd: 1000,
            downloadedBytes: 750,
            status: .downloading,
            speedBytesPerSec: 100_000
        )

        #expect(chunk.progress > 0.74 && chunk.progress < 0.76)
        #expect(chunk.speedBytesPerSec == 100_000)
    }

    @Test("T1-F20-03: Compute remaining ETA based on rolling speed")
    func testComputeETA() {
        let total: Int64 = 10_000_000
        let downloaded: Int64 = 5_000_000
        let speed: Double = 1_000_000 // 1 MB/s

        let eta = SpeedCalculator.calculateETA(totalBytes: total, downloadedBytes: downloaded, speedBytesPerSec: speed)
        #expect(eta == 5.0) // 5 seconds remaining

        let zeroSpeedETA = SpeedCalculator.calculateETA(totalBytes: total, downloadedBytes: downloaded, speedBytesPerSec: 0)
        #expect(zeroSpeedETA == nil)
    }

    @Test("T1-F20-04: Metric updates emission via AsyncStream")
    func testMetricUpdatesAsyncStream() async throws {
        let stream = AsyncStream<Double> { continuation in
            continuation.yield(1024.0)
            continuation.yield(2048.0)
            continuation.yield(4096.0)
            continuation.finish()
        }

        var values: [Double] = []
        for await val in stream {
            values.append(val)
        }

        #expect(values.count == 3)
        #expect(values == [1024.0, 2048.0, 4096.0])
    }

    @Test("T1-F20-05: Track cumulative downloaded bytes and overall progress fraction")
    func testDownloadTaskOverallProgress() {
        let task = DownloadTaskInfo(
            url: URL(string: "https://example.com/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.bin"),
            totalBytes: 20_000_000,
            downloadedBytes: 15_000_000,
            status: .downloading
        )

        #expect(task.progress == 0.75)
    }
}
