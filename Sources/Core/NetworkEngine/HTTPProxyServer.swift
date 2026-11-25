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
            if target.hasPrefix("[") {
                guard let closeBracket = target.firstIndex(of: "]") else { return .invalid }
                let host = String(target[target.index(after: target.startIndex)..<closeBracket])
                guard !host.isEmpty else { return .invalid }

                let remainder = target[target.index(after: closeBracket)...]
                let port: Int
                if remainder.isEmpty {
                    port = 443
                } else if remainder.hasPrefix(":") {
                    let portStr = remainder.dropFirst()
                    guard !portStr.isEmpty,
                          let parsedPort = Int(portStr),
                          (1...65535).contains(parsedPort) else {
                        return .invalid
                    }
                    port = parsedPort
                } else {
                    return .invalid
                }
                return .connect(host: host, port: port)
            }

            guard !target.contains("["), !target.contains("]"),
                  !target.hasPrefix(":"), !target.hasSuffix(":") else {
                return .invalid
            }
            let hostPort = target.split(separator: ":", omittingEmptySubsequences: false)
            guard let hostSub = hostPort.first, !hostSub.isEmpty else { return .invalid }
            guard hostPort.count <= 2 else { return .invalid }
            let host = String(hostSub)
            let port: Int
            if hostPort.count == 2 {
                guard let parsedPort = Int(hostPort[1]), (1...65535).contains(parsedPort) else {
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

    // MARK: - Client Request Handling

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
        ProxySocketIO.setHandshakeTimeouts(fd: clientFd, seconds: 15)

        enum HeaderReadOutcome {
            case parsed(RequestType, headerString: String, extraBodyData: Data)
            case finished
        }

        let outcome: HeaderReadOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var rawBuffer = Data()
                var readBuf = [UInt8](repeating: 0, count: 1024)
                var delimiterRange: Range<Data.Index>? = nil
                let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

                while rawBuffer.count < Self.maxHeaderSize {
                    let n = Darwin.read(clientFd, &readBuf, readBuf.count)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { break }

                    rawBuffer.append(readBuf, count: n)
                    if let range = rawBuffer.range(of: delimiter) {
                        delimiterRange = range
                        break
                    }
                }

                if rawBuffer.count >= Self.maxHeaderSize && delimiterRange == nil {
                    Self.finishClientRejection(fd: clientFd, response: Self.makePayloadTooLargeResponse())
                    continuation.resume(returning: .finished)
                    return
                }

                guard let dRange = delimiterRange else {
                    if !rawBuffer.isEmpty {
                        Self.finishClientRejection(fd: clientFd, response: Self.makeBadRequestResponse())
                    }
                    continuation.resume(returning: .finished)
                    return
                }

                // Split BEFORE UTF-8 decoding so arbitrary binary POST payloads are preserved intact
                let headerOnlyBytes = rawBuffer.subdata(in: 0..<dRange.lowerBound)
                let extraBodyData = rawBuffer.subdata(in: dRange.upperBound..<rawBuffer.count)

                guard let rawHeaderString = String(data: headerOnlyBytes, encoding: .utf8) else {
                    Self.finishClientRejection(fd: clientFd, response: Self.makeBadRequestResponse())
                    continuation.resume(returning: .finished)
                    return
                }

                let parsed = Self.parseRequest(rawHeaderString)
                if case .invalid = parsed {
                    Self.finishClientRejection(fd: clientFd, response: Self.makeBadRequestResponse())
                    continuation.resume(returning: .finished)
                    return
                }

                continuation.resume(returning: .parsed(parsed, headerString: rawHeaderString, extraBodyData: extraBodyData))
            }
        }

        guard case .parsed(let parsed, let rawHeaderString, let extraBodyData) = outcome else {
            return
        }

        switch parsed {
        case .invalid:
            return

        case .connect(let host, let port):
            await handleConnect(
                clientFd: clientFd,
                clientDesc: clientDesc,
                host: host,
                port: port,
                extraBodyData: extraBodyData,
                interface: interface,
                onTargetConnected: onTargetConnected,
                onBytesTransferred: onBytesTransferred
            )

        case .standard(let method, let urlStr, let keepAlive):
            await handleStandardRequest(
                clientFd: clientFd,
                clientDesc: clientDesc,
                method: method,
                urlStr: urlStr,
                keepAlive: keepAlive,
                rawHeaderString: rawHeaderString,
                extraBodyData: extraBodyData,
                interface: interface,
                onTargetConnected: onTargetConnected,
                onBytesTransferred: onBytesTransferred
            )
        }
    }

    private static func finishClientRejection(fd: Int32, response: String) {
        _ = ProxySocketIO.writeAll(fd: fd, data: Data(response.utf8))
        _ = Darwin.shutdown(fd, SHUT_WR)

        // Drain unread client bytes briefly so close() does not send TCP RST over our HTTP response.
        var drainBuf = [UInt8](repeating: 0, count: 4096)
        var totalDrained = 0
        while totalDrained < 65_536 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollRes = Darwin.poll(&pfd, 1, 25)
            guard pollRes > 0, (pfd.revents & Int16(POLLIN)) != 0 else { break }
            let n = Darwin.read(fd, &drainBuf, drainBuf.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            totalDrained += n
        }
    }

    // MARK: - CONNECT Tunneling Mode

    private func handleConnect(
        clientFd: Int32,
        clientDesc: String,
        host: String,
        port: Int,
        extraBodyData: Data,
        interface: String,
        onTargetConnected: (@Sendable (String, Int, ProxyProtocolType, Int32) -> Void)?,
        onBytesTransferred: (@Sendable (Int64, Int64) -> Void)?
    ) async {
        let targetFdOpt: Int32? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                switch self.connectOutbound(host: host, port: port, targetInterface: interface) {
                case .failure(let errMsg):
                    let resp = Self.makeGatewayTimeoutResponse(message: "Gateway Timeout: \(errMsg)")
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: Data(resp.utf8))
                    continuation.resume(returning: nil)

                case .success(let targetFd):
                    let successResponse = Self.makeConnectSuccessResponse()
                    guard ProxySocketIO.writeAll(fd: clientFd, data: Data(successResponse.utf8)) else {
                        Darwin.close(targetFd)
                        continuation.resume(returning: nil)
                        return
                    }
                    if !extraBodyData.isEmpty {
                        guard ProxySocketIO.writeAll(fd: targetFd, data: extraBodyData) else {
                            Darwin.close(targetFd)
                            continuation.resume(returning: nil)
                            return
                        }
                    }
                    continuation.resume(returning: targetFd)
                }
            }
        }

        guard let targetFd = targetFdOpt else { return }
        defer { Darwin.close(targetFd) }

        let connId = UUID()
        let initialReadBytes = Int64(extraBodyData.count)
        let connInfo = ProxyConnectionInfo(
            id: connId,
            port: self.port,
            clientAddress: clientDesc,
            targetHost: host,
            targetPort: port,
            egressInterface: interface,
            protocolType: .httpConnect,
            bytesRead: initialReadBytes,
            bytesWritten: 0
        )

        lock.withLock {
            activeConns[connId] = (connInfo, clientFd, targetFd)
            bytesReadCounter += initialReadBytes
        }
        onTargetConnected?(host, port, .httpConnect, targetFd)
        if initialReadBytes > 0 {
            onBytesTransferred?(initialReadBytes, 0)
        }

        defer {
            lock.withLock {
                _ = activeConns.removeValue(forKey: connId)
            }
        }

        // Stream raw bytes bidirectionally
        await streamBidirectional(
            clientFd: clientFd,
            targetFd: targetFd,
            connId: connId,
            onBytesTransferred: onBytesTransferred
        )
    }

    // MARK: - Direct GET/POST Request Mode

    private func handleStandardRequest(
        clientFd: Int32,
        clientDesc: String,
        method: String,
        urlStr: String,
        keepAlive: Bool,
        rawHeaderString: String,
        extraBodyData: Data,
        interface: String,
        onTargetConnected: (@Sendable (String, Int, ProxyProtocolType, Int32) -> Void)?,
        onBytesTransferred: (@Sendable (Int64, Int64) -> Void)?
    ) async {
        guard let url = URL(string: urlStr), let host = url.host else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let resp = Self.makeBadRequestResponse()
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: Data(resp.utf8))
                    continuation.resume()
                }
            }
            return
        }

        let targetPort = url.port ?? (url.scheme == "https" ? 443 : 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query {
            path += "?\(query)"
        }

        // Rewrite headers ONLY (never touch raw extraBodyData): rewrite request line to origin-form, drop Proxy-Connection
        var lines = rawHeaderString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let resp = Self.makeBadRequestResponse()
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: Data(resp.utf8))
                    continuation.resume()
                }
            }
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

        let rewrittenHeaders = filteredLines.joined(separator: "\r\n") + "\r\n\r\n"
        let outgoingData: Data = {
            var buffer = Data(rewrittenHeaders.utf8)
            if !extraBodyData.isEmpty {
                buffer.append(extraBodyData)
            }
            return buffer
        }()

        let targetFdOpt: Int32? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                switch self.connectOutbound(host: host, port: targetPort, targetInterface: interface) {
                case .failure(let errMsg):
                    let resp = Self.makeGatewayTimeoutResponse(message: "Gateway Timeout: \(errMsg)")
                    _ = ProxySocketIO.writeAll(fd: clientFd, data: Data(resp.utf8))
                    continuation.resume(returning: nil)

                case .success(let targetFd):
                    guard ProxySocketIO.writeAll(fd: targetFd, data: outgoingData) else {
                        Darwin.close(targetFd)
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: targetFd)
                }
            }
        }

        guard let targetFd = targetFdOpt else { return }
        defer { Darwin.close(targetFd) }

        let connId = UUID()
        let initialSentBytes = Int64(outgoingData.count)
        let connInfo = ProxyConnectionInfo(
            id: connId,
            port: self.port,
            clientAddress: clientDesc,
            targetHost: host,
            targetPort: targetPort,
            egressInterface: interface,
            protocolType: .httpDirect,
            bytesRead: initialSentBytes,
            bytesWritten: 0
        )

        lock.withLock {
            activeConns[connId] = (connInfo, clientFd, targetFd)
            bytesReadCounter += initialSentBytes
        }
        onTargetConnected?(host, targetPort, .httpDirect, targetFd)
        if initialSentBytes > 0 {
            onBytesTransferred?(initialSentBytes, 0)
        }

        defer {
            lock.withLock {
                _ = activeConns.removeValue(forKey: connId)
            }
        }

        // Stream remaining request body (if any) and response back from target to client
        await streamBidirectional(
            clientFd: clientFd,
            targetFd: targetFd,
            connId: connId,
            onBytesTransferred: onBytesTransferred
        )
    }

    // MARK: - Outbound Connection

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
            let msg = String(cString: strerror(err))
            return .failure("Connection refused or timed out: \(msg)")
        }
    }

    // MARK: - Streaming & Helpers

    private func streamBidirectional(
        clientFd: Int32,
        targetFd: Int32,
        connId: UUID,
        onBytesTransferred: (@Sendable (Int64, Int64) -> Void)?
    ) async {
        await ProxySocketIO.streamAndTrack(
            clientFd: clientFd,
            targetFd: targetFd,
            recordBytes: { [weak self] readDelta, writeDelta in
                self?.recordBytes(connId: connId, readDelta: readDelta, writeDelta: writeDelta)
            },
            onBytesTransferred: onBytesTransferred
        )
    }

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
}
