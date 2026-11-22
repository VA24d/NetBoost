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
        lock.lock()
        defer { lock.unlock() }
        return clientEndpoints
    }

    public var receivedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    public var totalBytesReceived: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytesReceived
    }

    public var totalBytesSent: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytesSent
    }

    public init(mode: SOCKS5TargetMode = .rawEcho) {
        self.mode = mode
    }

    public func resetMetrics() {
        lock.lock()
        defer { lock.unlock() }
        clientEndpoints.removeAll()
        payloads.removeAll()
        bytesReceived = 0
        bytesSent = 0
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isRunning {
                let p = self.port
                lock.unlock()
                continuation.resume(returning: p)
                return
            }

            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params, on: .any)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        if let assignedPort = listener.port?.rawValue {
                            self.lock.lock()
                            self.port = assignedPort
                            self.isRunning = true
                            self.lock.unlock()
                            continuation.resume(returning: assignedPort)
                        } else {
                            continuation.resume(throwing: NSError(domain: "MockSOCKS5TargetServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to determine bound port"]))
                        }
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] newConn in
                    self?.handleNewConnection(newConn)
                }

                listener.start(queue: .global())
                lock.unlock()
            } catch {
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        isRunning = false
        listener?.cancel()
        listener = nil

        for conn in activeConnections {
            conn.cancel()
        }
        activeConnections.removeAll()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            connection.cancel()
            return
        }

        activeConnections.append(connection)
        let endpointDesc = "\(connection.endpoint)"
        clientEndpoints.append(endpointDesc)
        lock.unlock()

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
        lock.lock()
        defer { lock.unlock() }
        activeConnections.removeAll(where: { $0 === connection })
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }

            if let error = error {
                connection.cancel()
                self.removeConnection(connection)
                return
            }

            if let data = data, !data.isEmpty {
                self.lock.lock()
                self.payloads.append(data)
                self.bytesReceived += data.count
                let currentMode = self.mode
                self.lock.unlock()

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

        lock.lock()
        bytesSent += responseData.count
        lock.unlock()

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
