import Testing
import Foundation

@Suite("Feature 19: Random-Access Disk Assembler", .tags(.tier1, .m4_downloader))
struct Tier1_19_DiskAssemblerTests {

    private func makeTemporaryFileURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("netboost-test-\(UUID().uuidString).bin")
    }

    @Test("T1-F19-01: Pre-allocate target file using FileHandle.truncate")
    func testPreAllocateFile() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        let targetSize: UInt64 = 1_048_576 // 1MB
        try handle.truncate(atOffset: targetSize)
        try handle.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actualSize = attrs[.size] as? UInt64
        #expect(actualSize == targetSize)
    }

    @Test("T1-F19-02: Seek to chunk start offset and write data blocks")
    func testSeekAndWriteChunk() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 1000)

        // Write at offset 500
        let testData = "HelloWorld".data(using: .utf8)!
        try handle.seek(toOffset: 500)
        try handle.write(contentsOf: testData)
        try handle.close()

        let readHandle = try FileHandle(forReadingFrom: fileURL)
        try readHandle.seek(toOffset: 500)
        let readData = try readHandle.read(upToCount: testData.count)
        try readHandle.close()

        #expect(readData == testData)
    }

    @Test("T1-F19-03: Multiple non-overlapping writes assemble complete contiguous payload")
    func testNonOverlappingChunkAssembly() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 20)

        let chunk1 = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let chunk2 = Data([11, 12, 13, 14, 15, 16, 17, 18, 19, 20])

        // Write chunk 2 first, then chunk 1 (out of order writing)
        try handle.seek(toOffset: 10)
        try handle.write(contentsOf: chunk2)

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: chunk1)

        try handle.synchronize()
        try handle.close()

        let fullData = try Data(contentsOf: fileURL)
        #expect(fullData.count == 20)
        #expect(fullData[0] == 1)
        #expect(fullData[9] == 10)
        #expect(fullData[10] == 11)
        #expect(fullData[19] == 20)
    }

    @Test("T1-F19-04: Flush disk buffers via FileHandle.synchronize")
    func testSynchronizeBuffers() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.write(contentsOf: Data([0xAA, 0xBB, 0xCC]))
        try handle.synchronize()
        try handle.close()

        let written = try Data(contentsOf: fileURL)
        #expect(written.count == 3)
    }

    @Test("T1-F19-05: Assembled file size on disk matches expected byte size exactly")
    func testFinalFileSizeMatchesExpected() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        let expectedSize: UInt64 = 65536
        try handle.truncate(atOffset: expectedSize)
        try handle.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? UInt64
        #expect(fileSize == expectedSize)
    }
}
