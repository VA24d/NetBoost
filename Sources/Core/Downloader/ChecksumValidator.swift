import Foundation
import CryptoKit

public enum ChecksumAlgorithm: String, Sendable, CaseIterable {
    case md5
    case sha1
    case sha256

    /// Auto-detects checksum algorithm based on hexadecimal string length.
    public static func detect(from hashString: String) -> ChecksumAlgorithm? {
        let trimmed = hashString.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.count {
        case 32: return .md5
        case 40: return .sha1
        case 64: return .sha256
        default: return nil
        }
    }
}

public protocol ChecksumValidatorProtocol: Sendable {
    func computeChecksum(for fileURL: URL, algorithm: ChecksumAlgorithm) async throws -> String
    func computeChecksum(for data: Data, algorithm: ChecksumAlgorithm) -> String
    func validate(fileURL: URL, expectedChecksum: String, algorithm: ChecksumAlgorithm?) async throws -> Bool
    func validate(data: Data, expectedChecksum: String, algorithm: ChecksumAlgorithm?) -> Bool
}

public struct ChecksumValidator: ChecksumValidatorProtocol {
    public init() {}

    public static func computeChecksum(for data: Data, algorithm: ChecksumAlgorithm) -> String {
        ChecksumValidator().computeChecksum(for: data, algorithm: algorithm)
    }

    public static func computeChecksum(for fileURL: URL, algorithm: ChecksumAlgorithm) async throws -> String {
        try await ChecksumValidator().computeChecksum(for: fileURL, algorithm: algorithm)
    }

    public static func validate(fileURL: URL, expectedChecksum: String, algorithm: ChecksumAlgorithm? = nil) async throws -> Bool {
        try await ChecksumValidator().validate(fileURL: fileURL, expectedChecksum: expectedChecksum, algorithm: algorithm)
    }

    public static func validate(data: Data, expectedChecksum: String, algorithm: ChecksumAlgorithm? = nil) -> Bool {
        ChecksumValidator().validate(data: data, expectedChecksum: expectedChecksum, algorithm: algorithm)
    }

    /// Computes lowercase hexadecimal checksum for in-memory Data.
    public func computeChecksum(for data: Data, algorithm: ChecksumAlgorithm) -> String {
        switch algorithm {
        case .md5:
            let digest = Insecure.MD5.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        case .sha1:
            let digest = Insecure.SHA1.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        case .sha256:
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Streams downloaded file from disk and calculates lowercase hex digest.
    public func computeChecksum(for fileURL: URL, algorithm: ChecksumAlgorithm) async throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let bufferSize = 65536 // 64KB chunk buffer

        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: bufferSize)
                guard let data = chunk, !data.isEmpty else { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()

        case .sha1:
            var hasher = Insecure.SHA1()
            while true {
                let chunk = try handle.read(upToCount: bufferSize)
                guard let data = chunk, !data.isEmpty else { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()

        case .md5:
            var hasher = Insecure.MD5()
            while true {
                let chunk = try handle.read(upToCount: bufferSize)
                guard let data = chunk, !data.isEmpty else { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Validates file against expected checksum case-insensitively.
    public func validate(fileURL: URL, expectedChecksum: String, algorithm: ChecksumAlgorithm? = nil) async throws -> Bool {
        let trimmed = expectedChecksum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let algo = algorithm ?? ChecksumAlgorithm.detect(from: trimmed) else {
            return false
        }
        let computed = try await computeChecksum(for: fileURL, algorithm: algo)
        return computed.caseInsensitiveCompare(trimmed) == .orderedSame
    }

    /// Validates data against expected checksum case-insensitively.
    public func validate(data: Data, expectedChecksum: String, algorithm: ChecksumAlgorithm? = nil) -> Bool {
        let trimmed = expectedChecksum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let algo = algorithm ?? ChecksumAlgorithm.detect(from: trimmed) else {
            return false
        }
        let computed = computeChecksum(for: data, algorithm: algo)
        return computed.caseInsensitiveCompare(trimmed) == .orderedSame
    }
}
