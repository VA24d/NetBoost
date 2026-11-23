import Foundation

public protocol DownloadManagerProtocol: Sendable {
    func startDownload(url: URL, destination: URL, chunksCount: Int, expectedChecksum: String?) async throws -> DownloadTaskInfo
    func pauseDownload(id: UUID) async throws
    func resumeDownload(id: UUID) async throws
    func cancelDownload(id: UUID) async throws
    var taskPublisher: AsyncStream<DownloadTaskInfo> { get }
}

public enum SpeedMetricsCalculator {
    public static func calculateThroughput(bytes: Int64, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return Double(bytes) / duration
    }

    public static func calculateETA(totalBytes: Int64, downloadedBytes: Int64, speedBytesPerSec: Double) -> TimeInterval? {
        guard speedBytesPerSec > 0 else { return nil }
        let remaining = max(0, totalBytes - downloadedBytes)
        let eta = Double(remaining) / speedBytesPerSec
        guard !eta.isNaN && !eta.isInfinite else { return nil }
        return eta
    }

    public static func updateEMA(previousSpeed: Double, instantaneousSpeed: Double, alpha: Double = 0.2) -> Double {
        guard previousSpeed > 0 else { return instantaneousSpeed }
        return (alpha * instantaneousSpeed) + ((1.0 - alpha) * previousSpeed)
    }
}

public final class DownloadManager: DownloadManagerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: DownloadTaskInfo] = [:]
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var assemblers: [UUID: DiskAssembler] = [:]
    private var completions: [UUID: [CheckedContinuation<DownloadTaskInfo, any Error>]] = [:]
    private var continuation: AsyncStream<DownloadTaskInfo>.Continuation?

    public let taskPublisher: AsyncStream<DownloadTaskInfo>

    private let rangeProbe: RangeProbeProtocol
    private let session: URLSession

    public init(
        rangeProbe: RangeProbeProtocol? = nil,
        session: URLSession = .shared
    ) {
        self.session = session
        self.rangeProbe = rangeProbe ?? RangeProbe(session: session)

        var cont: AsyncStream<DownloadTaskInfo>.Continuation?
        self.taskPublisher = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    deinit {
        continuation?.finish()
    }

    public func getTask(id: UUID) -> DownloadTaskInfo? {
        lock.withLock { tasks[id] }
    }

    public func getAllTasks() -> [DownloadTaskInfo] {
        lock.withLock { Array(tasks.values) }
    }

    /// Enqueues and initiates a segmented multi-connection download.
    public func startDownload(
        url: URL,
        destination: URL,
        chunksCount: Int = 0,
        expectedChecksum: String? = nil
    ) async throws -> DownloadTaskInfo {
        let taskId = UUID()
        let initialTask = DownloadTaskInfo(
            id: taskId,
            url: url,
            destinationURL: destination,
            status: .probing,
            checksum: expectedChecksum
        )

        lock.withLock {
            tasks[taskId] = initialTask
        }
        continuation?.yield(initialTask)

        // Step 1: Capability Probe
        let probeResult: RangeProbeResult
        do {
            probeResult = try await rangeProbe.probe(url: url)
        } catch {
            var failedTask = initialTask
            failedTask.status = .failed
            lock.withLock {
                tasks[taskId] = failedTask
            }
            continuation?.yield(failedTask)
            throw error
        }

        let totalBytes = probeResult.contentLength
        let targetChunks = chunksCount > 0 ? chunksCount : probeResult.suggestedChunkCount
        let effectiveChunks = probeResult.supportsRanges ? targetChunks : 1

        // Step 2: Dynamic Chunk Partitioning
        let chunkInfos = ChunkPartitionEngine.partition(totalBytes: totalBytes, desiredChunks: effectiveChunks)

        // Step 3: Destination Path Resolution
        let finalDestinationURL: URL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue {
            finalDestinationURL = destination.appendingPathComponent(probeResult.filename)
        } else {
            finalDestinationURL = destination
        }

        // Step 4: Destination File Pre-allocation via DiskAssembler
        let assembler = DiskAssembler()
        do {
            try assembler.prepare(fileURL: finalDestinationURL, totalBytes: totalBytes)
        } catch {
            var failedTask = initialTask
            failedTask.status = .failed
            lock.withLock {
                tasks[taskId] = failedTask
            }
            continuation?.yield(failedTask)
            throw error
        }

        let activeTask = DownloadTaskInfo(
            id: taskId,
            url: url,
            destinationURL: finalDestinationURL,
            totalBytes: totalBytes,
            downloadedBytes: 0,
            chunks: chunkInfos,
            status: .downloading,
            checksum: expectedChecksum
        )

        lock.withLock {
            tasks[taskId] = activeTask
            assemblers[taskId] = assembler
        }
        continuation?.yield(activeTask)

        // Step 5: Launch concurrent worker streaming pipeline
        startPipeline(for: taskId)

        return activeTask
    }

    /// Convenience method that initiates a download and awaits its completion.
    public func downloadAndWait(
        url: URL,
        destination: URL,
        chunksCount: Int = 0,
        expectedChecksum: String? = nil,
        timeout: TimeInterval = 30.0
    ) async throws -> DownloadTaskInfo {
        let task = try await startDownload(
            url: url,
            destination: destination,
            chunksCount: chunksCount,
            expectedChecksum: expectedChecksum
        )
        return try await waitUntilCompleted(id: task.id, timeout: timeout)
    }

    /// Waits until a download task reaches a terminal state (completed, failed, cancelled).
    public func waitUntilCompleted(id: UUID, timeout: TimeInterval = 30.0) async throws -> DownloadTaskInfo {
        let existing = lock.withLock { tasks[id] }
        if let task = existing {
            if task.status == .completed { return task }
            if task.status == .failed {
                throw NSError(
                    domain: "DownloadManager",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "Download failed"]
                )
            }
            if task.status == .cancelled { throw CancellationError() }
        }

        return try await withThrowingTaskGroup(of: DownloadTaskInfo.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock {
                        if let task = self.tasks[id] {
                            if task.status == .completed {
                                continuation.resume(returning: task)
                                return
                            } else if task.status == .failed {
                                continuation.resume(throwing: NSError(
                                    domain: "DownloadManager",
                                    code: -6,
                                    userInfo: [NSLocalizedDescriptionKey: "Download failed"]
                                ))
                                return
                            } else if task.status == .cancelled {
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                        }
                        self.completions[id, default: []].append(continuation)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(
                    domain: "DownloadManager",
                    code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "Download timed out after \(timeout) seconds"]
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    public func pauseDownload(id: UUID) async throws {
        let (taskOpt, assemblerOpt) = lock.withLock { () -> (DownloadTaskInfo?, DiskAssembler?) in
            guard var task = tasks[id] else { return (nil, nil) }
            downloadTasks[id]?.cancel()
            downloadTasks.removeValue(forKey: id)

            task.status = .paused
            task.speedBytesPerSec = 0
            task.etaSeconds = nil
            for i in 0..<task.chunks.count {
                if task.chunks[i].status == .downloading {
                    task.chunks[i].status = .pending
                }
            }
            tasks[id] = task
            return (task, assemblers[id])
        }

        guard let task = taskOpt else {
            throw NSError(domain: "DownloadManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "Task not found"])
        }

        try? assemblerOpt?.flush()
        continuation?.yield(task)
    }

    public func resumeDownload(id: UUID) async throws {
        let shouldResume = lock.withLock { () -> Bool in
            guard var task = tasks[id] else { return false }
            guard task.status == .paused || task.status == .failed else { return false }

            task.status = .downloading
            for i in 0..<task.chunks.count {
                if task.chunks[i].status != .completed {
                    task.chunks[i].status = .pending
                }
            }
            tasks[id] = task

            if assemblers[id] == nil {
                let assembler = DiskAssembler()
                try? assembler.prepare(fileURL: task.destinationURL, totalBytes: task.totalBytes)
                assemblers[id] = assembler
            }
            return true
        }

        guard shouldResume else { return }

        if let task = getTask(id: id) {
            continuation?.yield(task)
        }
        startPipeline(for: id)
    }

    public func cancelDownload(id: UUID) async throws {
        let (taskOpt, assemblerOpt) = lock.withLock { () -> (DownloadTaskInfo?, DiskAssembler?) in
            guard var task = tasks[id] else { return (nil, nil) }
            downloadTasks[id]?.cancel()
            downloadTasks.removeValue(forKey: id)

            let asm = assemblers.removeValue(forKey: id)
            task.status = .cancelled
            task.speedBytesPerSec = 0
            task.etaSeconds = nil
            tasks[id] = task
            return (task, asm)
        }

        guard let task = taskOpt else {
            throw NSError(domain: "DownloadManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "Task not found"])
        }

        try? assemblerOpt?.close()
        continuation?.yield(task)
        notifyContinuations(taskId: id, result: .failure(CancellationError()))
    }

    // MARK: - Private Pipeline Execution

    private func startPipeline(for taskId: UUID) {
        let backgroundTask = Task { [weak self] in
            guard let self = self else { return }
            await self.executeDownloadPipeline(taskId: taskId)
        }
        lock.withLock {
            downloadTasks[taskId] = backgroundTask
        }
    }

    private func executeDownloadPipeline(taskId: UUID) async {
        let (taskOpt, assemblerOpt) = lock.withLock {
            (self.tasks[taskId], self.assemblers[taskId])
        }

        guard let task = taskOpt, let assembler = assemblerOpt else { return }

        // If totalBytes == 0, mark complete immediately
        if task.totalBytes == 0 {
            try? assembler.flush()
            try? assembler.close()
            var completedTask = task
            completedTask.status = .completed
            completedTask.speedBytesPerSec = 0
            completedTask.etaSeconds = 0
            lock.withLock {
                tasks[taskId] = completedTask
                assemblers.removeValue(forKey: taskId)
            }
            continuation?.yield(completedTask)
            notifyContinuations(taskId: taskId, result: .success(completedTask))
            return
        }

        let pendingChunks = task.chunks.filter { $0.status != .completed }

        do {
            try await withThrowingTaskGroup(of: DownloadChunkInfo.self) { group in
                for chunk in pendingChunks {
                    group.addTask {
                        let worker = ChunkWorker(
                            chunk: chunk,
                            url: task.url,
                            assembler: assembler,
                            session: self.session,
                            maxRetries: 3
                        ) { [weak self] chunkId, downloadedBytes, speed in
                            self?.updateChunkProgress(
                                taskId: taskId,
                                chunkId: chunkId,
                                downloadedBytes: downloadedBytes,
                                speed: speed
                            )
                        }
                        return try await worker.download()
                    }
                }

                for try await completedChunk in group {
                    self.updateChunkCompleted(taskId: taskId, chunk: completedChunk)
                }
            }

            let isInterrupted = lock.withLock { () -> Bool in
                guard let t = self.tasks[taskId] else { return true }
                return t.status == .paused || t.status == .cancelled
            }
            guard !isInterrupted else { return }

            // Flush & Close Assembler
            try assembler.flush()
            try assembler.close()

            // Verification Phase
            var currentTask = lock.withLock { self.tasks[taskId] } ?? task
            currentTask.status = .verifying
            lock.withLock {
                tasks[taskId] = currentTask
            }
            continuation?.yield(currentTask)

            if let expected = currentTask.checksum, !expected.isEmpty {
                let matches = try await ChecksumValidator.validate(
                    fileURL: currentTask.destinationURL,
                    expectedChecksum: expected
                )
                if !matches {
                    currentTask.status = .failed
                    currentTask.speedBytesPerSec = 0
                    currentTask.etaSeconds = nil
                    lock.withLock {
                        tasks[taskId] = currentTask
                        assemblers.removeValue(forKey: taskId)
                    }
                    continuation?.yield(currentTask)
                    notifyContinuations(
                        taskId: taskId,
                        result: .failure(NSError(
                            domain: "DownloadManager",
                            code: -4,
                            userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch verification failed"]
                        ))
                    )
                    return
                }
            }

            // Completion
            currentTask.status = .completed
            currentTask.downloadedBytes = currentTask.totalBytes
            currentTask.speedBytesPerSec = 0
            currentTask.etaSeconds = 0
            lock.withLock {
                tasks[taskId] = currentTask
                assemblers.removeValue(forKey: taskId)
            }
            continuation?.yield(currentTask)
            notifyContinuations(taskId: taskId, result: .success(currentTask))
        } catch is CancellationError {
            // Cancellation or pause handled by pauseDownload / cancelDownload
        } catch {
            var failedTask = lock.withLock { self.tasks[taskId] } ?? task
            failedTask.status = .failed
            failedTask.speedBytesPerSec = 0
            failedTask.etaSeconds = nil
            lock.withLock {
                tasks[taskId] = failedTask
                assemblers.removeValue(forKey: taskId)
            }
            continuation?.yield(failedTask)
            notifyContinuations(taskId: taskId, result: .failure(error))
        }
    }

    private func updateChunkProgress(taskId: UUID, chunkId: Int, downloadedBytes: Int64, speed: Double) {
        let taskOpt = lock.withLock { () -> DownloadTaskInfo? in
            guard var task = tasks[taskId], task.status == .downloading else {
                return nil
            }

            if let idx = task.chunks.firstIndex(where: { $0.id == chunkId }) {
                task.chunks[idx].downloadedBytes = downloadedBytes
                task.chunks[idx].speedBytesPerSec = speed
                task.chunks[idx].status = (downloadedBytes >= task.chunks[idx].totalBytes) ? .completed : .downloading
            }

            let totalDownloaded = task.chunks.reduce(0) { $0 + $1.downloadedBytes }
            task.downloadedBytes = totalDownloaded

            let instantaneousSpeed = task.chunks.reduce(0.0) { $0 + $1.speedBytesPerSec }
            let smoothedSpeed = SpeedMetricsCalculator.updateEMA(
                previousSpeed: task.speedBytesPerSec,
                instantaneousSpeed: instantaneousSpeed,
                alpha: 0.2
            )
            task.speedBytesPerSec = smoothedSpeed
            task.etaSeconds = SpeedMetricsCalculator.calculateETA(
                totalBytes: task.totalBytes,
                downloadedBytes: totalDownloaded,
                speedBytesPerSec: smoothedSpeed
            )

            tasks[taskId] = task
            return task
        }

        if let task = taskOpt {
            continuation?.yield(task)
        }
    }

    private func updateChunkCompleted(taskId: UUID, chunk: DownloadChunkInfo) {
        let taskOpt = lock.withLock { () -> DownloadTaskInfo? in
            guard var task = tasks[taskId] else { return nil }

            if let idx = task.chunks.firstIndex(where: { $0.id == chunk.id }) {
                task.chunks[idx] = chunk
            }

            let totalDownloaded = task.chunks.reduce(0) { $0 + $1.downloadedBytes }
            task.downloadedBytes = totalDownloaded

            tasks[taskId] = task
            return task
        }

        if let task = taskOpt {
            continuation?.yield(task)
        }
    }

    private func notifyContinuations(taskId: UUID, result: Result<DownloadTaskInfo, any Error>) {
        let waiting = lock.withLock {
            completions.removeValue(forKey: taskId) ?? []
        }

        for c in waiting {
            switch result {
            case .success(let task):
                c.resume(returning: task)
            case .failure(let error):
                c.resume(throwing: error)
            }
        }
    }
}
