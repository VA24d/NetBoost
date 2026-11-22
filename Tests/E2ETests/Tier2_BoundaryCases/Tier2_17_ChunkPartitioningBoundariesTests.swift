import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 17: Chunk Partitioning Boundaries", .tags(.tier2, .m4_downloader, .accelerator))
struct Tier2_17_ChunkPartitioningBoundariesTests {

    func partitionFile(totalBytes: Int64, desiredChunks: Int) -> [DownloadChunkInfo] {
        guard totalBytes > 0 else { return [] }
        guard totalBytes > 1024 * 1024 else {
            // Small file (<1MB): single chunk
            return [DownloadChunkInfo(id: 0, rangeStart: 0, rangeEnd: totalBytes - 1)]
        }

        let numChunks = max(1, min(desiredChunks, 16))
        let chunkSize = totalBytes / Int64(numChunks)
        var chunks: [DownloadChunkInfo] = []

        var currentOffset: Int64 = 0
        for i in 0..<numChunks {
            let start = currentOffset
            let end: Int64
            if i == numChunks - 1 {
                // Last chunk absorbs any remainder
                end = totalBytes - 1
            } else {
                end = start + chunkSize - 1
            }
            chunks.append(DownloadChunkInfo(id: i, rangeStart: start, rangeEnd: end))
            currentOffset = end + 1
        }
        return chunks
    }

    @Test("T2-F17-01: Small file (<1MB) partitioned into single chunk to avoid connection overhead")
    func testSmallFilePartitioning() {
        let chunks = partitionFile(totalBytes: 500_000, desiredChunks: 8)
        #expect(chunks.count == 1)
        #expect(chunks[0].rangeStart == 0)
        #expect(chunks[0].rangeEnd == 499_999)
        #expect(chunks[0].totalBytes == 500_000)
    }

    @Test("T2-F17-02: Non-divisible file size: last chunk absorbs remainder bytes")
    func testNonDivisibleFileSizeRemainder() {
        // 100,000,007 bytes split into 8 chunks
        let total: Int64 = 100_000_007
        let chunks = partitionFile(totalBytes: total, desiredChunks: 8)

        #expect(chunks.count == 8)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == total - 1)

        let totalCalculated = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(totalCalculated == total)
    }

    @Test("T2-F17-03: 1-byte file creates single chunk bytes=0-0")
    func testOneByteFilePartitioning() {
        let chunks = partitionFile(totalBytes: 1, desiredChunks: 8)
        #expect(chunks.count == 1)
        #expect(chunks[0].rangeStart == 0)
        #expect(chunks[0].rangeEnd == 0)
        #expect(chunks[0].totalBytes == 1)
    }

    @Test("T2-F17-04: Very large file (>100GB) calculation avoids 32-bit overflow")
    func testLargeFile64BitCalculations() {
        let total: Int64 = 150 * 1024 * 1024 * 1024 // 150 GB
        let chunks = partitionFile(totalBytes: total, desiredChunks: 16)

        #expect(chunks.count == 16)
        #expect(chunks.last?.rangeEnd == total - 1)
        let totalCalculated = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(totalCalculated == total)
    }

    @Test("T2-F17-05: Byte continuity invariant across all adjacent chunks")
    func testByteContinuityInvariant() {
        let chunks = partitionFile(totalBytes: 52_428_800, desiredChunks: 8)
        for i in 0..<(chunks.count - 1) {
            #expect(chunks[i].rangeEnd + 1 == chunks[i + 1].rangeStart)
        }
    }
}
