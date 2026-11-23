import Foundation
import Darwin

public final class HTTPProxyServer: @unchecked Sendable {
    public static let maxHeaderSize: Int = 65536 // 64 KB limit

    public enum RequestType: Equatable, Sendable {
        case connect(host: String, port: Int)
        case standard(method: String, url: String, keepAlive: Bool)
        case invalid
    }

    public enum OutboundConnectResult {
        case success(Int32)
        case failure(String)
    }

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

    // MARK: - Protocol Parsing & Formatting Helpers

    public static func parseRequest(_ raw: String) -> RequestType {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .invalid }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return .invalid }

        let method = parts[0].uppercased()
        let target = parts[1]

        if method == "CONNECT" {
            guard !target.hasPrefix(":"), !target.hasSuffix(":") else { return .invalid }
            let hostPort = target.split(separator: ":")
            guard let hostSub = hostPort.first, !hostSub.isEmpty else { return .invalid }
            let host = String(hostSub)
            let port: Int
            if hostPort.count > 1 {
                guard let parsedPort = Int(hostPort[1]), parsedPort >= 1 && parsedPort <= 65535 else {
                    return .invalid
                }
                port = parsedPort
            } else {
                port = 443
            }
            return .connect(host: host, port: port)
        } else {
            guard !target.isEmpty else { return .invalid }
            let keepAlive = lines.contains { line in
                let lower = line.lowercased()
                return lower.hasPrefix("proxy-connection: keep-alive") || lower.hasPrefix("connection: keep-alive")
            }
            return .standard(method: method, url: target, keepAlive: keepAlive)
        }
    }

    public static func makeConnectSuccessResponse() -> String {
        "HTTP/1.1 200 Connection Established\r\nProxy-Agent: NetBoost/1.0\r\n\r\n"
    }

    public static func makeBadRequestResponse() -> String {
        "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nBad Request\n"
    }

    public static func makeGatewayTimeoutResponse(message: String = "Gateway Timeout") -> String {
        "HTTP/1.1 504 Gateway Timeout\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n\(message)\n"
    }

    public static func makePayloadTooLargeResponse() -> String {
        "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nHeader Too Large\n"
    }

    // MARK: - Lifecycle

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

    // MARK: - Accept Loop

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

    // MARK: - Client Request Handling

    public func handleClient(clientFd: Int32, clientDesc: String, interface: String) async {
        defer { Darwin.close(clientFd) }

        // Read HTTP headers (enforcing 64KB max header size)
        var headerData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var delimiterRange: Range<Data.Index>? = nil
        let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        while headerData.count < Self.maxHeaderSize {
            let n = Darwin.read(clientFd, &buffer, buffer.count)
            guard n > 0 else { break }

            headerData.append(buffer, count: n)
            if let range = headerData.range(of: delimiter) {
                delimiterRange = range
                break
            }
        }

        if headerData.count >= Self.maxHeaderSize && delimiterRange == nil {
            let resp = Self.makePayloadTooLargeResponse()
            _ = writeAll(fd: clientFd, data: Data(resp.utf8))
            return
        }

        guard let rawHeaderString = String(data: headerData, encoding: .utf8) else {
            let resp = Self.makeBadRequestResponse()
            _ = writeAll(fd: clientFd, data: Data(resp.utf8))
            return
        }

        let parsed = Self.parseRequest(rawHeaderString)

        switch parsed {
        case .invalid:
            let resp = Self.makeBadRequestResponse()
            _ = writeAll(fd: clientFd, data: Data(resp.utf8))
            return

        case .connect(let host, let port):
            await handleConnect(
                clientFd: clientFd,
                clientDesc: clientDesc,
                host: host,
                port: port,
                interface: interface
            )

        case .standard(let method, let urlStr, let keepAlive):
            await handleStandardRequest(
                clientFd: clientFd,
                clientDesc: clientDesc,
                method: method,
                urlStr: urlStr,
                keepAlive: keepAlive,
                rawHeaderString: rawHeaderString,
                headerData: headerData,
                delimiterRange: delimiterRange,
                interface: interface
            )
        }
    }

    // MARK: - CONNECT Tunneling Mode

    private func handleConnect(
        clientFd: Int32,
        clientDesc: String,
        host: String,
        port: Int,
        interface: String
    ) async {
        let connResult = connectOutbound(host: host, port: port, targetInterface: interface)
        switch connResult {
        case .failure(let errMsg):
            let resp = Self.makeGatewayTimeoutResponse(message: "Gateway Timeout: \(errMsg)")
            _ = writeAll(fd: clientFd, data: Data(resp.utf8))
            return

        case .success(let targetFd):
            defer { Darwin.close(targetFd) }

            let successResponse = Self.makeConnectSuccessResponse()
            guard writeAll(fd: clientFd, data: Data(successResponse.utf8)) else { return }

            let connId = UUID()
            let connInfo = ProxyConnectionInfo(
                id: connId,
                port: self.port,
                clientAddress: clientDesc,
                targetHost: host,
                targetPort: port,
                egressInterface: interface,
                protocolType: .httpConnect
            )

            lock.withLock {
                activeConns[connId] = (connInfo, clientFd, targetFd)
            }

            defer {
                lock.withLock {
                    _ = activeConns.removeValue(forKey: connId)
                }
            }

            // Stream raw bytes bidirectionally
            await streamBidirectional(clientFd: clientFd, targetFd: targetFd)
        }
    }

    // MARK: - Direct GET/POST Request Mode

    private func handleStandardRequest(
        clientFd: Int32,
        clientDesc: String,
        method: String,
        urlStr: String,
        keepAlive: Bool,
        rawHeaderString: String,
        headerData: Data,
        delimiterRange: Range<Data.Index>?,
        interface: String
    ) async {
        guard let url = URL(string: urlStr), let host = url.host else {
            let resp = Self.makeBadRequestResponse()
            _ = writeAll(fd: clientFd, data: Data(resp.utf8))
            return
        }

        let targetPort = url.port ?? (url.scheme == "https" ? 443 : 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query {
            path += "?\(query)"
        }

        // Rewrite headers: rewrite request line to origin-form, drop Proxy-Connection
        var lines = rawHeaderString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            let resp = Self.makeBadRequestResponse()
            _ = writeAll(fd: clientFd, data: Data(resp.utf8))
            return
        }

        lines[0] = "\(method) \(path) HTTP/1.1"

        var filteredLines: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("proxy-connection:") {
                filteredLines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
            } else if lower.hasPrefix("proxy-") {
                continue // Drop other proxy headers
            } else {
                filteredLines.append(line)
            }
        }

        let rewrittenHeaders = filteredLines.joined(separator: "\r\n")
        var outgoingData = Data(rewrittenHeaders.utf8)

        // If client sent body data along with headers
        if let dRange = delimiterRange, dRange.upperBound < headerData.count {
            let extra = headerData.subdata(in: dRange.upperBound..<headerData.count)
            outgoingData.append(extra)
        }

        let connResult = connectOutbound(host: host, port: targetPort, targetInterface: interface)
        switch connResult {
        case .failure(let errMsg):
            let resp = Self.makeGatewayTimeoutResponse(message: "Gateway Timeout: \(errMsg)")
            _ = writeAll(fd: clientFd, data: Data(resp.utf8))
            return

        case .success(let targetFd):
            defer { Darwin.close(targetFd) }

            guard writeAll(fd: targetFd, data: outgoingData) else { return }

            let connId = UUID()
            let connInfo = ProxyConnectionInfo(
                id: connId,
                port: self.port,
                clientAddress: clientDesc,
                targetHost: host,
                targetPort: targetPort,
                egressInterface: interface,
                protocolType: .httpDirect
            )

            lock.withLock {
                activeConns[connId] = (connInfo, clientFd, targetFd)
            }

            defer {
                lock.withLock {
                    _ = activeConns.removeValue(forKey: connId)
                }
            }

            // Stream response back from target to client
            await streamBidirectional(clientFd: clientFd, targetFd: targetFd)
        }
    }

    // MARK: - Outbound Connection

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
            return .failure("DNS resolution failed for \(host)")
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
            let msg = String(cString: strerror(lastErr))
            return .failure("Connection refused or timed out: \(msg)")
        }
    }

    // MARK: - Streaming & Helpers

    private func streamBidirectional(clientFd: Int32, targetFd: Int32) async {
        await withTaskGroup(of: Int64.self) { group in
            group.addTask {
                let bytes = SOCKS5Server.pump(from: clientFd, to: targetFd)
                _ = shutdown(targetFd, SHUT_WR)
                return bytes
            }

            group.addTask {
                let bytes = SOCKS5Server.pump(from: targetFd, to: clientFd)
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
