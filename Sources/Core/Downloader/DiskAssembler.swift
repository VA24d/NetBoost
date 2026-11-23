import Foundation

public protocol DiskAssemblerProtocol: Sendable {
    func prepare(fileURL: URL, totalBytes: Int64) throws
    func write(data: Data, at offset: Int64) throws
    func flush() throws
    func close() throws
}

public final class DiskAssembler: DiskAssemblerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var destinationURL: URL?
    private var isPrepared = false

    public init() {}

    deinit {
        try? close()
    }

    /// Pre-allocates destination file on disk and initializes file handle for random-access writes.
    public func prepare(fileURL: URL, totalBytes: Int64) throws {
        lock.lock()
        defer { lock.unlock() }

        // Clean up any previously opened handle
        if let handle = fileHandle {
            try? handle.synchronize()
            try? handle.close()
            self.fileHandle = nil
        }

        self.destinationURL = fileURL

        let parentDir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // If file already exists, recreate it cleanly to avoid stale trailing bytes
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        let created = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard created else {
            throw NSError(
                domain: "DiskAssembler",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create destination file at \(fileURL.path)"]
            )
        }

        let handle = try FileHandle(forUpdating: fileURL)
        if totalBytes > 0 {
            try handle.truncate(atOffset: UInt64(totalBytes))
        }

        self.fileHandle = handle
        self.isPrepared = true
    }

    /// Thread-safe random-access write of byte block at specified offset.
    public func write(data: Data, at offset: Int64) throws {
        // Zero-byte write is a valid no-op
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let handle = fileHandle, isPrepared else {
            throw NSError(
                domain: "DiskAssembler",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "DiskAssembler has not been prepared for writing"]
            )
        }

        guard offset >= 0 else {
            throw NSError(
                domain: "DiskAssembler",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid negative write offset \(offset)"]
            )
        }

        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    /// Flushes disk write buffers.
    public func flush() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = fileHandle else { return }
        try handle.synchronize()
    }

    /// Flushes buffers and closes destination file.
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = fileHandle else { return }
        try handle.synchronize()
        try handle.close()
        self.fileHandle = nil
        self.isPrepared = false
    }
}
