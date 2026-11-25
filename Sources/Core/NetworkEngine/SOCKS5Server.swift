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
        while isRunning && !Task.isCancelled {
            let currentListenerFd = lock.withLock { listenerFd }
            guard currentListenerFd >= 0 else { break }

            guard let accepted = await ProxySocketIO.acceptNext(
                listenerFd: currentListenerFd,
                isRunning: { [weak self] in self?.isRunning ?? false }
            ) else {
                if !isRunning || Task.isCancelled { break }
                continue
            }

            let iface = targetInterface
            Task { [weak self] in
                await self?.handleClient(
                    clientFd: accepted.clientFd,
                    clientDesc: accepted.clientDesc,
                    interface: iface
                )
            }
        }
    }

    // MARK: - SOCKS5 Request Handling

    public func handleClient(clientFd: Int32, clientDesc: String, interface: String) async {
        await handleClient(
            clientFd: clientFd,
            clientDesc: clientDesc,
            interface: interface,
            onTargetConnected: nil,
            onBytesTransferred: nil
        )
    }

    internal func handleClient(
        clientFd: Int32,
        clientDesc: String,
        interface: String,
        onTargetConnected: (@Sendable (String, Int, ProxyProtocolType, Int32) -> Void)?,
        onBytesTransferred: (@Sendable (Int64, Int64) -> Void)?
    ) async {
        defer { Darwin.close(clientFd) }

        enum HandshakeOutcome {
            case connected(targetFd: Int32, targetHost: String, targetPort: Int)
            case failed
        }

        let outcome: HandshakeOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let greetingHeader = ProxySocketIO.readExact(fd: clientFd, count: 2) else {
                    continuation.resume(returning: .failed)
                    return
                }
                let version = greetingHeader[0]
                let nMethods = Int(greetingHeader[1])

                guard version == 0x05 else {
                    continuation.resume(returning: .failed)
                    return
                }

                guard nMethods > 0, let methods = ProxySocketIO.readExact(fd: clientFd, count: nMethods) else {
                    continuation.resume(returning: .failed)
                    return
                }

                let selectedMethod = Self.selectAuthMethod(offered: Array(methods))
                let greetingReply = Data([0x05, selectedMethod])
                guard ProxySocketIO.writeAll(fd: clientFd, data: greetingReply), selectedMethod == 0x00 else {
                    continuation.resume(returning: .failed)
                    return
                }

                guard let reqHeader = ProxySocketIO.readExact(fd: clientFd, count: 4) else {
                    continuation.resume(returning: .failed)
                    return
                }
                let reqVer = reqHeader[0]
                let cmd = reqHeader[1]
                let atyp = reqHeader[3]

                guard reqVer == 0x05 else {
                    continuation.resume(returning: .failed)
                    return
                }

                // Only CONNECT (0x01) is supported
                guard cmd == 0x01 else {
                    let reply = Self.makeReply(rep: 0x07, atyp: atyp == 0x04 ? 0x04 : 0x01)
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: reply)
                    continuation.resume(returning: .failed)
                    return
                }

                let targetHost: String
                let targetPort: Int

                switch atyp {
                case 0x01: // IPv4
                    guard let ipBytes = ProxySocketIO.readExact(fd: clientFd, count: 4),
                          let portBytes = ProxySocketIO.readExact(fd: clientFd, count: 2) else {
                        continuation.resume(returning: .failed)
                        return
                    }
                    targetHost = "\(ipBytes[0]).\(ipBytes[1]).\(ipBytes[2]).\(ipBytes[3])"
                    targetPort = Int((UInt16(portBytes[0]) << 8) | UInt16(portBytes[1]))

                case 0x03: // Domain Name
                    guard let lenByte = ProxySocketIO.readExact(fd: clientFd, count: 1),
                          let domainBytes = ProxySocketIO.readExact(fd: clientFd, count: Int(lenByte[0])),
                          let portBytes = ProxySocketIO.readExact(fd: clientFd, count: 2) else {
                        continuation.resume(returning: .failed)
                        return
                    }
                    targetHost = String(data: domainBytes, encoding: .utf8) ?? ""
                    targetPort = Int((UInt16(portBytes[0]) << 8) | UInt16(portBytes[1]))

                case 0x04: // IPv6
                    guard let ipBytes = ProxySocketIO.readExact(fd: clientFd, count: 16),
                          let portBytes = ProxySocketIO.readExact(fd: clientFd, count: 2) else {
                        continuation.resume(returning: .failed)
                        return
                    }
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
                    let reply = Self.makeReply(rep: 0x08, atyp: 0x01)
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: reply)
                    continuation.resume(returning: .failed)
                    return
                }

                guard !targetHost.isEmpty, (1...65535).contains(targetPort) else {
                    let reply = Self.makeReply(rep: 0x04, atyp: atyp == 0x04 ? 0x04 : 0x01)
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: reply)
                    continuation.resume(returning: .failed)
                    return
                }

                let connResult = self.connectOutbound(host: targetHost, port: targetPort, targetInterface: interface)
                switch connResult {
                case .failure(let repCode):
                    let reply = Self.makeReply(rep: repCode, atyp: atyp == 0x04 ? 0x04 : 0x01)
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: reply)
                    continuation.resume(returning: .failed)

                case .success(let targetFd):
                    let reply = Self.makeSuccessReply(atyp: atyp, targetFd: targetFd, fallbackPort: targetPort)
                    guard ProxySocketIO.writeAll(fd: clientFd, data: reply) else {
                        Darwin.close(targetFd)
                        continuation.resume(returning: .failed)
                        return
                    }
                    continuation.resume(returning: .connected(targetFd: targetFd, targetHost: targetHost, targetPort: targetPort))
                }
            }
        }

        guard case .connected(let targetFd, let targetHost, let targetPort) = outcome else {
            return
        }
        defer { Darwin.close(targetFd) }

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
        onTargetConnected?(targetHost, targetPort, .socks5, targetFd)

        defer {
            lock.withLock {
                _ = activeConns.removeValue(forKey: connId)
            }
        }

        await ProxySocketIO.streamAndTrack(
            clientFd: clientFd,
            targetFd: targetFd,
            recordBytes: { [weak self] readDelta, writeDelta in
                self?.recordBytes(connId: connId, readDelta: readDelta, writeDelta: writeDelta)
            },
            onBytesTransferred: onBytesTransferred
        )
    }

    private static func makeReply(rep: UInt8, atyp: UInt8, port: Int = 0) -> Data {
        let clampedPort = max(0, min(65535, port))
        let boundPort = UInt16(clampedPort)
        let portHi = UInt8((boundPort >> 8) & 0xFF)
        let portLo = UInt8(boundPort & 0xFF)

        if atyp == 0x04 {
            var data = Data([0x05, rep, 0x00, 0x04])
            data.append(contentsOf: [UInt8](repeating: 0, count: 16))
            data.append(contentsOf: [portHi, portLo])
            return data
        }
        return Data([0x05, rep, 0x00, 0x01, 0, 0, 0, 0, portHi, portLo])
    }

    private static func makeSuccessReply(atyp: UInt8, targetFd: Int32, fallbackPort: Int) -> Data {
        let clampedFallbackPort = UInt16(max(0, min(65535, fallbackPort)))
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let hasSockName = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(targetFd, sa, &len)
            }
        } == 0

        if atyp == 0x04 {
            var addrBytes = [UInt8](repeating: 0, count: 16)
            addrBytes[15] = 1 // ::1 fallback
            var replyPort = clampedFallbackPort

            if hasSockName && Int32(storage.ss_family) == AF_INET6 {
                let sin6 = withUnsafePointer(to: &storage) { ptr in
                    ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                }
                replyPort = UInt16(bigEndian: sin6.sin6_port)
                var rawAddr = sin6.sin6_addr
                withUnsafeBytes(of: &rawAddr) { bytes in
                    if bytes.count == 16 {
                        addrBytes = Array(bytes)
                    }
                }
            }

            var data = Data([0x05, 0x00, 0x00, 0x04])
            data.append(contentsOf: addrBytes)
            data.append(UInt8((replyPort >> 8) & 0xFF))
            data.append(UInt8(replyPort & 0xFF))
            return data
        }

        // Preserve 10-byte IPv4 reply shape for ATYP 0x01 and 0x03
        var addrBytes: [UInt8] = [127, 0, 0, 1]
        var replyPort = clampedFallbackPort

        if hasSockName && Int32(storage.ss_family) == AF_INET {
            let sin = withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            replyPort = UInt16(bigEndian: sin.sin_port)
            var rawAddr = sin.sin_addr.s_addr
            withUnsafeBytes(of: &rawAddr) { bytes in
                if bytes.count == 4 {
                    addrBytes = Array(bytes)
                }
            }
        }

        return Data([
            0x05, 0x00, 0x00, 0x01,
            addrBytes[0], addrBytes[1], addrBytes[2], addrBytes[3],
            UInt8((replyPort >> 8) & 0xFF),
            UInt8(replyPort & 0xFF)
        ])
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
        switch ProxySocketIO.connectOutbound(
            host: host,
            port: port,
            targetInterface: targetInterface,
            timeout: timeout
        ) {
        case .success(let fd):
            return .success(fd)
        case .failure(let err):
            return .failure(Self.mapPOSIXErrorToSOCKS5Reply(errno: err))
        }
    }

    // MARK: - Streaming & Helpers

    private func recordBytes(connId: UUID, readDelta: Int64, writeDelta: Int64) {
        lock.withLock {
            bytesReadCounter += readDelta
            bytesWrittenCounter += writeDelta
            if let existing = activeConns[connId] {
                let updated = ProxySocketIO.makeUpdatedConnectionInfo(existing.info, readDelta: readDelta, writeDelta: writeDelta)
                activeConns[connId] = (updated, existing.clientFd, existing.targetFd)
            }
        }
    }

    public static func pump(from srcFd: Int32, to dstFd: Int32, bufferSize: Int = 32768) -> Int64 {
        ProxySocketIO.pump(from: srcFd, to: dstFd, bufferSize: bufferSize)
    }
}
