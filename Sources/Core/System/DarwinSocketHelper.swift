import Foundation
import Darwin

public enum DarwinSocketError: Error, LocalizedError, Sendable, Equatable {
    case invalidFileDescriptor
    case interfaceNotFound(String)
    case socketCreationFailed(errno: Int32, message: String)
    case socketOptionFailed(errno: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileDescriptor:
            return "Invalid socket file descriptor"
        case .interfaceNotFound(let name):
            return "Network interface not found: \(name)"
        case .socketCreationFailed(let code, let msg):
            return "Failed to create socket (errno \(code)): \(msg)"
        case .socketOptionFailed(let code, let msg):
            return "Failed to set socket option (errno \(code)): \(msg)"
        }
    }
}

public final class DarwinSocketHelper: Sendable {

    /// Socket option constants on Darwin
    public static let IP_BOUND_IF: Int32 = 25          // IPPROTO_IP opt 25 on Darwin
    public static let IPV6_BOUND_IF: Int32 = 125       // IPPROTO_IPV6 opt 125 on Darwin
    public static let SO_BINDTODEVICE: Int32 = 0x1134  // SOL_SOCKET device binding where supported

    /// Looks up interface index from BSD name (e.g. "en0" -> 15).
    public static func getInterfaceIndex(for bsdName: String) -> UInt32? {
        let index = if_nametoindex(bsdName)
        guard index != 0 else { return nil }
        return index
    }

    /// Looks up BSD interface name from interface index (e.g. 15 -> "en0").
    public static func getInterfaceName(for index: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(index, &buffer) != nil else { return nil }
        return buffer.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    /// Creates a BSD socket.
    public static func createSocket(
        domain: Int32 = AF_INET,
        type: Int32 = SOCK_STREAM,
        protocol proto: Int32 = 0
    ) throws -> Int32 {
        let fd = socket(domain, type, proto)
        guard fd >= 0 else {
            let code = errno
            let msg = String(cString: strerror(code))
            throw DarwinSocketError.socketCreationFailed(errno: code, message: msg)
        }
        return fd
    }

    /// Closes a BSD socket.
    public static func closeSocket(fd: Int32) {
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
    }

    /// Binds an existing socket file descriptor to a specific interface index using IP_BOUND_IF.
    public static func bindSocket(fd: Int32, toInterfaceIndex index: UInt32) throws {
        guard fd >= 0 else {
            throw DarwinSocketError.invalidFileDescriptor
        }

        var interfaceIndex = index
        let len = socklen_t(MemoryLayout<UInt32>.size)

        // Try binding IPv4 (IPPROTO_IP opt IP_BOUND_IF)
        let v4Result = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex, len)
        if v4Result == 0 {
            return
        }

        // If IPv4 failed (e.g. socket is AF_INET6), try IPv6 (IPPROTO_IPV6 opt IPV6_BOUND_IF)
        let v6Result = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &interfaceIndex, len)
        if v6Result == 0 {
            return
        }

        let code = errno
        let msg = String(cString: strerror(code))
        throw DarwinSocketError.socketOptionFailed(errno: code, message: msg)
    }

    /// Binds an existing socket file descriptor to a named interface (e.g., "en0", "en10", "lo0").
    public static func bindSocket(fd: Int32, toInterface bsdName: String) throws {
        guard let index = getInterfaceIndex(for: bsdName) else {
            throw DarwinSocketError.interfaceNotFound(bsdName)
        }
        try bindSocket(fd: fd, toInterfaceIndex: index)
    }

    /// Queries the interface index currently bound to the socket using IP_BOUND_IF.
    public static func getBoundInterface(fd: Int32) throws -> UInt32 {
        guard fd >= 0 else {
            throw DarwinSocketError.invalidFileDescriptor
        }

        var interfaceIndex: UInt32 = 0
        var len = socklen_t(MemoryLayout<UInt32>.size)

        // Query IPv4 bound interface
        let v4Result = getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex, &len)
        if v4Result == 0 {
            return interfaceIndex
        }

        // Query IPv6 bound interface
        let v6Result = getsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &interfaceIndex, &len)
        if v6Result == 0 {
            return interfaceIndex
        }

        let code = errno
        let msg = String(cString: strerror(code))
        throw DarwinSocketError.socketOptionFailed(errno: code, message: msg)
    }

    public struct InterfaceByteCounters: Sendable, Equatable {
        public let inputBytes: UInt64
        public let outputBytes: UInt64

        public init(inputBytes: UInt64 = 0, outputBytes: UInt64 = 0) {
            self.inputBytes = inputBytes
            self.outputBytes = outputBytes
        }
    }

    /// Reads real-time hardware interface bytes (in and out) using Darwin getifaddrs
    public static func getInterfaceBytes(for bsdName: String? = nil) -> InterfaceByteCounters {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return InterfaceByteCounters(inputBytes: 0, outputBytes: 0)
        }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if !isLoopback {
                let name = String(cString: ptr.pointee.ifa_name)
                if bsdName == nil || name == bsdName {
                    if ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                        if let data = ptr.pointee.ifa_data {
                            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                            totalIn += UInt64(ifData.ifi_ibytes)
                            totalOut += UInt64(ifData.ifi_obytes)
                        }
                    }
                }
            }
            cursor = ptr.pointee.ifa_next
        }
        return InterfaceByteCounters(inputBytes: totalIn, outputBytes: totalOut)
    }

    /// Checks if a BSD network interface exists and has active flags (IFF_UP and IFF_RUNNING).
    public static func isInterfaceActive(_ bsdName: String) -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let name = String(cString: ptr.pointee.ifa_name)
            if name == bsdName {
                let flags = Int32(ptr.pointee.ifa_flags)
                let isUp = (flags & IFF_UP) != 0
                let isRunning = (flags & IFF_RUNNING) != 0
                if isUp && isRunning {
                    return true
                }
            }
            cursor = ptr.pointee.ifa_next
        }
        return false
    }
}
