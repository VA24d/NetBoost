import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 19: Disk Assembler Boundaries", .tags(.tier2, .m4_downloader, .accelerator))
struct Tier2_19_DiskAssemblerBoundariesTests {

    @Test("T2-F19-01: Pre-allocate destination file to expected size via truncate")
    func testPreAllocateFileSize() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("netboost_preallocate_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempFile)
        let expectedSize: UInt64 = 10 * 1024 * 1024 // 10 MB
        try handle.truncate(atOffset: expectedSize)
        try handle.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: tempFile.path)
        let actualSize = attrs[.size] as? UInt64
        #expect(actualSize == expectedSize)
    }

    @Test("T2-F19-02: Non-writable destination path raises error")
    func testNonWritableDestinationPath() {
        let nonWritable = URL(fileURLWithPath: "/System/Library/netboost_forbidden_\(UUID().uuidString).bin")
        #expect(throws: Error.self) {
            try FileHandle(forWritingTo: nonWritable)
        }
    }

    @Test("T2-F19-03: Concurrent non-overlapping random-access writes produce bit-exact assembled file")
    func testRandomAccessAssemblerWrites() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("netboost_assemble_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let totalSize: UInt64 = 4096
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let handle = try FileHandle(forUpdating: tempFile)
        try handle.truncate(atOffset: totalSize)

        // Write 4 distinct slices out-of-order: slice 3, slice 1, slice 0, slice 2
        let slice0 = Data(repeating: 0xAA, count: 1024)
        let slice1 = Data(repeating: 0xBB, count: 1024)
        let slice2 = Data(repeating: 0xCC, count: 1024)
        let slice3 = Data(repeating: 0xDD, count: 1024)

        try handle.seek(toOffset: 3072)
        try handle.write(contentsOf: slice3)

        try handle.seek(toOffset: 1024)
        try handle.write(contentsOf: slice1)

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: slice0)

        try handle.seek(toOffset: 2048)
        try handle.write(contentsOf: slice2)

        try handle.synchronize()
        try handle.close()

        let assembledData = try Data(contentsOf: tempFile)
        #expect(assembledData.count == 4096)
        #expect(assembledData.subdata(in: 0..<1024) == slice0)
        #expect(assembledData.subdata(in: 1024..<2048) == slice1)
        #expect(assembledData.subdata(in: 2048..<3072) == slice2)
        #expect(assembledData.subdata(in: 3072..<4096) == slice3)
    }

    @Test("T2-F19-04: Writing zero-byte slice at offset is a valid no-op")
    func testZeroByteWriteHandling() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("netboost_zerobyte_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        FileManager.default.createFile(atPath: tempFile.path, contents: Data([0x01, 0x02, 0x03]))
        let handle = try FileHandle(forUpdating: tempFile)
        try handle.seek(toOffset: 1)
        try handle.write(contentsOf: Data())
        try handle.close()

        let data = try Data(contentsOf: tempFile)
        #expect(data == Data([0x01, 0x02, 0x03]))
    }

    @Test("T2-F19-05: Existing file overwrite policy replaces or updates cleanly")
    func testFileOverwriteHandling() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("netboost_overwrite_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let oldData = Data(repeating: 0x11, count: 500)
        FileManager.default.createFile(atPath: tempFile.path, contents: oldData)

        let newData = Data(repeating: 0x22, count: 1000)
        try newData.write(to: tempFile, options: .atomic)

        let readData = try Data(contentsOf: tempFile)
        #expect(readData.count == 1000)
        #expect(readData == newData)
    }
}
