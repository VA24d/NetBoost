import Foundation
import Darwin

public final class SOCKS5Server: @unchecked Sendable {
    public let port: Int
    public let targetInterface: String
    public var fallbackIfInterfaceUnavailable: Bool = true

    private let lock = NSLock()
    private var listenerFd: Int32 = -1
    private var actualBoundPort: Int = 0
    private var isRunningInternal: Bool = false
    private var acceptTask: Task<Void, Never>?
    private var activeConns: [UUID: (info: ProxyConnectionInfo, clientFd: Int32, targetFd: Int32)] = [:]
    private var bytesReadCounter: Int64 = 0
    private var bytesWrittenCounter: Int64 = 0

    public var isRunning: Bool {
        lock.withLock { isRunningInternal }
    }

    public var boundPort: Int {
        lock.withLock { actualBoundPort > 0 ? actualBoundPort : port }
    }

    public var activeConnections: [ProxyConnectionInfo] {
        lock.withLock { activeConns.values.map(\.info) }
    }

    public var totalBytesRead: Int64 {
        lock.withLock { bytesReadCounter }
    }

    public var totalBytesWritten: Int64 {
        lock.withLock { bytesWrittenCounter }
    }

    public init(port: Int, targetInterface: String = "en10") {
        self.port = port
        self.targetInterface = targetInterface
    }

    deinit {
        stop()
    }

    // MARK: - Protocol Helpers

    public static func validateVersion(_ version: UInt8) -> Bool {
        version == 0x05
    }

    public static func selectAuthMethod(offered: [UInt8]) -> UInt8 {
        offered.contains(0x00) ? 0x00 : 0xFF
    }

    public static func parseAddressType(_ b: UInt8) -> String? {
        switch b {
        case 0x01: return "IPv4"
        case 0x03: return "Domain"
        case 0x04: return "IPv6"
        default: return nil
        }
    }

    public static func mapPOSIXErrorToSOCKS5Reply(errno: Int32) -> UInt8 {
        switch errno {
        case ENETUNREACH: return 0x03 // Network unreachable
        case EHOSTUNREACH: return 0x04 // Host unreachable
        case ECONNREFUSED: return 0x05 // Connection refused
        case ETIMEDOUT: return 0x06 // TTL expired / Timeout
        default: return 0x01 // General server failure
        }
    }

    // MARK: - Server Lifecycle

    public func start() async throws {
        try lock.withLock {
            guard !isRunningInternal else { return }

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                let err = errno
                throw ProxyError.bindFailed(port: port, errno: err)
            }

            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindRes != 0 {
                let err = errno
                Darwin.close(fd)
                if err == EADDRINUSE {
                    throw ProxyError.portAlreadyInUse(port)
                } else {
                    throw ProxyError.bindFailed(port: port, errno: err)
                }
            }

            guard Darwin.listen(fd, 128) == 0 else {
                let err = errno
                Darwin.close(fd)
                throw ProxyError.bindFailed(port: port, errno: err)
            }

            var boundAddr = sockaddr_in()
            var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let getSockRes = withUnsafeMutablePointer(to: &boundAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &boundLen)
                }
            }
            if getSockRes == 0 {
                self.actualBoundPort = Int(UInt16(bigEndian: boundAddr.sin_port))
            } else {
                self.actualBoundPort = port
            }

            self.listenerFd = fd
            self.isRunningInternal = true
        }

        acceptTask = Task { [weak self] in
            await self?.runAcceptLoop()
        }
    }

    public func stop() {
        var connsToClose: [(clientFd: Int32, targetFd: Int32)] = []
        let fdToClose: Int32 = lock.withLock {
            isRunningInternal = false
            let fd = listenerFd
            listenerFd = -1
            connsToClose = activeConns.values.map { ($0.clientFd, $0.targetFd) }
            activeConns.removeAll()
            return fd
        }

        if fdToClose >= 0 {
            Darwin.close(fdToClose)
        }

        for conn in connsToClose {
            if conn.clientFd >= 0 {
                _ = Darwin.shutdown(conn.clientFd, SHUT_RDWR)
            }
            if conn.targetFd >= 0 {
                _ = Darwin.shutdown(conn.targetFd, SHUT_RDWR)
            }
        }

        acceptTask?.cancel()
        acceptTask = nil
    }

    // MARK: - Connection Loop

    private func runAcceptLoop() async {
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenerFd, sa, &clientAddrLen)
                }
            }

            guard clientFd >= 0 else {
                if !isRunning { break }
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continue
                }
                break
            }

            // Clear O_NONBLOCK inherited from listener so client socket has blocking I/O with timeouts
            let clientFlags = fcntl(clientFd, F_GETFL, 0)
            _ = fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK)

            var one: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var tv = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let clientIP = String(cString: inet_ntoa(clientAddr.sin_addr))
            let clientPort = Int(UInt16(bigEndian: clientAddr.sin_port))
            let clientDesc = "\(clientIP):\(clientPort)"

            Task { [weak self] in
                await self?.handleClient(clientFd: clientFd, clientDesc: clientDesc, interface: self?.targetInterface ?? "en10")
            }
        }
    }

    // MARK: - SOCKS5 Request Handling

    public func handleClient(clientFd: Int32, clientDesc: String, interface: String) async {
        defer { Darwin.close(clientFd) }

        // 1. Handshake greeting
        guard let greetingHeader = readExact(fd: clientFd, count: 2) else { return }
        let version = greetingHeader[0]
        let nMethods = Int(greetingHeader[1])

        guard version == 0x05 else {
            // SOCKS4 or invalid version
            return
        }

        guard nMethods > 0, let methods = readExact(fd: clientFd, count: nMethods) else {
            return
        }

        let selectedMethod = Self.selectAuthMethod(offered: Array(methods))
        let greetingReply = Data([0x05, selectedMethod])
        guard writeAll(fd: clientFd, data: greetingReply) else { return }

        guard selectedMethod == 0x00 else {
            // No acceptable auth method
            return
        }

        // 2. Client Request Frame
        guard let reqHeader = readExact(fd: clientFd, count: 4) else { return }
        let reqVer = reqHeader[0]
        let cmd = reqHeader[1]
        let atyp = reqHeader[3]

        guard reqVer == 0x05 else { return }

        // Only CONNECT (0x01) is supported
        guard cmd == 0x01 else {
            let reply = Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            _ = writeAll(fd: clientFd, data: reply)
            return
        }

        // Parse target host & port
        let targetHost: String
        let targetPort: Int

        switch atyp {
        case 0x01: // IPv4
            guard let ipBytes = readExact(fd: clientFd, count: 4),
                  let portBytes = readExact(fd: clientFd, count: 2) else { return }
            targetHost = "\(ipBytes[0]).\(ipBytes[1]).\(ipBytes[2]).\(ipBytes[3])"
            targetPort = Int((UInt16(portBytes[0]) << 8) | UInt16(portBytes[1]))

        case 0x03: // Domain Name
            guard let lenByte = readExact(fd: clientFd, count: 1),
                  let domainBytes = readExact(fd: clientFd, count: Int(lenByte[0])),
                  let portBytes = readExact(fd: clientFd, count: 2) else { return }
            targetHost = String(data: domainBytes, encoding: .utf8) ?? ""
            targetPort = Int((UInt16(portBytes[0]) << 8) | UInt16(portBytes[1]))

        case 0x04: // IPv6
            guard let ipBytes = readExact(fd: clientFd, count: 16),
                  let portBytes = readExact(fd: clientFd, count: 2) else { return }
            var sin6 = in6_addr()
            _ = ipBytes.withUnsafeBytes { ptr in
                memcpy(&sin6, ptr.baseAddress!, 16)
            }
            var strBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = inet_ntop(AF_INET6, &sin6, &strBuf, socklen_t(INET6_ADDRSTRLEN))
            targetHost = strBuf.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? ""
            }
            targetPort = Int((UInt16(portBytes[0]) << 8) | UInt16(portBytes[1]))

        default:
            let reply = Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            _ = writeAll(fd: clientFd, data: reply)
            return
        }

        // 3. Connect to Outbound Target with Interface Binding
        let connResult = connectOutbound(host: targetHost, port: targetPort, targetInterface: interface)
        switch connResult {
        case .failure(let repCode):
            let reply = Data([0x05, repCode, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            _ = writeAll(fd: clientFd, data: reply)
            return

        case .success(let targetFd):
            defer { Darwin.close(targetFd) }

            // Reply Success: 0x05, 0x00, 0x00, 0x01, BND.ADDR (127.0.0.1), BND.PORT
            let boundPort = UInt16(targetPort)
            let portHi = UInt8((boundPort >> 8) & 0xFF)
            let portLo = UInt8(boundPort & 0xFF)
            let reply = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, portHi, portLo])
            guard writeAll(fd: clientFd, data: reply) else { return }

            // Track connection
            let connId = UUID()
            let connInfo = ProxyConnectionInfo(
                id: connId,
                port: port,
                clientAddress: clientDesc,
                targetHost: targetHost,
                targetPort: targetPort,
                egressInterface: interface,
                protocolType: .socks5
            )

            lock.withLock {
                activeConns[connId] = (connInfo, clientFd, targetFd)
            }

            defer {
                lock.withLock {
                    _ = activeConns.removeValue(forKey: connId)
                }
            }

            // 4. Bi-directional raw streaming
            await streamBidirectional(clientFd: clientFd, targetFd: targetFd)
        }
    }

    public enum OutboundConnectResult {
        case success(Int32)
        case failure(UInt8)
    }

    public func connectOutbound(
        host: String,
        port: Int,
        targetInterface: String,
        timeout: TimeInterval = 5.0
    ) -> OutboundConnectResult {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let gaiStatus = getaddrinfo(host, portStr, &hints, &res)
        guard gaiStatus == 0, let addrList = res else {
            return .failure(0x04) // Host unreachable
        }
        defer { freeaddrinfo(res) }

        var ptr: UnsafeMutablePointer<addrinfo>? = addrList
        var lastErr: Int32 = ECONNREFUSED
        var connectedFd: Int32 = -1

        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host.hasPrefix("127.")

        while let current = ptr {
            let info = current.pointee
            ptr = current.pointee.ai_next

            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else {
                lastErr = errno
                continue
            }

            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            // Interface binding
            if !isLoopback && !targetInterface.isEmpty && targetInterface != "auto" && targetInterface != "any" {
                if let ifIdx = DarwinSocketHelper.getInterfaceIndex(for: targetInterface) {
                    _ = try? DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: ifIdx)
                }
            } else if targetInterface == "lo0" {
                if let loIdx = DarwinSocketHelper.getInterfaceIndex(for: "lo0") {
                    _ = try? DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIdx)
                }
            }

            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let connRes = Darwin.connect(fd, info.ai_addr, info.ai_addrlen)
            if connRes == 0 {
                connectedFd = fd
                break
            } else {
                lastErr = errno
                Darwin.close(fd)
            }
        }

        if connectedFd >= 0 {
            return .success(connectedFd)
        } else {
            let rep = Self.mapPOSIXErrorToSOCKS5Reply(errno: lastErr)
            return .failure(rep)
        }
    }

    // MARK: - Streaming & Helpers

    private func streamBidirectional(clientFd: Int32, targetFd: Int32) async {
        await withTaskGroup(of: Int64.self) { group in
            // Client -> Target
            group.addTask {
                let bytes = Self.pump(from: clientFd, to: targetFd)
                _ = shutdown(targetFd, SHUT_WR)
                return bytes
            }

            // Target -> Client
            group.addTask {
                let bytes = Self.pump(from: targetFd, to: clientFd)
                _ = shutdown(clientFd, SHUT_WR)
                return bytes
            }

            var totalClientToTarget: Int64 = 0
            var totalTargetToClient: Int64 = 0
            for await bytes in group {
                if totalClientToTarget == 0 {
                    totalClientToTarget = bytes
                } else {
                    totalTargetToClient = bytes
                }
            }

            lock.withLock {
                bytesReadCounter += totalClientToTarget
                bytesWrittenCounter += totalTargetToClient
            }
        }
    }

    public static func pump(from srcFd: Int32, to dstFd: Int32, bufferSize: Int = 32768) -> Int64 {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var total: Int64 = 0

        while true {
            let n = Darwin.read(srcFd, &buffer, bufferSize)
            guard n > 0 else { break }

            var written = 0
            var writeFailed = false
            while written < n {
                let bytesToWrite = n - written
                let w = buffer.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.write(dstFd, base.advanced(by: written), bytesToWrite)
                }
                if w <= 0 {
                    writeFailed = true
                    break
                }
                written += w
            }
            if writeFailed { break }
            total += Int64(n)
        }
        return total
    }

    private func readExact(fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var bytesRead = 0
        while bytesRead < count {
            let n = data.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: bytesRead), count - bytesRead)
            }
            if n <= 0 { return nil }
            bytesRead += n
        }
        return data
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var bytesWritten = 0
        let total = data.count
        while bytesWritten < total {
            let n = data.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: bytesWritten), total - bytesWritten)
            }
            if n <= 0 { return false }
            bytesWritten += n
        }
        return true
    }
}
