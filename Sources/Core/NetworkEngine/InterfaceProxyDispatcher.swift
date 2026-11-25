import Foundation
import Darwin

public final class InterfaceProxyDispatcher: ProxyDispatcherProtocol, @unchecked Sendable {
    public static let defaultPorts: [Int: String] = [
        1080: "en10",
        1081: "en0",
        1082: "auto"
    ]

    private let lock = NSLock()
    public private(set) var portConfigs: [Int: ProxyPortConfiguration] = [:]
    public var loadBalancedInterfaces: [String] = ["en10", "en0"]
    private var roundRobinIndex: Int = 0

    private var listeners: [Int: Int32] = [:] // port -> fd
    private var _boundPorts: [Int: Int] = [:] // config port -> actual port
    public var boundPorts: [Int: Int] {
        lock.withLock { _boundPorts }
    }
    private var acceptTasks: [Int: Task<Void, Never>] = [:]
    private var isRunningInternal: Bool = false

    private var activeConns: [UUID: ProxyConnectionInfo] = [:]
    private var activeClientFds: [UUID: Int32] = [:]
    private var activeTargetFds: [UUID: Int32] = [:]
    private var totalBytesReadCounter: Int64 = 0
    private var totalBytesWrittenCounter: Int64 = 0

    public var isRunning: Bool {
        lock.withLock { isRunningInternal }
    }

    public var activeConnections: [ProxyConnectionInfo] {
        lock.withLock { Array(activeConns.values) }
    }

    public var totalBytesRead: Int64 {
        lock.withLock { totalBytesReadCounter }
    }

    public var totalBytesWritten: Int64 {
        lock.withLock { totalBytesWrittenCounter }
    }

    public init(
        ports: [Int: String] = defaultPorts,
        loadBalancedInterfaces: [String] = ["en10", "en0"]
    ) {
        self.loadBalancedInterfaces = loadBalancedInterfaces
        for (port, iface) in ports {
            let mode: ProxyPortMode = (iface == "auto") ? .loadBalanced : .direct
            let label = (mode == .loadBalanced) ? "Load Balanced" : "\(iface) Direct"
            self.portConfigs[port] = ProxyPortConfiguration(
                port: port,
                targetInterface: iface,
                mode: mode,
                label: label
            )
        }
    }

    deinit {
        let (fds, clientFds, targetFds) = lock.withLock { () -> ([Int32], [Int32], [Int32]) in
            isRunningInternal = false
            let f = Array(listeners.values)
            let c = Array(activeClientFds.values)
            let t = Array(activeTargetFds.values)
            listeners.removeAll()
            activeClientFds.removeAll()
            activeTargetFds.removeAll()
            activeConns.removeAll()
            return (f, c, t)
        }
        for fd in clientFds where fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        for fd in targetFds where fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        for fd in fds where fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Interface Selection

    public func interfaceForPort(_ port: Int) -> String? {
        lock.withLock {
            guard let cfg = portConfigs[port] else { return nil }
            if cfg.mode == .loadBalanced {
                guard !loadBalancedInterfaces.isEmpty else { return "en10" }
                let chosen = loadBalancedInterfaces[roundRobinIndex % loadBalancedInterfaces.count]
                roundRobinIndex += 1
                return chosen
            }
            return cfg.targetInterface
        }
    }

    public func nextLoadBalancedInterface() -> String {
        lock.withLock {
            guard !loadBalancedInterfaces.isEmpty else { return "en10" }
            let chosen = loadBalancedInterfaces[roundRobinIndex % loadBalancedInterfaces.count]
            roundRobinIndex += 1
            return chosen
        }
    }

    // MARK: - Shell Snippet

    public func generateShellSnippet(port: Int) -> String {
        "export ALL_PROXY=socks5://127.0.0.1:\(port)"
    }

    // MARK: - Lifecycle

    public func start(ports: [Int: String] = defaultPorts) async throws {
        lock.withLock {
            for (port, iface) in ports {
                let mode: ProxyPortMode = (iface == "auto") ? .loadBalanced : .direct
                let label = (mode == .loadBalanced) ? "Load Balanced" : "\(iface) Direct"
                self.portConfigs[port] = ProxyPortConfiguration(
                    port: port,
                    targetInterface: iface,
                    mode: mode,
                    label: label
                )
            }
        }

        var startedFds: [Int: Int32] = [:]

        do {
            for port in ports.keys {
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
                var actualPort = port
                if withUnsafeMutablePointer(to: &boundAddr, { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        getsockname(fd, sa, &boundLen)
                    }
                }) == 0 {
                    actualPort = Int(UInt16(bigEndian: boundAddr.sin_port))
                }

                startedFds[port] = fd
                lock.withLock {
                    self._boundPorts[port] = actualPort
                }
            }
        } catch {
            // Clean up any successfully started fds on error
            for (_, fd) in startedFds {
                Darwin.close(fd)
            }
            throw error
        }

        lock.withLock {
            self.listeners = startedFds
            self.isRunningInternal = true
        }

        for (port, fd) in startedFds {
            let task = Task { [weak self] () -> Void in
                guard let self = self else { return }
                await self.runAcceptLoop(port: port, listenerFd: fd)
            }
            lock.withLock {
                self.acceptTasks[port] = task
            }
        }
    }

    public func stop() async throws {
        let (fdsToClose, clientFdsToClose, targetFdsToClose): ([Int32], [Int32], [Int32]) = lock.withLock {
            isRunningInternal = false
            let f = Array(listeners.values)
            listeners.removeAll()
            let c = Array(activeClientFds.values)
            activeClientFds.removeAll()
            let t = Array(activeTargetFds.values)
            activeTargetFds.removeAll()
            activeConns.removeAll()
            return (f, c, t)
        }

        for fd in clientFdsToClose where fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        for fd in targetFdsToClose where fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }

        for fd in fdsToClose where fd >= 0 {
            Darwin.close(fd)
        }

        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            let t = Array(acceptTasks.values)
            acceptTasks.removeAll()
            return t
        }

        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Accept Loop & Auto-Detection

    private func runAcceptLoop(port: Int, listenerFd: Int32) async {
        while isRunning && !Task.isCancelled {
            guard let accepted = await ProxySocketIO.acceptNext(
                listenerFd: listenerFd,
                isRunning: { [weak self] in self?.isRunning ?? false }
            ) else {
                if !isRunning || Task.isCancelled { break }
                continue
            }

            let assignedInterface: String
            let cfg = lock.withLock { portConfigs[port] }
            if cfg?.mode == .loadBalanced {
                assignedInterface = nextLoadBalancedInterface()
            } else {
                assignedInterface = cfg?.targetInterface ?? "en10"
            }

            Task { [weak self] in
                await self?.handleIncomingConnection(
                    clientFd: accepted.clientFd,
                    clientDesc: accepted.clientDesc,
                    port: port,
                    assignedInterface: assignedInterface
                )
            }
        }
    }

    private func handleIncomingConnection(
        clientFd: Int32,
        clientDesc: String,
        port: Int,
        assignedInterface: String
    ) async {
        ProxySocketIO.setHandshakeTimeouts(fd: clientFd, seconds: 15)
        let firstByteOpt: UInt8? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var firstByte: UInt8 = 0
                var peekCount: Int
                repeat {
                    peekCount = recv(clientFd, &firstByte, 1, MSG_PEEK)
                } while peekCount < 0 && errno == EINTR

                if peekCount == 1 {
                    continuation.resume(returning: firstByte)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let firstByte = firstByteOpt else {
            Darwin.close(clientFd)
            return
        }

        let connId = UUID()

        if firstByte == 0x05 {
            let connInfo = ProxyConnectionInfo(
                id: connId,
                port: port,
                clientAddress: clientDesc,
                targetHost: "socks5",
                targetPort: 0,
                egressInterface: assignedInterface,
                protocolType: .socks5
            )
            lock.withLock {
                activeConns[connId] = connInfo
                activeClientFds[connId] = clientFd
            }
            defer {
                lock.withLock {
                    _ = activeConns.removeValue(forKey: connId)
                    _ = activeClientFds.removeValue(forKey: connId)
                    _ = activeTargetFds.removeValue(forKey: connId)
                }
            }

            let socks5 = SOCKS5Server(port: port, targetInterface: assignedInterface)
            await socks5.handleClient(
                clientFd: clientFd,
                clientDesc: clientDesc,
                interface: assignedInterface,
                onTargetConnected: { [weak self] targetHost, targetPort, protoType, targetFd in
                    self?.updateConnectionTarget(
                        connId: connId,
                        targetHost: targetHost,
                        targetPort: targetPort,
                        protocolType: protoType,
                        targetFd: targetFd
                    )
                },
                onBytesTransferred: { [weak self] deltaRead, deltaWritten in
                    self?.recordBytes(connId: connId, readDelta: deltaRead, writeDelta: deltaWritten)
                }
            )
        } else if firstByte >= 0x20 && firstByte <= 0x7E {
            let connInfo = ProxyConnectionInfo(
                id: connId,
                port: port,
                clientAddress: clientDesc,
                targetHost: "http",
                targetPort: 0,
                egressInterface: assignedInterface,
                protocolType: .httpConnect
            )
            lock.withLock {
                activeConns[connId] = connInfo
                activeClientFds[connId] = clientFd
            }
            defer {
                lock.withLock {
                    _ = activeConns.removeValue(forKey: connId)
                    _ = activeClientFds.removeValue(forKey: connId)
                    _ = activeTargetFds.removeValue(forKey: connId)
                }
            }

            let http = HTTPProxyServer(port: port, targetInterface: assignedInterface)
            await http.handleClient(
                clientFd: clientFd,
                clientDesc: clientDesc,
                interface: assignedInterface,
                onTargetConnected: { [weak self] targetHost, targetPort, protoType, targetFd in
                    self?.updateConnectionTarget(
                        connId: connId,
                        targetHost: targetHost,
                        targetPort: targetPort,
                        protocolType: protoType,
                        targetFd: targetFd
                    )
                },
                onBytesTransferred: { [weak self] deltaRead, deltaWritten in
                    self?.recordBytes(connId: connId, readDelta: deltaRead, writeDelta: deltaWritten)
                }
            )
        } else {
            // Unsupported binary protocol (e.g. SOCKS4 or garbage)
            Darwin.close(clientFd)
        }
    }

    private func updateConnectionTarget(
        connId: UUID,
        targetHost: String,
        targetPort: Int,
        protocolType: ProxyProtocolType,
        targetFd: Int32
    ) {
        lock.withLock {
            activeTargetFds[connId] = targetFd
            if let existing = activeConns[connId] {
                activeConns[connId] = ProxyConnectionInfo(
                    id: existing.id,
                    port: existing.port,
                    clientAddress: existing.clientAddress,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    egressInterface: existing.egressInterface,
                    protocolType: protocolType,
                    bytesRead: existing.bytesRead,
                    bytesWritten: existing.bytesWritten,
                    startTime: existing.startTime
                )
            }
        }
    }

    private func recordBytes(connId: UUID, readDelta: Int64, writeDelta: Int64) {
        lock.withLock {
            totalBytesReadCounter += readDelta
            totalBytesWrittenCounter += writeDelta
            if let existing = activeConns[connId] {
                activeConns[connId] = ProxySocketIO.makeUpdatedConnectionInfo(existing, readDelta: readDelta, writeDelta: writeDelta)
            }
        }
    }
}
