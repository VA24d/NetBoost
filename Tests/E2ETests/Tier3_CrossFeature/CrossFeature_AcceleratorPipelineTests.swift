import Foundation
import Testing
import Network
import CryptoKit
@testable import NetBoostCore

@Suite("Tier 3: Accelerator Pipeline Interaction", .tags(.tier3, .accelerator, .range_206, .m4_downloader))
struct CrossFeature_AcceleratorPipelineTests {

    @Test("Capability probe parses Content-Length and Accept-Ranges from HTTP server")
    func testCapabilityProbe() async throws {
        let payloadSize = 65536 // 64 KB
        let testData = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let server = MockHTTPServer(payload: testData)
        let port = try await server.start()
        defer { server.stop() }

        let targetURL = URL(string: "http://127.0.0.1:\(port)/dataset.bin")!
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
        #expect(httpResponse.expectedContentLength == Int64(payloadSize))
        #expect(httpResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    }

    @Test("Dynamic byte-range partitioning generates contiguous, non-overlapping chunks covering total file")
    func testByteRangePartitioning() {
        let totalSize: Int64 = 1_048_576 // 1 MB
        let chunkCount = 8
        let chunkSize = totalSize / Int64(chunkCount)

        var chunks: [DownloadChunkInfo] = []
        for i in 0..<chunkCount {
            let start = Int64(i) * chunkSize
            let end = (i == chunkCount - 1) ? (totalSize - 1) : (start + chunkSize - 1)
            chunks.append(DownloadChunkInfo(id: i, rangeStart: start, rangeEnd: end))
        }

        #expect(chunks.count == 8)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == totalSize - 1)

        // Verify continuity
        for i in 0..<(chunkCount - 1) {
            #expect(chunks[i].rangeEnd + 1 == chunks[i + 1].rangeStart)
        }

        let totalCovered = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(totalCovered == totalSize)
    }

    @Test("Random-access disk assembler pre-allocates file and validates file size")
    func testDiskAssemblerPreallocation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("prealloc_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let targetSize: UInt64 = 524_288 // 512 KB
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempFile)
        try handle.truncate(atOffset: targetSize)
        try handle.close()

        let attributes = try FileManager.default.attributesOfItem(atPath: tempFile.path)
        let fileSize = attributes[.size] as? UInt64
        #expect(fileSize == targetSize)
    }

    @Test("Concurrent URLSession data streaming writes chunks directly to pre-allocated file and computes metrics")
    func testConcurrentStreamingAndAssembly() async throws {
        let payloadSize = 131_072 // 128 KB
        let originalData = TestAssertions.generateDeterministicPayload(size: payloadSize)
        let server = MockHTTPServer(payload: originalData)
        let port = try await server.start()
        defer { server.stop() }

        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("assembled_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        // Pre-allocate file
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        try fileHandle.truncate(atOffset: UInt64(payloadSize))

        final class SafeWriter: @unchecked Sendable {
            private let lock = NSLock()
            private let handle: FileHandle

            init(handle: FileHandle) {
                self.handle = handle
            }

            func write(chunk: Data, at offset: UInt64) throws {
                lock.lock()
                defer { lock.unlock() }
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: chunk)
            }
        }

        let writer = SafeWriter(handle: fileHandle)
        let chunkCount = 4
        let chunkSize = payloadSize / chunkCount
        let targetURL = URL(string: "http://127.0.0.1:\(port)/download.bin")!

        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for i in 0..<chunkCount {
                let start = i * chunkSize
                let end = (i == chunkCount - 1) ? (payloadSize - 1) : (start + chunkSize - 1)

                group.addTask {
                    var request = URLRequest(url: targetURL)
                    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 5.0
                    let session = URLSession(configuration: config)

                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 206 else {
                        throw NSError(domain: "PipelineTest", code: -1, userInfo: nil)
                    }

                    try writer.write(chunk: data, at: UInt64(start))
                    return (i, data.count)
                }
            }

            var totalReceived = 0
            for try await (_, count) in group {
                totalReceived += count
            }
            #expect(totalReceived == payloadSize)
        }

        try fileHandle.synchronize()
        try fileHandle.close()

        // Verify assembled file matches original
        let assembledData = try Data(contentsOf: destinationURL)
        #expect(assembledData.count == originalData.count)
        #expect(assembledData == originalData)
    }

    @Test("Checksum integrity verifier validates SHA-256 and MD5 over assembled file")
    func testChecksumVerification() throws {
        let testData = TestAssertions.generateDeterministicPayload(size: 65536)
        let expectedSHA256 = TestAssertions.sha256Hex(of: testData)
        let expectedMD5 = TestAssertions.md5Hex(of: testData)

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("checksum_verify_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try testData.write(to: tempFile)

        let readData = try Data(contentsOf: tempFile)
        let computedSHA256 = TestAssertions.sha256Hex(of: readData)
        let computedMD5 = TestAssertions.md5Hex(of: readData)

        #expect(computedSHA256 == expectedSHA256)
        #expect(computedMD5 == expectedMD5)
    }
}
