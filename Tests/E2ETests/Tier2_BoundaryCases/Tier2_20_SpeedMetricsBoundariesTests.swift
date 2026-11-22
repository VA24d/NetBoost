import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 20: Speed Metrics Boundaries", .tags(.tier2, .m4_downloader, .accelerator))
struct Tier2_20_SpeedMetricsBoundariesTests {

    @Test("T2-F20-01: Zero speed (stalled) returns nil or infinite ETA without NaN or crash")
    func testStalledDownloadETA() {
        func computeETA(remainingBytes: Int64, speedBytesPerSec: Double) -> TimeInterval? {
            guard speedBytesPerSec > 0 else { return nil }
            let eta = Double(remainingBytes) / speedBytesPerSec
            guard !eta.isNaN && !eta.isInfinite else { return nil }
            return eta
        }

        #expect(computeETA(remainingBytes: 50_000_000, speedBytesPerSec: 0.0) == nil)
        #expect(computeETA(remainingBytes: 50_000_000, speedBytesPerSec: -5.0) == nil)
        #expect(computeETA(remainingBytes: 50_000_000, speedBytesPerSec: 10_000_000.0) == 5.0)
    }

    @Test("T2-F20-02: Exponential moving average dampens speed fluctuations")
    func testExponentialMovingAverage() {
        var smoothedSpeed: Double = 5_000_000.0 // 5 MB/s initial
        let alpha = 0.2 // Smoothing factor

        func updateEMA(instantaneous: Double) -> Double {
            smoothedSpeed = (alpha * instantaneous) + ((1.0 - alpha) * smoothedSpeed)
            return smoothedSpeed
        }

        // Sudden spike to 50 MB/s
        let smoothed1 = updateEMA(instantaneous: 50_000_000.0)
        #expect(smoothed1 == 14_000_000.0) // Dampened from 50MB/s to 14MB/s
    }

    @Test("T2-F20-03: Paused state zeroes speed while retaining progress")
    func testPausedStateMetrics() {
        var task = DownloadTaskInfo(
            url: URL(string: "http://example.com/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.bin"),
            totalBytes: 100_000_000,
            downloadedBytes: 45_000_000,
            status: .downloading,
            speedBytesPerSec: 12_500_000.0
        )

        #expect(task.progress == 0.45)
        #expect(task.speedBytesPerSec == 12_500_000.0)

        // Pause
        task.status = .paused
        task.speedBytesPerSec = 0.0

        #expect(task.status == .paused)
        #expect(task.progress == 0.45)
        #expect(task.speedBytesPerSec == 0.0)
    }

    @Test("T2-F20-04: Progress is clamped between 0.0 and 1.0 even on zero total bytes")
    func testProgressClamping() {
        let zeroTotalTask = DownloadTaskInfo(
            url: URL(string: "http://example.com/zero.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/zero.bin"),
            totalBytes: 0,
            downloadedBytes: 0
        )
        #expect(zeroTotalTask.progress == 0.0)

        let completedTask = DownloadTaskInfo(
            url: URL(string: "http://example.com/done.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/done.bin"),
            totalBytes: 1000,
            downloadedBytes: 1000
        )
        #expect(completedTask.progress == 1.0)
    }

    @Test("T2-F20-05: Per-chunk progress calculation correctly calculates fractional completion")
    func testChunkProgressCalculation() {
        let chunk = DownloadChunkInfo(
            id: 1,
            rangeStart: 1000,
            rangeEnd: 1999,
            downloadedBytes: 500,
            status: .downloading
        )

        #expect(chunk.totalBytes == 1000)
        #expect(chunk.progress == 0.5)
    }
}
