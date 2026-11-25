import Foundation
import Network

public enum SOCKS5TargetMode: Sendable, Equatable {
    case rawEcho
    case httpEcho
    case fixedData(Data)
}

public final class MockSOCKS5TargetServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var isRunning = false
    private var port: UInt16 = 0

    public var mode: SOCKS5TargetMode = .rawEcho

    // Tracking
    private var clientEndpoints: [String] = []
    private var payloads: [Data] = []
    private var bytesReceived: Int = 0
    private var bytesSent: Int = 0

    public var connectedClientEndpoints: [String] {
        lock.withLock { clientEndpoints }
    }

    public var receivedPayloads: [Data] {
        lock.withLock { payloads }
    }

    public var totalBytesReceived: Int {
        lock.withLock { bytesReceived }
    }

    public var totalBytesSent: Int {
        lock.withLock { bytesSent }
    }

    public init(mode: SOCKS5TargetMode = .rawEcho) {
        self.mode = mode
    }

    public func resetMetrics() {
        lock.withLock {
            clientEndpoints.removeAll()
            payloads.removeAll()
            bytesReceived = 0
            bytesSent = 0
        }
    }

    public func start() async throws -> UInt16 {
        final class OnceGate: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func tryEnter() -> Bool {
                lock.withLock {
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let alreadyRunningPort: UInt16? = lock.withLock {
                if isRunning { return self.port }
                return nil
            }
            if let p = alreadyRunningPort {
                continuation.resume(returning: p)
                return
            }

            let gate = OnceGate()
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                let listener = try NWListener(using: params)
                self.lock.withLock { self.listener = listener }

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        if let assignedPort = listener.port?.rawValue {
                            self.lock.withLock {
                                self.port = assignedPort
                                self.isRunning = true
                            }
                            if gate.tryEnter() {
                                continuation.resume(returning: assignedPort)
                            }
                        } else {
                            listener.cancel()
                            if gate.tryEnter() {
                                continuation.resume(throwing: NSError(domain: "MockSOCKS5TargetServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to determine bound port"]))
                            }
                        }
                    case .waiting(let error), .failed(let error):
                        listener.cancel()
                        if gate.tryEnter() {
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        if gate.tryEnter() {
                            continuation.resume(throwing: NSError(domain: "MockSOCKS5TargetServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "MockSOCKS5TargetServer listener cancelled before ready"]))
                        }
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] newConn in
                    self?.handleNewConnection(newConn)
                }

                listener.start(queue: .global())

                DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                    if gate.tryEnter() {
                        listener.cancel()
                        continuation.resume(throwing: NSError(domain: "MockSOCKS5TargetServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "MockSOCKS5TargetServer startup timed out"]))
                    }
                }
            } catch {
                if gate.tryEnter() {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        let connsToCancel = lock.withLock { () -> [NWConnection] in
            isRunning = false
            listener?.cancel()
            listener = nil
            let conns = activeConnections
            activeConnections.removeAll()
            return conns
        }

        for conn in connsToCancel {
            conn.cancel()
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let shouldAccept = lock.withLock { () -> Bool in
            guard isRunning else { return false }
            activeConnections.append(connection)
            let endpointDesc = "\(connection.endpoint)"
            clientEndpoints.append(endpointDesc)
            return true
        }

        guard shouldAccept else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .ready:
                self.receiveData(on: connection)
            case .failed, .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: .global())
    }

    private func removeConnection(_ connection: NWConnection) {
        lock.withLock {
            activeConnections.removeAll(where: { $0 === connection })
        }
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }

            if error != nil {
                connection.cancel()
                self.removeConnection(connection)
                return
            }

            if let data = data, !data.isEmpty {
                let currentMode = self.lock.withLock { () -> SOCKS5TargetMode in
                    self.payloads.append(data)
                    self.bytesReceived += data.count
                    return self.mode
                }

                self.sendResponse(for: data, on: connection, mode: currentMode)
            }

            if isComplete {
                connection.cancel()
                self.removeConnection(connection)
            } else {
                self.receiveData(on: connection)
            }
        }
    }

    private func sendResponse(for incomingData: Data, on connection: NWConnection, mode: SOCKS5TargetMode) {
        let responseData: Data

        switch mode {
        case .rawEcho:
            responseData = incomingData

        case .fixedData(let data):
            responseData = data

        case .httpEcho:
            if let str = String(data: incomingData, encoding: .utf8), str.hasPrefix("GET") || str.hasPrefix("POST") || str.hasPrefix("HEAD") {
                let body = "Echo: Received \(incomingData.count) bytes\n"
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                var full = Data(headers.utf8)
                full.append(Data(body.utf8))
                responseData = full
            } else {
                responseData = incomingData
            }
        }

        lock.withLock {
            bytesSent += responseData.count
        }

        connection.send(content: responseData, completion: .contentProcessed { [weak self, weak connection] _ in
            if case .httpEcho = mode {
                connection?.cancel()
                if let conn = connection {
                    self?.removeConnection(conn)
                }
            }
        })
    }
}
