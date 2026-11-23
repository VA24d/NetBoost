import Foundation

public enum ChunkWorkerError: Error, Sendable, Equatable {
    case rangeNotSatisfiable
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int)
    case cancelled
    case networkError(String)
}

public final class ChunkWorker: @unchecked Sendable {
    public let chunk: DownloadChunkInfo
    public let url: URL
    public let assembler: DiskAssemblerProtocol
    public let session: URLSession
    public let maxRetries: Int
    public var onProgress: (@Sendable (Int, Int64, Double) -> Void)?

    public init(
        chunk: DownloadChunkInfo,
        url: URL,
        assembler: DiskAssemblerProtocol,
        session: URLSession = .shared,
        maxRetries: Int = 3,
        onProgress: (@Sendable (Int, Int64, Double) -> Void)? = nil
    ) {
        self.chunk = chunk
        self.url = url
        self.assembler = assembler
        self.session = session
        self.maxRetries = maxRetries
        self.onProgress = onProgress
    }

    /// Calculates exponential backoff with Retry-After header consideration.
    public static func calculateBackoff(retryAfterHeader: String?, attempt: Int) -> TimeInterval {
        if let header = retryAfterHeader, let seconds = Double(header) {
            return seconds
        }
        return min(30.0, 1.0 * pow(2.0, Double(attempt)))
    }

    /// Constructs standard Range request header for resuming chunk.
    public static func makeResumeRange(chunk: DownloadChunkInfo) -> String {
        let nextByte = chunk.rangeStart + chunk.downloadedBytes
        return "bytes=\(nextByte)-\(chunk.rangeEnd)"
    }

    /// Concurrently downloads the assigned byte slice directly to disk with exponential retry.
    public func download() async throws -> DownloadChunkInfo {
        var currentChunk = chunk
        var attempt = 0

        while currentChunk.downloadedBytes < currentChunk.totalBytes {
            if Task.isCancelled {
                currentChunk.status = .pending
                throw CancellationError()
            }

            let startByte = currentChunk.rangeStart + currentChunk.downloadedBytes
            let endByte = currentChunk.rangeEnd

            if startByte > endByte {
                currentChunk.status = .completed
                return currentChunk
            }

            var request = URLRequest(url: url)
            request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 10.0

            let startTime = Date()
            do {
                currentChunk.status = .downloading

                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ChunkWorkerError.networkError("Invalid response type from server")
                }

                // Check for terminal 416 Range Not Satisfiable
                if httpResponse.statusCode == 416 {
                    currentChunk.status = .failed
                    throw ChunkWorkerError.rangeNotSatisfiable
                }

                // Check for rate limiting 429
                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    let backoff = Self.calculateBackoff(retryAfterHeader: retryAfter, attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    attempt += 1
                    continue
                }

                guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                    if httpResponse.statusCode >= 500 && attempt < maxRetries {
                        let backoff = Self.calculateBackoff(retryAfterHeader: nil, attempt: attempt)
                        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                    currentChunk.status = .failed
                    throw ChunkWorkerError.serverError(statusCode: httpResponse.statusCode)
                }

                // Zero-copy direct write into pre-allocated file at start offset
                try assembler.write(data: data, at: startByte)

                let duration = max(0.001, Date().timeIntervalSince(startTime))
                let speed = Double(data.count) / duration

                currentChunk.downloadedBytes += Int64(data.count)
                currentChunk.speedBytesPerSec = speed
                onProgress?(currentChunk.id, currentChunk.downloadedBytes, speed)

                if currentChunk.downloadedBytes >= currentChunk.totalBytes {
                    currentChunk.status = .completed
                    return currentChunk
                }
            } catch is CancellationError {
                currentChunk.status = .pending
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    currentChunk.status = .pending
                    throw CancellationError()
                }

                if let workerErr = error as? ChunkWorkerError, workerErr == .rangeNotSatisfiable {
                    currentChunk.status = .failed
                    throw workerErr
                }

                if attempt < maxRetries {
                    let backoff = Self.calculateBackoff(retryAfterHeader: nil, attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    attempt += 1
                    continue
                } else {
                    currentChunk.status = .failed
                    throw error
                }
            }
        }

        currentChunk.status = .completed
        return currentChunk
    }
}
