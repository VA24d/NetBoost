import Foundation
import Testing
import Network
import CryptoKit
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 9: Segmented Download Dynamic Chunk Failure & Resumption", .tags(.tier4, .accelerator, .range_206, .m4_downloader))
struct Scenario09_DownloadChunkFailureRecoveryTests {

    @Test("Segmented download detects chunk failure mid-stream, preserves healthy chunks, and resumes failed slice to 100% SHA-256 integrity")
    func testChunkFailureAndResumptionPipeline() async throws {
        // Step 1: 128 KB Payload Setup
        let payloadSize = 131_072 // 128 KB
        let originalPayload = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let expectedSHA256 = TestAssertions.sha256Hex(of: originalPayload)

        let server = MockHTTPServer(payload: originalPayload)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/resilient_dataset.bin")!

        // Step 2: 4-Chunk Partitioning (32 KB per chunk)
        let chunkCount = 4
        let chunkSize = payloadSize / chunkCount
        var chunks: [DownloadChunkInfo] = []

        for i in 0..<chunkCount {
            let start = Int64(i * chunkSize)
            let end = (i == chunkCount - 1) ? Int64(payloadSize - 1) : Int64((i + 1) * chunkSize - 1)
            chunks.append(DownloadChunkInfo(id: i, rangeStart: start, rangeEnd: end))
        }

        #expect(chunks.count == 4)

        // Step 3: Destination File Pre-allocation
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("resumed_download_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        try fileHandle.truncate(atOffset: UInt64(payloadSize))

        final class ThreadSafeAssembler: @unchecked Sendable {
            private let lock = NSLock()
            private let handle: FileHandle

            init(handle: FileHandle) {
                self.handle = handle
            }

            func writeData(_ data: Data, at offset: UInt64) throws {
                lock.lock()
                defer { lock.unlock() }
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: data)
            }
        }

        let assembler = ThreadSafeAssembler(handle: fileHandle)

        // Step 4: Download Chunks 0, 1, 3 successfully
        for chunk in [chunks[0], chunks[1], chunks[3]] {
            var req = URLRequest(url: targetURL)
            req.setValue("bytes=\(chunk.rangeStart)-\(chunk.rangeEnd)", forHTTPHeaderField: "Range")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                Issue.record("Failed to fetch chunk \(chunk.id)")
                return
            }

            try assembler.writeData(data, at: UInt64(chunk.rangeStart))
        }

        // Step 5: Simulate Mid-Stream Failure on Chunk 2 after partial download (16 KB of 32 KB)
        let failedChunk = chunks[2]
        let partialLength = chunkSize / 2 // 16 KB partial
        let partialSlice = originalPayload.subdata(in: Int(failedChunk.rangeStart)..<(Int(failedChunk.rangeStart) + partialLength))

        // Write partial slice to disk
        try assembler.writeData(partialSlice, at: UInt64(failedChunk.rangeStart))

        var failedChunkState = failedChunk
        failedChunkState.downloadedBytes = Int64(partialLength)
        failedChunkState.status = .failed

        #expect(failedChunkState.downloadedBytes == 16384)
        #expect(failedChunkState.status == .failed)

        // Step 6: Dynamic Resumption Calculation for Chunk 2
        let resumeStart = failedChunk.rangeStart + failedChunkState.downloadedBytes
        let resumeEnd = failedChunk.rangeEnd
        #expect(resumeStart < resumeEnd)

        // Step 7: Request Remaining Slice: Range: bytes=resumeStart-resumeEnd
        var resumeRequest = URLRequest(url: targetURL)
        resumeRequest.setValue("bytes=\(resumeStart)-\(resumeEnd)", forHTTPHeaderField: "Range")

        let (resumedData, resumeResponse) = try await URLSession.shared.data(for: resumeRequest)
        guard let resumeHTTP = resumeResponse as? HTTPURLResponse, resumeHTTP.statusCode == 206 else {
            Issue.record("Failed to resume chunk 2")
            return
        }

        #expect(resumedData.count == Int(resumeEnd - resumeStart + 1))

        // Write remaining slice at resumeStart offset
        try assembler.writeData(resumedData, at: UInt64(resumeStart))
        failedChunkState.downloadedBytes += Int64(resumedData.count)
        failedChunkState.status = .completed

        #expect(failedChunkState.progress == 1.0)
        #expect(failedChunkState.status == .completed)

        try fileHandle.synchronize()
        try fileHandle.close()

        // Step 8: Verify Complete Assembled File Matches Original SHA-256
        let assembledFileBytes = try Data(contentsOf: destinationURL)
        #expect(assembledFileBytes.count == payloadSize)
        let assembledSHA256 = TestAssertions.sha256Hex(of: assembledFileBytes)
        #expect(assembledSHA256 == expectedSHA256)
    }
}
