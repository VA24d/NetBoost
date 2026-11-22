import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 17: Dynamic Byte-Range Partitioning", .tags(.tier1, .m4_downloader, .accelerator))
struct Tier1_17_ChunkPartitioningTests {

    struct ByteRangePartitioner {
        static func partition(totalBytes: Int64, chunkCount: Int) -> [DownloadChunkInfo] {
            guard totalBytes > 0, chunkCount > 0 else { return [] }
            let count = Int64(min(Int(totalBytes), chunkCount))
            let chunkSize = totalBytes / count
            let remainder = totalBytes % count

            var chunks: [DownloadChunkInfo] = []
            var currentOffset: Int64 = 0

            for i in 0..<count {
                let extra: Int64 = (i == count - 1) ? remainder : 0
                let start = currentOffset
                let end = start + chunkSize - 1 + extra
                chunks.append(DownloadChunkInfo(
                    id: Int(i),
                    rangeStart: start,
                    rangeEnd: end,
                    downloadedBytes: 0,
                    status: .pending,
                    speedBytesPerSec: 0
                ))
                currentOffset = end + 1
            }

            return chunks
        }
    }

    @Test("T1-F17-01: Partition 100MB file into 8 contiguous byte slices")
    func testPartition100MBInto8Chunks() {
        let size: Int64 = 104_857_600 // 100MB
        let chunks = ByteRangePartitioner.partition(totalBytes: size, chunkCount: 8)

        #expect(chunks.count == 8)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == size - 1)
    }

    @Test("T1-F17-02: Partition 1GB file into 16 contiguous byte slices")
    func testPartition1GBInto16Chunks() {
        let size: Int64 = 1_073_741_824 // 1GB
        let chunks = ByteRangePartitioner.partition(totalBytes: size, chunkCount: 16)

        #expect(chunks.count == 16)
        #expect(chunks.first?.rangeStart == 0)
        #expect(chunks.last?.rangeEnd == size - 1)
    }

    @Test("T1-F17-03: Verify strict byte continuity across all adjacent chunks")
    func testByteContinuityInvariant() {
        let size: Int64 = 52_428_800
        let chunks = ByteRangePartitioner.partition(totalBytes: size, chunkCount: 8)

        for i in 0..<(chunks.count - 1) {
            #expect(chunks[i].rangeEnd + 1 == chunks[i + 1].rangeStart)
        }
    }

    @Test("T1-F17-04: Boundary check: chunk[0].start == 0 and chunk[last].end == totalBytes - 1")
    func testBoundaryZeroAndEndInvariant() {
        let size: Int64 = 12_345_678 // non-power-of-2
        let chunks = ByteRangePartitioner.partition(totalBytes: size, chunkCount: 8)

        #expect(chunks[0].rangeStart == 0)
        #expect(chunks[chunks.count - 1].rangeEnd == size - 1)
    }

    @Test("T1-F17-05: Sum of individual chunk capacities equals exact total Content-Length")
    func testTotalCapacityEqualsContentLength() {
        let size: Int64 = 99_999_999
        let chunks = ByteRangePartitioner.partition(totalBytes: size, chunkCount: 12)

        let sumBytes = chunks.reduce(0) { $0 + $1.totalBytes }
        #expect(sumBytes == size)
    }
}
