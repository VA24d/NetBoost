import Testing
import Foundation
@testable import NetBoostCore

@Suite("Downloader: DownloadManager Integration Tests", .tags(.tier1, .m4_downloader, .accelerator))
struct DownloadManagerTests {

    private func makeTemporaryFileURL(name: String = "assembled.bin") -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("netboost-dm-\(UUID().uuidString)-\(name)")
    }

    @Test("Full end-to-end 8-chunk accelerated download with bit-exact SHA-256 verification")
    func testFullAcceleratedDownloadPipeline() async throws {
        let payloadSize = 1_048_576 // 1 MB (triggers 8-chunk partition)
        let originalPayload = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let expectedSHA256 = TestAssertions.sha256Hex(of: originalPayload)

        let server = MockHTTPServer(payload: originalPayload)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/dataset.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let manager = DownloadManager()

        let taskInfo = try await manager.downloadAndWait(
            url: targetURL,
            destination: destURL,
            chunksCount: 8,
            expectedChecksum: expectedSHA256,
            timeout: 10.0
        )

        #expect(taskInfo.status == .completed)
        #expect(taskInfo.downloadedBytes == Int64(payloadSize))
        #expect(taskInfo.totalBytes == Int64(payloadSize))
        #expect(taskInfo.chunks.count == 8)

        let downloadedData = try Data(contentsOf: destURL)
        #expect(downloadedData == originalPayload)

        let computedSHA256 = TestAssertions.sha256Hex(of: downloadedData)
        #expect(computedSHA256 == expectedSHA256)
    }

    @Test("Single stream fallback when server does not support ranges")
    func testSingleStreamFallback() async throws {
        let payloadSize = 65536
        let originalPayload = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let expectedSHA256 = TestAssertions.sha256Hex(of: originalPayload)

        let server = MockHTTPServer(payload: originalPayload)
        server.simulateNonRangeSupport = true
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/stream.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let manager = DownloadManager()

        let taskInfo = try await manager.downloadAndWait(
            url: targetURL,
            destination: destURL,
            chunksCount: 8,
            expectedChecksum: expectedSHA256,
            timeout: 10.0
        )

        #expect(taskInfo.status == .completed)
        #expect(taskInfo.chunks.count == 1) // Forced to 1 chunk fallback
        #expect(taskInfo.downloadedBytes == Int64(payloadSize))

        let downloadedData = try Data(contentsOf: destURL)
        #expect(downloadedData == originalPayload)
    }

    @Test("Pause and resume download preserves progress and completes to 100% integrity")
    func testPauseAndResumeDownload() async throws {
        let payloadSize = 262_144 // 256 KB
        let originalPayload = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let expectedSHA256 = TestAssertions.sha256Hex(of: originalPayload)

        let server = MockHTTPServer(payload: originalPayload)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/resumable.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let manager = DownloadManager()

        let initialTask = try await manager.startDownload(
            url: targetURL,
            destination: destURL,
            chunksCount: 4,
            expectedChecksum: expectedSHA256
        )

        // Pause download
        try await manager.pauseDownload(id: initialTask.id)
        let pausedTask = manager.getTask(id: initialTask.id)
        #expect(pausedTask?.status == .paused)
        #expect(pausedTask?.speedBytesPerSec == 0.0)

        // Resume download
        try await manager.resumeDownload(id: initialTask.id)
        let completedTask = try await manager.waitUntilCompleted(id: initialTask.id, timeout: 10.0)

        #expect(completedTask.status == .completed)
        #expect(completedTask.downloadedBytes == Int64(payloadSize))

        let assembledData = try Data(contentsOf: destURL)
        #expect(assembledData == originalPayload)
        #expect(TestAssertions.sha256Hex(of: assembledData) == expectedSHA256)
    }

    @Test("Cancel download terminates active task")
    func testCancelDownloadLifecycle() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/cancel.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let manager = DownloadManager()

        let initialTask = try await manager.startDownload(
            url: targetURL,
            destination: destURL,
            chunksCount: 4
        )

        try await manager.cancelDownload(id: initialTask.id)
        let cancelledTask = manager.getTask(id: initialTask.id)
        #expect(cancelledTask?.status == .cancelled)
    }

    @Test("Checksum verification mismatch marks task as failed")
    func testChecksumMismatchFailure() async throws {
        let payloadSize = 32768
        let originalPayload = TestAssertions.generateDeterministicPayload(size: payloadSize)

        let server = MockHTTPServer(payload: originalPayload)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/corrupt.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let manager = DownloadManager()
        let wrongChecksum = "0000000000000000000000000000000000000000000000000000000000000000"

        await #expect(throws: Error.self) {
            _ = try await manager.downloadAndWait(
                url: targetURL,
                destination: destURL,
                chunksCount: 4,
                expectedChecksum: wrongChecksum,
                timeout: 5.0
            )
        }

        let failedTask = manager.getAllTasks().first
        #expect(failedTask?.status == .failed)
    }

    @Test("Zero-byte file download completes immediately")
    func testZeroByteDownloadCompletion() async throws {
        let server = MockHTTPServer(payload: Data())
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/empty.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let manager = DownloadManager()
        let taskInfo = try await manager.downloadAndWait(
            url: targetURL,
            destination: destURL,
            timeout: 5.0
        )

        #expect(taskInfo.status == .completed)
        #expect(taskInfo.totalBytes == 0)
        #expect(taskInfo.downloadedBytes == 0)
    }

    @Test("TaskPublisher emits progress updates through lifecycle")
    func testTaskPublisherLifecycleEmissions() async throws {
        let payloadSize = 65536
        let originalPayload = TestAssertions.generateDeterministicPayload(size: payloadSize)

        let server = MockHTTPServer(payload: originalPayload)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/stream_events.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let manager = DownloadManager()

        let listenerTask = Task { () -> [DownloadTaskStatus] in
            var statuses: [DownloadTaskStatus] = []
            for await update in manager.taskPublisher {
                if !statuses.contains(update.status) {
                    statuses.append(update.status)
                }
                if update.status == .completed {
                    break
                }
            }
            return statuses
        }

        _ = try await manager.downloadAndWait(
            url: targetURL,
            destination: destURL,
            chunksCount: 4,
            timeout: 5.0
        )

        let collectedStatuses = await listenerTask.value
        #expect(collectedStatuses.contains(.probing))
        #expect(collectedStatuses.contains(.downloading))
        #expect(collectedStatuses.contains(.completed))
    }
}
