import Testing
import Foundation
@testable import NetBoostCore

@Suite("Downloader: ChunkPartitionEngine Unit Tests", .tags(.tier1, .m4_downloader, .accelerator))
struct ChunkPartitionEngineTests {

    @Test("Small file (<1MB) partitioned into a single chunk")
    func testSmallFilePartitioning() {
        let size: Int64 = 500_000
        let chunks = ChunkPartitionEngine.partition(totalBytes: size, desiredChunks: 8)

        #expect(chunks.count == 1)
        #expect(chunks[0].rangeStart == 0)
        #expect(chunks[0].rangeEnd == 499_999)
        #expect(chunks[0].totalBytes == 500_000)
    }

    @Test("1-byte file creates single chunk bytes=0-0")
    func testOneByteFilePartitioning() {
        let chunks = ChunkPartitionEngine.partition(totalBytes: 1, desiredChunks: 8)

        #expect(chunks.count == 1)
        #expect(chunks[0].rangeStart == 0)
        #expect(chunks[0].rangeEnd == 0)
        #expect(chunks[0].totalBytes == 1)
    }

    @Test("Zero or negative bytes return empty chunks")
    func testZeroAndNegativeBytes() {
        #expect(ChunkPartitionEngine.partition(totalBytes: 0, desiredChunks: 8).isEmpty)
        #expect(ChunkPartitionEngine.partition(totalBytes: -100, desiredChunks: 8).isEmpty)
    }

    @Test("Partition 100MB file into 8 contiguous slices")
    func testPartition100MBInto8Chunks() {
        let size: Int64 = 104_857_600 // 100MB
        let chunks = ChunkPartitionEngine.partition(totalBytes: size, desiredChunks: 8)

        #expect(chunks.count == 8)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == size - 1)

        let sumBytes = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(sumBytes == size)
    }

    @Test("Partition 1GB file into 16 contiguous slices")
    func testPartition1GBInto16Chunks() {
        let size: Int64 = 1_073_741_824 // 1GB
        let chunks = ChunkPartitionEngine.partition(totalBytes: size, desiredChunks: 16)

        #expect(chunks.count == 16)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == size - 1)

        let sumBytes = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(sumBytes == size)
    }

    @Test("Verify strict byte continuity across all adjacent chunks")
    func testByteContinuityInvariant() {
        let size: Int64 = 52_428_800
        let chunks = ChunkPartitionEngine.partition(totalBytes: size, desiredChunks: 8)

        for i in 0..<(chunks.count - 1) {
            #expect(chunks[i].rangeEnd + 1 == chunks[i + 1].rangeStart)
        }
    }

    @Test("Boundary invariant: chunk[0].start == 0 and chunk[last].end == totalBytes - 1")
    func testBoundaryZeroAndEndInvariant() {
        let size: Int64 = 12_345_678
        let chunks = ChunkPartitionEngine.partition(totalBytes: size, desiredChunks: 8)

        #expect(chunks[0].rangeStart == 0)
        #expect(chunks[chunks.count - 1].rangeEnd == size - 1)
    }

    @Test("Non-divisible file size: last chunk absorbs remainder bytes exactly")
    func testNonDivisibleFileSizeRemainder() {
        let total: Int64 = 100_000_007
        let chunks = ChunkPartitionEngine.partition(totalBytes: total, desiredChunks: 8)

        #expect(chunks.count == 8)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == total - 1)

        let sumBytes = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(sumBytes == total)
    }

    @Test("Very large file (>100GB) calculation avoids 32-bit overflow")
    func testLargeFile64BitCalculations() {
        let total: Int64 = 150 * 1024 * 1024 * 1024 // 150 GB
        let chunks = ChunkPartitionEngine.partition(totalBytes: total, desiredChunks: 16)

        #expect(chunks.count == 16)
        #expect(chunks.last?.rangeEnd == total - 1)

        let sumBytes = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(sumBytes == total)
    }
}
