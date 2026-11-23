import Foundation

public protocol ChunkPartitionEngineProtocol: Sendable {
    func partition(totalBytes: Int64, desiredChunks: Int) -> [DownloadChunkInfo]
}

public struct ChunkPartitionEngine: ChunkPartitionEngineProtocol {
    public init() {}

    public func partition(totalBytes: Int64, desiredChunks: Int = 8) -> [DownloadChunkInfo] {
        Self.partition(totalBytes: totalBytes, desiredChunks: desiredChunks)
    }

    /// Partitions a file of totalBytes into contiguous byte chunks.
    /// - Parameters:
    ///   - totalBytes: Total size in bytes of the target file.
    ///   - desiredChunks: Target chunk count (clamped between 1 and 16).
    /// - Returns: An array of DownloadChunkInfo covering the entire byte range [0, totalBytes - 1].
    public static func partition(totalBytes: Int64, desiredChunks: Int = 8) -> [DownloadChunkInfo] {
        guard totalBytes > 0 else { return [] }

        // Small file (<1MB): single chunk to avoid connection setup overhead
        guard totalBytes >= 1_048_576 else {
            return [DownloadChunkInfo(
                id: 0,
                rangeStart: 0,
                rangeEnd: totalBytes - 1,
                downloadedBytes: 0,
                status: .pending,
                speedBytesPerSec: 0
            )]
        }

        let clampedChunks = max(1, min(desiredChunks, 16))
        let numChunks = Int64(min(Int64(clampedChunks), totalBytes))
        guard numChunks > 0 else { return [] }

        let chunkSize = totalBytes / numChunks
        var chunks: [DownloadChunkInfo] = []
        chunks.reserveCapacity(Int(numChunks))

        var currentOffset: Int64 = 0
        for i in 0..<numChunks {
            let start = currentOffset
            let end: Int64
            if i == numChunks - 1 {
                // The last chunk absorbs any remaining fractional bytes to ensure exact byte coverage
                end = totalBytes - 1
            } else {
                end = start + chunkSize - 1
            }

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
