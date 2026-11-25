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

    private static let streamBlockSize: Int = 65_536
    private static let progressIntervalSec: TimeInterval = 0.1
    private static let progressByteThreshold: Int64 = 262_144

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

    /// Concurrently streams the assigned byte slice directly to disk with incremental writes and exponential retry.
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

            let expectedRequestBytes = endByte - startByte + 1

            var request = URLRequest(url: url)
            request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 15.0

            do {
                currentChunk.status = .downloading

                let (asyncBytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    asyncBytes.task.cancel()
                    throw ChunkWorkerError.networkError("Invalid response type from server")
                }

                // Check for terminal 416 Range Not Satisfiable
                if httpResponse.statusCode == 416 {
                    asyncBytes.task.cancel()
                    currentChunk.status = .failed
                    throw ChunkWorkerError.rangeNotSatisfiable
                }

                // Check for rate limiting 429
                if httpResponse.statusCode == 429 {
                    asyncBytes.task.cancel()
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    let backoff = Self.calculateBackoff(retryAfterHeader: retryAfter, attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    attempt += 1
                    continue
                }

                if httpResponse.statusCode == 200 {
                    // Reject 200 OK when requesting a non-zero offset (server ignored Range and sent byte 0)
                    guard startByte == 0 else {
                        asyncBytes.task.cancel()
                        currentChunk.status = .failed
                        throw ChunkWorkerError.serverError(statusCode: 200)
                    }
                    // Also reject 200 OK if full response size does not match the chunk size
                    if httpResponse.expectedContentLength > 0 && httpResponse.expectedContentLength != expectedRequestBytes {
                        asyncBytes.task.cancel()
                        currentChunk.status = .failed
                        throw ChunkWorkerError.serverError(statusCode: 200)
                    }
                } else if httpResponse.statusCode != 206 {
                    asyncBytes.task.cancel()
                    if httpResponse.statusCode >= 500 && attempt < maxRetries {
                        let backoff = Self.calculateBackoff(retryAfterHeader: nil, attempt: attempt)
                        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                    currentChunk.status = .failed
                    throw ChunkWorkerError.serverError(statusCode: httpResponse.statusCode)
                }

                var blockBuffer: [UInt8] = []
                blockBuffer.reserveCapacity(Self.streamBlockSize)
                var writeOffset = startByte
                var receivedThisAttempt: Int64 = 0
                var bytesSinceProgress: Int64 = 0
                var lastProgressTime = Date()
                var smoothedSpeed = currentChunk.speedBytesPerSec

                for try await byte in asyncBytes {
                    if Task.isCancelled {
                        asyncBytes.task.cancel()
                        currentChunk.status = .pending
                        throw CancellationError()
                    }

                    if receivedThisAttempt >= expectedRequestBytes {
                        asyncBytes.task.cancel()
                        if httpResponse.statusCode == 200 {
                            currentChunk.status = .failed
                            throw ChunkWorkerError.serverError(statusCode: 200)
                        }
                        break
                    }

                    blockBuffer.append(byte)
                    receivedThisAttempt += 1

                    if blockBuffer.count >= Self.streamBlockSize {
                        let data = Data(blockBuffer)
                        try assembler.write(data: data, at: writeOffset)
                        let writtenCount = Int64(data.count)
                        writeOffset += writtenCount
                        currentChunk.downloadedBytes += writtenCount
                        bytesSinceProgress += writtenCount
                        blockBuffer.removeAll(keepingCapacity: true)

                        let now = Date()
                        let dt = now.timeIntervalSince(lastProgressTime)
                        if dt >= Self.progressIntervalSec || bytesSinceProgress >= Self.progressByteThreshold {
                            let instSpeed = Double(bytesSinceProgress) / max(0.001, dt)
                            smoothedSpeed = smoothedSpeed > 0 ? (0.2 * instSpeed + 0.8 * smoothedSpeed) : instSpeed
                            currentChunk.speedBytesPerSec = smoothedSpeed
                            onProgress?(currentChunk.id, currentChunk.downloadedBytes, smoothedSpeed)
                            lastProgressTime = now
                            bytesSinceProgress = 0
                        }
                    }
                }

                if !blockBuffer.isEmpty {
                    let data = Data(blockBuffer)
                    try assembler.write(data: data, at: writeOffset)
                    let writtenCount = Int64(data.count)
                    writeOffset += writtenCount
                    currentChunk.downloadedBytes += writtenCount
                    bytesSinceProgress += writtenCount
                    blockBuffer.removeAll()
                }

                if bytesSinceProgress > 0 {
                    let dt = max(0.001, Date().timeIntervalSince(lastProgressTime))
                    let instSpeed = Double(bytesSinceProgress) / dt
                    smoothedSpeed = smoothedSpeed > 0 ? (0.2 * instSpeed + 0.8 * smoothedSpeed) : instSpeed
                    currentChunk.speedBytesPerSec = smoothedSpeed
                    onProgress?(currentChunk.id, currentChunk.downloadedBytes, smoothedSpeed)
                }

                if currentChunk.downloadedBytes >= currentChunk.totalBytes {
                    currentChunk.status = .completed
                    return currentChunk
                }

                // Stream ended before chunk completed
                if attempt < maxRetries {
                    let backoff = Self.calculateBackoff(retryAfterHeader: nil, attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    attempt += 1
                } else {
                    currentChunk.status = .failed
                    throw ChunkWorkerError.networkError("Incomplete stream: received \(currentChunk.downloadedBytes) of \(currentChunk.totalBytes) bytes")
                }
            } catch is CancellationError {
                currentChunk.status = .pending
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    currentChunk.status = .pending
                    throw CancellationError()
                }

                if let workerErr = error as? ChunkWorkerError {
                    switch workerErr {
                    case .rangeNotSatisfiable, .serverError:
                        currentChunk.status = .failed
                        throw workerErr
                    case .cancelled:
                        currentChunk.status = .pending
                        throw CancellationError()
                    case .rateLimited, .networkError:
                        break
                    }
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
