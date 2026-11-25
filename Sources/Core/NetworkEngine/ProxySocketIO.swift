import Foundation
import Darwin

internal enum ProxySocketIO {
    static func acceptNext(
        listenerFd: Int32,
        isRunning: @escaping @Sendable () -> Bool
    ) async -> (clientFd: Int32, clientDesc: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                while isRunning() {
                    var clientAddr = sockaddr_in()
                    var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

                    let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.accept(listenerFd, sa, &clientAddrLen)
                        }
                    }

                    if clientFd >= 0 {
                        // Clear O_NONBLOCK inherited from listener so client socket has blocking I/O
                        let clientFlags = fcntl(clientFd, F_GETFL, 0)
                        if clientFlags >= 0 {
                            _ = fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK)
                        }

                        var one: Int32 = 1
                        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

                        // Handshake timeout (15s) — cleared before entering persistent bidirectional streaming
                        var tv = timeval(tv_sec: 15, tv_usec: 0)
                        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                        setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                        let clientIP = String(cString: inet_ntoa(clientAddr.sin_addr))
                        let clientPort = Int(UInt16(bigEndian: clientAddr.sin_port))
                        continuation.resume(returning: (clientFd, "\(clientIP):\(clientPort)"))
                        return
                    }

                    let err = errno
                    if !isRunning() { break }
                    if err == EINTR { continue }
                    if err == EWOULDBLOCK || err == EAGAIN {
                        var pfd = pollfd(fd: listenerFd, events: Int16(POLLIN), revents: 0)
                        let pollRes = Darwin.poll(&pfd, 1, 50)
                        if pollRes < 0 && errno != EINTR {
                            break
                        }
                        if (pfd.revents & Int16(POLLNVAL | POLLERR)) != 0 {
                            break
                        }
                        continue
                    }
                    break
                }
                continuation.resume(returning: nil)
            }
        }
    }

    static func setHandshakeTimeouts(fd: Int32, seconds: Int = 15) {
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func clearTimeouts(fd: Int32) {
        guard fd >= 0 else { return }
        var zero = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
    }

    internal enum OutboundConnectIO {
        case success(Int32)
        case failure(Int32)
    }

    static func connectOutbound(
        host: String,
        port: Int,
        targetInterface: String,
        timeout: TimeInterval = 5.0
    ) -> OutboundConnectIO {
        let cleanHost: String
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 {
            cleanHost = String(host.dropFirst().dropLast())
        } else {
            cleanHost = host
        }

        guard !cleanHost.isEmpty, (1...65535).contains(port) else {
            return .failure(EINVAL)
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let gaiStatus = getaddrinfo(cleanHost, portStr, &hints, &res)
        guard gaiStatus == 0, let addrList = res else {
            return .failure(EHOSTUNREACH)
        }
        defer { freeaddrinfo(res) }

        var ptr: UnsafeMutablePointer<addrinfo>? = addrList
        var lastErr: Int32 = ECONNREFUSED
        var connectedFd: Int32 = -1

        let isLoopback = cleanHost == "127.0.0.1"
            || cleanHost == "localhost"
            || cleanHost == "::1"
            || cleanHost.hasPrefix("127.")

        let timeoutMs = Int32(max(1, Int(ceil(timeout * 1000.0))))

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

            if !isLoopback && !targetInterface.isEmpty && targetInterface != "auto" && targetInterface != "any" {
                if let ifIdx = DarwinSocketHelper.getInterfaceIndex(for: targetInterface) {
                    _ = try? DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: ifIdx)
                }
            } else if targetInterface == "lo0" {
                if let loIdx = DarwinSocketHelper.getInterfaceIndex(for: "lo0") {
                    _ = try? DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIdx)
                }
            }

            // Use non-blocking connect + poll for crisp connect timeout without leaving SO_RCVTIMEO on the tunnel
            let origFlags = fcntl(fd, F_GETFL, 0)
            if origFlags >= 0 {
                _ = fcntl(fd, F_SETFL, origFlags | O_NONBLOCK)
            }

            let connRes = Darwin.connect(fd, info.ai_addr, info.ai_addrlen)
            var isConnected = false
            if connRes == 0 {
                isConnected = true
            } else if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var pollRes: Int32 = 0
                repeat {
                    pollRes = Darwin.poll(&pfd, 1, timeoutMs)
                } while pollRes < 0 && errno == EINTR

                if pollRes > 0 {
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0 {
                        isConnected = true
                    } else {
                        lastErr = soErr != 0 ? soErr : errno
                    }
                } else if pollRes == 0 {
                    lastErr = ETIMEDOUT
                } else {
                    lastErr = errno
                }
            } else {
                lastErr = errno
            }

            if isConnected {
                if origFlags >= 0 {
                    _ = fcntl(fd, F_SETFL, origFlags & ~O_NONBLOCK)
                }
                clearTimeouts(fd: fd)
                connectedFd = fd
                break
            } else {
                Darwin.close(fd)
            }
        }

        if connectedFd >= 0 {
            return .success(connectedFd)
        } else {
            return .failure(lastErr)
        }
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        var bytesWritten = 0
        let total = data.count
        while bytesWritten < total {
            let n = data.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: bytesWritten), total - bytesWritten)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            bytesWritten += n
        }
        return true
    }

    static func readExact(fd: Int32, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        var data = Data(count: count)
        var bytesRead = 0
        while bytesRead < count {
            let n = data.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: bytesRead), count - bytesRead)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            bytesRead += n
        }
        return data
    }

    static func pump(
        from srcFd: Int32,
        to dstFd: Int32,
        bufferSize: Int = 32768,
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) -> Int64 {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var total: Int64 = 0

        while true {
            let n = Darwin.read(srcFd, &buffer, bufferSize)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }

            var written = 0
            var writeFailed = false
            while written < n {
                let bytesToWrite = n - written
                let w = buffer.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.write(dstFd, base.advanced(by: written), bytesToWrite)
                }
                if w < 0 && errno == EINTR { continue }
                if w <= 0 {
                    writeFailed = true
                    break
                }
                written += w
            }
            if writeFailed { break }
            let delta = Int64(n)
            total += delta
            onBytes?(delta)
        }
        return total
    }

    static func pumpAsync(
        from srcFd: Int32,
        to dstFd: Int32,
        bufferSize: Int = 32768,
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let bytes = pump(from: srcFd, to: dstFd, bufferSize: bufferSize, onBytes: onBytes)
                continuation.resume(returning: bytes)
            }
        }
    }

    static func streamBidirectional(
        clientFd: Int32,
        targetFd: Int32,
        onClientToTarget: (@Sendable (Int64) -> Void)? = nil,
        onTargetToClient: (@Sendable (Int64) -> Void)? = nil
    ) async -> (clientToTarget: Int64, targetToClient: Int64) {
        clearTimeouts(fd: clientFd)
        clearTimeouts(fd: targetFd)

        return await withTaskGroup(of: (isClientToTarget: Bool, bytes: Int64).self) { group in
            group.addTask {
                let bytes = await pumpAsync(from: clientFd, to: targetFd, onBytes: onClientToTarget)
                _ = Darwin.shutdown(targetFd, SHUT_WR)
                return (true, bytes)
            }

            group.addTask {
                let bytes = await pumpAsync(from: targetFd, to: clientFd, onBytes: onTargetToClient)
                _ = Darwin.shutdown(clientFd, SHUT_WR)
                return (false, bytes)
            }

            var totalClientToTarget: Int64 = 0
            var totalTargetToClient: Int64 = 0
            for await result in group {
                if result.isClientToTarget {
                    totalClientToTarget += result.bytes
                } else {
                    totalTargetToClient += result.bytes
                }
            }
            return (totalClientToTarget, totalTargetToClient)
        }
    }

    static func makeUpdatedConnectionInfo(
        _ info: ProxyConnectionInfo,
        readDelta: Int64,
        writeDelta: Int64
    ) -> ProxyConnectionInfo {
        ProxyConnectionInfo(
            id: info.id,
            port: info.port,
            clientAddress: info.clientAddress,
            targetHost: info.targetHost,
            targetPort: info.targetPort,
            egressInterface: info.egressInterface,
            protocolType: info.protocolType,
            bytesRead: info.bytesRead + readDelta,
            bytesWritten: info.bytesWritten + writeDelta,
            startTime: info.startTime
        )
    }

    static func streamAndTrack(
        clientFd: Int32,
        targetFd: Int32,
        recordBytes: @escaping @Sendable (Int64, Int64) -> Void,
        onBytesTransferred: (@Sendable (Int64, Int64) -> Void)?
    ) async {
        _ = await streamBidirectional(
            clientFd: clientFd,
            targetFd: targetFd,
            onClientToTarget: { delta in
                recordBytes(delta, 0)
                onBytesTransferred?(delta, 0)
            },
            onTargetToClient: { delta in
                recordBytes(0, delta)
                onBytesTransferred?(0, delta)
            }
        )
    }
}
