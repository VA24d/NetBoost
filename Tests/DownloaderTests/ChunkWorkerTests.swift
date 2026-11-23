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
}
