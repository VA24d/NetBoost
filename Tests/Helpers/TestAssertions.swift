import Foundation
import CryptoKit
import Network
import Darwin

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
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                let res = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                Darwin.close(fd)
                if res == 0 {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
