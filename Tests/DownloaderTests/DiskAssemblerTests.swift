import Testing
import Foundation
@testable import NetBoostCore

@Suite("Downloader: DiskAssembler Unit & Thread-Safety Tests", .tags(.tier1, .m4_downloader))
struct DiskAssemblerTests {

    private func makeTemporaryFileURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("netboost-disk-test-\(UUID().uuidString).bin")
    }

    @Test("Pre-allocate destination file to expected byte size")
    func testPreAllocateDestinationFile() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let assembler = DiskAssembler()
        let targetSize: Int64 = 1_048_576 // 1MB
        try assembler.prepare(fileURL: fileURL, totalBytes: targetSize)
        try assembler.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actualSize = attrs[.size] as? UInt64
        #expect(actualSize == UInt64(targetSize))
    }

    @Test("Seek to chunk offset and perform out-of-order writes for complete assembly")
    func testOutOfOrderWritesAssembly() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let assembler = DiskAssembler()
        let totalSize: Int64 = 4096
        try assembler.prepare(fileURL: fileURL, totalBytes: totalSize)

        let slice0 = Data(repeating: 0x11, count: 1024)
        let slice1 = Data(repeating: 0x22, count: 1024)
        let slice2 = Data(repeating: 0x33, count: 1024)
        let slice3 = Data(repeating: 0x44, count: 1024)

        // Write slices out of order: slice 2, slice 0, slice 3, slice 1
        try assembler.write(data: slice2, at: 2048)
        try assembler.write(data: slice0, at: 0)
        try assembler.write(data: slice3, at: 3072)
        try assembler.write(data: slice1, at: 1024)

        try assembler.flush()
        try assembler.close()

        let assembled = try Data(contentsOf: fileURL)
        #expect(assembled.count == 4096)
        #expect(assembled.subdata(in: 0..<1024) == slice0)
        #expect(assembled.subdata(in: 1024..<2048) == slice1)
        #expect(assembled.subdata(in: 2048..<3072) == slice2)
        #expect(assembled.subdata(in: 3072..<4096) == slice3)
    }

    @Test("Writing zero-byte data is a valid no-op")
    func testZeroByteWriteIsNoOp() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let assembler = DiskAssembler()
        try assembler.prepare(fileURL: fileURL, totalBytes: 10)
        try assembler.write(data: Data(), at: 0)
        try assembler.flush()
        try assembler.close()

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actualSize = attrs[.size] as? UInt64
        #expect(actualSize == 10)
    }

    @Test("Non-writable destination path raises error")
    func testNonWritablePathRaisesError() {
        let forbidden = URL(fileURLWithPath: "/System/Library/netboost_forbidden_\(UUID().uuidString).bin")
        let assembler = DiskAssembler()

        #expect(throws: Error.self) {
            try assembler.prepare(fileURL: forbidden, totalBytes: 1024)
        }
    }

    @Test("Writing without prepare throws error")
    func testWriteWithoutPrepareThrowsError() {
        let assembler = DiskAssembler()
        #expect(throws: Error.self) {
            try assembler.write(data: Data([1, 2, 3]), at: 0)
        }
    }

    @Test("Negative offset throws error")
    func testNegativeOffsetThrowsError() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let assembler = DiskAssembler()
        try assembler.prepare(fileURL: fileURL, totalBytes: 1024)

        #expect(throws: Error.self) {
            try assembler.write(data: Data([1, 2, 3]), at: -10)
        }
        try assembler.close()
    }
}
