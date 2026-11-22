import Foundation

public enum ChunkStatus: String, Codable, Sendable {
    case pending
    case downloading
    case completed
    case failed
}

public struct DownloadChunkInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: Int
    public let rangeStart: Int64
    public let rangeEnd: Int64
    public var downloadedBytes: Int64
    public var status: ChunkStatus
    public var speedBytesPerSec: Double

    public init(
        id: Int,
        rangeStart: Int64,
        rangeEnd: Int64,
        downloadedBytes: Int64 = 0,
        status: ChunkStatus = .pending,
        speedBytesPerSec: Double = 0
    ) {
        self.id = id
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.downloadedBytes = downloadedBytes
        self.status = status
        self.speedBytesPerSec = speedBytesPerSec
    }

    public var totalBytes: Int64 {
        max(0, rangeEnd - rangeStart + 1)
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }
}

public enum DownloadTaskStatus: String, Codable, Sendable {
    case queued
    case probing
    case downloading
    case paused
    case assembling
    case verifying
    case completed
    case failed
    case cancelled
}

public struct DownloadTaskInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let destinationURL: URL
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var chunks: [DownloadChunkInfo]
    public var status: DownloadTaskStatus
    public var speedBytesPerSec: Double
    public var etaSeconds: TimeInterval?
    public var checksum: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        destinationURL: URL,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        chunks: [DownloadChunkInfo] = [],
        status: DownloadTaskStatus = .queued,
        speedBytesPerSec: Double = 0,
        etaSeconds: TimeInterval? = nil,
        checksum: String? = nil
    ) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.chunks = chunks
        self.status = status
        self.speedBytesPerSec = speedBytesPerSec
        self.etaSeconds = etaSeconds
        self.checksum = checksum
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }
}
