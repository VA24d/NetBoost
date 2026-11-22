import Foundation
import CryptoKit
import Network

public enum TestAssertions {

    /// Computes the lowercase hex SHA-256 digest of the given data.
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the lowercase hex SHA-1 digest of the given data.
    public static func sha1Hex(of data: Data) -> String {
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the lowercase hex MD5 digest of the given data.
    public static func md5Hex(of data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generates a reproducible pseudo-random byte buffer of the requested size.
    public static func generateDeterministicPayload(size: Int, pattern: [UInt8] = [0x4E, 0x65, 0x74, 0x42, 0x6F, 0x6F, 0x73, 0x74]) -> Data {
        guard size > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: size)
        let patLen = pattern.count
        for i in 0..<size {
            bytes[i] = pattern[i % patLen] ^ UInt8(i & 0xFF)
        }
        return Data(bytes)
    }

    /// Polls an asynchronous condition at regular intervals until it evaluates to true or times out.
    public static func pollUntil(
        timeout: TimeInterval = 5.0,
        interval: TimeInterval = 0.05,
        condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return try await condition()
    }

    /// Verifies if a local TCP port is reachable via loopback.
    public static func isLocalPortReachable(port: UInt16, timeout: TimeInterval = 2.0) async -> Bool {
        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var isResumed = false

            func resumeOnce(continuation: CheckedContinuation<Bool, Never>, returning value: Bool) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !isResumed else { return false }
                isResumed = true
                continuation.resume(returning: value)
                return true
            }
        }

        return await withCheckedContinuation { continuation in
            let guardBox = ResumeGuard()
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let params = NWParameters.tcp
            let connection = NWConnection(to: endpoint, using: params)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardBox.resumeOnce(continuation: continuation, returning: true) {
                        connection.cancel()
                    }
                case .failed, .cancelled:
                    if guardBox.resumeOnce(continuation: continuation, returning: false) {
                        connection.cancel()
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global())

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if guardBox.resumeOnce(continuation: continuation, returning: false) {
                    connection.cancel()
                }
            }
        }
    }
}
