import Testing
import Foundation
@testable import NetBoostCore

@Suite("Downloader: ChunkWorker Unit Tests", .tags(.tier1, .m4_downloader, .range_206))
struct ChunkWorkerTests {

    private func makeTemporaryFileURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("netboost-chunkworker-\(UUID().uuidString).bin")
    }

    @Test("Stream single chunk directly to DiskAssembler")
    func testSingleChunkWorkerDownload() async throws {
        let payload = TestAssertions.generateDeterministicPayload(size: 32768)
        let server = MockHTTPServer(payload: payload)
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/chunk_test.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let assembler = DiskAssembler()
        try assembler.prepare(fileURL: destURL, totalBytes: 32768)

        let chunk = DownloadChunkInfo(id: 0, rangeStart: 0, rangeEnd: 32767)
        let worker = ChunkWorker(
            chunk: chunk,
            url: testURL,
            assembler: assembler,
            session: .shared
        )

        let completedChunk = try await worker.download()
        try assembler.flush()
        try assembler.close()

        #expect(completedChunk.status == .completed)
        #expect(completedChunk.downloadedBytes == 32768)

        let written = try Data(contentsOf: destURL)
        #expect(written == payload)
    }

    @Test("Calculate exponential backoff correctly")
    func testCalculateExponentialBackoff() {
        #expect(ChunkWorker.calculateBackoff(retryAfterHeader: "12", attempt: 0) == 12.0)
        #expect(ChunkWorker.calculateBackoff(retryAfterHeader: nil, attempt: 0) == 1.0)
        #expect(ChunkWorker.calculateBackoff(retryAfterHeader: nil, attempt: 1) == 2.0)
        #expect(ChunkWorker.calculateBackoff(retryAfterHeader: nil, attempt: 2) == 4.0)
        #expect(ChunkWorker.calculateBackoff(retryAfterHeader: nil, attempt: 3) == 8.0)
        #expect(ChunkWorker.calculateBackoff(retryAfterHeader: nil, attempt: 10) == 30.0) // Clamped at 30s
    }

    @Test("Resume range header calculation from partial byte offset")
    func testResumeRangeHeaderCalculation() {
        let partial = DownloadChunkInfo(
            id: 2,
            rangeStart: 2000,
            rangeEnd: 3999,
            downloadedBytes: 750,
            status: .pending
        )

        let header = ChunkWorker.makeResumeRange(chunk: partial)
        #expect(header == "bytes=2750-3999")
    }

    @Test("Terminal HTTP 416 throws rangeNotSatisfiable error")
    func testTerminalHTTP416Error() async throws {
        let server = MockHTTPServer()
        server.forceRange416 = true
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/terminal_416.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let assembler = DiskAssembler()
        try assembler.prepare(fileURL: destURL, totalBytes: 1000)

        let chunk = DownloadChunkInfo(id: 0, rangeStart: 0, rangeEnd: 999)
        let worker = ChunkWorker(
            chunk: chunk,
            url: testURL,
            assembler: assembler,
            session: .shared
        )

        do {
            _ = try await worker.download()
            Issue.record("Expected 416 error")
        } catch let err as ChunkWorkerError {
            #expect(err == .rangeNotSatisfiable)
        }
    }

    @Test("Task cancellation cleanly terminates ChunkWorker")
    func testChunkWorkerCancellation() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/cancel.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let assembler = DiskAssembler()
        try assembler.prepare(fileURL: destURL, totalBytes: 1000)

        let chunk = DownloadChunkInfo(id: 0, rangeStart: 0, rangeEnd: 999)
        let worker = ChunkWorker(
            chunk: chunk,
            url: testURL,
            assembler: assembler,
            session: .shared
        )

        let task = Task {
            try await worker.download()
        }

        task.cancel()
        let result = await task.result
        switch result {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success(let c):
            #expect(c.status == .completed)
        }
    }

    @Test("Incremental streaming fires multiple progress callbacks across large chunk")
    func testStreamingProgressCallbacks() async throws {
        final class ProgressRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [(id: Int, bytes: Int64, speed: Double)] = []

            func record(id: Int, bytes: Int64, speed: Double) {
                lock.withLock {
                    events.append((id, bytes, speed))
                }
            }

            var snapshot: [(id: Int, bytes: Int64, speed: Double)] {
                lock.withLock { events }
            }
        }

        let payloadSize = 524_288 // 512 KB (> 256KB threshold and > 64KB block size)
        let payload = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let server = MockHTTPServer(payload: payload)
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/streaming.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let assembler = DiskAssembler()
        try assembler.prepare(fileURL: destURL, totalBytes: Int64(payloadSize))

        let recorder = ProgressRecorder()
        let chunk = DownloadChunkInfo(id: 3, rangeStart: 0, rangeEnd: Int64(payloadSize - 1))
        let worker = ChunkWorker(
            chunk: chunk,
            url: testURL,
            assembler: assembler,
            session: .shared
        ) { chunkId, bytes, speed in
            recorder.record(id: chunkId, bytes: bytes, speed: speed)
        }

        let completed = try await worker.download()
        try assembler.flush()
        try assembler.close()

        #expect(completed.status == .completed)
        #expect(completed.downloadedBytes == Int64(payloadSize))

        let events = recorder.snapshot
        #expect(events.count >= 2)
        #expect(events.allSatisfy { $0.id == 3 && $0.speed > 0 })
        #expect(events.last?.bytes == Int64(payloadSize))

        for i in 1..<events.count {
            #expect(events[i].bytes >= events[i - 1].bytes)
        }

        let written = try Data(contentsOf: destURL)
        #expect(written == payload)
    }

    @Test("Rejects unexpected HTTP 200 OK when requesting non-zero byte offset")
    func testRejectUnexpected200OnPartialOffset() async throws {
        let payloadSize = 8192
        let payload = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let server = MockHTTPServer(payload: payload)
        server.simulateNonRangeSupport = true // Ignores Range and returns HTTP 200 with full body
        let port = try await server.start()
        defer { server.stop() }

        let testURL = URL(string: "http://127.0.0.1:\(port)/full_instead_of_206.bin")!
        let destURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destURL) }

        let assembler = DiskAssembler()
        try assembler.prepare(fileURL: destURL, totalBytes: Int64(payloadSize))

        // Chunk 1 starts at offset 4096 (> 0)
        let partialChunk = DownloadChunkInfo(id: 1, rangeStart: 4096, rangeEnd: 8191)
        let worker = ChunkWorker(
            chunk: partialChunk,
            url: testURL,
            assembler: assembler,
            session: .shared
        )

        do {
            _ = try await worker.download()
            Issue.record("Expected serverError(statusCode: 200) when server returns 200 for startByte > 0")
        } catch let err as ChunkWorkerError {
            #expect(err == .serverError(statusCode: 200))
        }

        try assembler.close()
        // File must remain untouched (all zero-filled from prepare) rather than overwritten with byte 0 at offset 4096
        let diskData = try Data(contentsOf: destURL)
        #expect(diskData == Data(repeating: 0, count: payloadSize))
    }
}
