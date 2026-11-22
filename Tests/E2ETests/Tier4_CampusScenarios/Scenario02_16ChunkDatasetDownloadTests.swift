import Foundation
import Testing
import Network
import CryptoKit
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 2: High-Speed 16-Chunk Campus Dataset Download", .tags(.tier4, .accelerator, .range_206, .m4_downloader))
struct Scenario02_16ChunkDatasetDownloadTests {

    @Test("16-chunk parallel download of campus research dataset with pre-allocation and bit-exact SHA-256 verification")
    func test16ChunkDatasetDownloadPipeline() async throws {
        // Step 1: Initialize Mock Server with 256KB dataset
        let datasetSize = 262_144 // 256 KB
        let originalPayload = TestAssertions.generateDeterministicPayload(size: datasetSize)
        let expectedSHA256 = TestAssertions.sha256Hex(of: originalPayload)

        let server = MockHTTPServer(payload: originalPayload)
        let port = try await server.start()
        defer { server.stop() }

        let datasetURL = URL(string: "http://127.0.0.1:\(port)/research_dataset.bin")!

        // Step 2: Capability Probe
        var headRequest = URLRequest(url: datasetURL)
        headRequest.httpMethod = "HEAD"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config)

        let (_, headResponse) = try await session.data(for: headRequest)
        guard let httpResponse = headResponse as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.expectedContentLength == Int64(datasetSize))
        #expect(httpResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")

        // Step 3: Dynamic 16-Chunk Partitioning
        let chunkCount = 16
        let chunkSize = datasetSize / chunkCount
        var chunks: [DownloadChunkInfo] = []

        for i in 0..<chunkCount {
            let start = Int64(i * chunkSize)
            let end = (i == chunkCount - 1) ? Int64(datasetSize - 1) : Int64((i + 1) * chunkSize - 1)
            chunks.append(DownloadChunkInfo(id: i, rangeStart: start, rangeEnd: end))
        }

        #expect(chunks.count == 16)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == Int64(datasetSize - 1))

        // Step 4: Random-Access Disk Assembler Pre-allocation
        let tempDir = FileManager.default.temporaryDirectory
        let destinationFile = tempDir.appendingPathComponent("campus_dataset_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destinationFile) }

        FileManager.default.createFile(atPath: destinationFile.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationFile)
        try fileHandle.truncate(atOffset: UInt64(datasetSize))

        final class ConcurrentDiskWriter: @unchecked Sendable {
            private let lock = NSLock()
            private let handle: FileHandle
            private var completedBytes: Int = 0

            init(handle: FileHandle) {
                self.handle = handle
            }

            func writeSlice(data: Data, at offset: UInt64) throws {
                lock.lock()
                defer { lock.unlock() }
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: data)
                completedBytes += data.count
            }

            func progress(total: Int) -> Double {
                lock.lock()
                defer { lock.unlock() }
                return Double(completedBytes) / Double(total)
            }
        }

        let writer = ConcurrentDiskWriter(handle: fileHandle)

        // Step 5: 16 Concurrent HTTP Range Data Tasks
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for chunk in chunks {
                group.addTask {
                    var req = URLRequest(url: datasetURL)
                    req.setValue("bytes=\(chunk.rangeStart)-\(chunk.rangeEnd)", forHTTPHeaderField: "Range")

                    let taskSession = URLSession(configuration: .ephemeral)
                    let (data, response) = try await taskSession.data(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                        throw NSError(domain: "Scenario2", code: -1)
                    }

                    try writer.writeSlice(data: data, at: UInt64(chunk.rangeStart))
                    return (chunk.id, data.count)
                }
            }

            for try await (chunkId, bytes) in group {
                #expect(bytes > 0)
                #expect(chunkId >= 0 && chunkId < 16)
            }
        }

        try fileHandle.synchronize()
        try fileHandle.close()

        // Step 6: Verify 100% Assembly Completion
        let finalProgress = writer.progress(total: datasetSize)
        #expect(finalProgress == 1.0)

        // Step 7: Checksum Verification against Original Server Manifest
        let assembledBytes = try Data(contentsOf: destinationFile)
        #expect(assembledBytes.count == datasetSize)
        let assembledSHA256 = TestAssertions.sha256Hex(of: assembledBytes)
        #expect(assembledSHA256 == expectedSHA256)
    }
}
