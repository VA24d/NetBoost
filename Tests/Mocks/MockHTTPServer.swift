import Foundation
import Network

public struct CapturedHTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public let timestamp: Date

    public init(
        method: String,
        path: String,
        headers: [String: String],
        body: Data = Data(),
        timestamp: Date = Date()
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.timestamp = timestamp
    }
}

public enum CaptivePortalMode: Sendable, Equatable {
    case none
    case redirect302(targetURL: String)
    case htmlLoginForm(formHTML: String)
    case appleHotspotDetectSuccess
}

public final class MockHTTPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var isRunning = false
    private var port: UInt16 = 0

    // Server Configuration
    public var payload: Data
    public var captivePortalMode: CaptivePortalMode = .none
    public var forceRange416: Bool = false
    public var force500Error: Bool = false
    public var dropConnectionImmediately: Bool = false
    public var dropConnectionAfterBytes: Int? = nil
    public var simulateNonRangeSupport: Bool = false

    // Request Tracking
    private var requests: [CapturedHTTPRequest] = []

    public var recordedRequests: [CapturedHTTPRequest] {
        lock.withLock { requests }
    }

    public init(payload: Data? = nil) {
        if let payload = payload {
            self.payload = payload
        } else {
            // Default 1MB deterministic payload
            var bytes = [UInt8](repeating: 0, count: 1_048_576)
            for i in 0..<bytes.count {
                bytes[i] = UInt8(i % 251)
            }
            self.payload = Data(bytes)
        }
    }

    public func resetRecordedRequests() {
        lock.withLock { requests.removeAll() }
    }

    /// Starts the HTTP server on an ephemeral loopback port and returns the assigned port.
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
                                continuation.resume(throwing: NSError(domain: "MockHTTPServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to determine bound port"]))
                            }
                        }
                    case .waiting(let error), .failed(let error):
                        listener.cancel()
                        if gate.tryEnter() {
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        if gate.tryEnter() {
                            continuation.resume(throwing: NSError(domain: "MockHTTPServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "MockHTTPServer listener cancelled before ready"]))
                        }
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] newConnection in
                    self?.handleNewConnection(newConnection)
                }

                listener.start(queue: .global())

                DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                    if gate.tryEnter() {
                        listener.cancel()
                        continuation.resume(throwing: NSError(domain: "MockHTTPServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "MockHTTPServer startup timed out"]))
                    }
                }
            } catch {
                if gate.tryEnter() {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the server and cancels all active connections.
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

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let shouldAccept = lock.withLock { () -> Bool in
            guard isRunning, !dropConnectionImmediately else { return false }
            activeConnections.append(connection)
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
                self.receiveNextBlock(on: connection, accumulatedData: Data())
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

    private func receiveNextBlock(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }

            if error != nil {
                connection.cancel()
                self.removeConnection(connection)
                return
            }

            var current = accumulatedData
            if let data = data {
                current.append(data)
            }

            // Check if headers have fully arrived (\r\n\r\n)
            if let headerEnd = current.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = current.subdata(in: 0..<headerEnd.lowerBound)
                let bodyData = current.subdata(in: headerEnd.upperBound..<current.count)

                if let headerString = String(data: headerData, encoding: .utf8) {
                    self.processRequest(headerString: headerString, bodyData: bodyData, on: connection)
                    return
                }
            }

            if isComplete {
                connection.cancel()
                self.removeConnection(connection)
            } else {
                self.receiveNextBlock(on: connection, accumulatedData: current)
            }
        }
    }

    private func processRequest(headerString: String, bodyData: Data, on connection: NWConnection) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            removeConnection(connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            removeConnection(connection)
            return
        }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let captured = CapturedHTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: bodyData,
            timestamp: Date()
        )

        let (mode, is500, is416, dropAfter, noRanges, currentPayload) = lock.withLock { () -> (CaptivePortalMode, Bool, Bool, Int?, Bool, Data) in
            requests.append(captured)
            return (captivePortalMode, force500Error, forceRange416, dropConnectionAfterBytes, simulateNonRangeSupport, payload)
        }

        // 1. Fault Injection: Force 500
        if is500 {
            let body = "Internal Server Error"
            let response = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
            return
        }

        // 2. Captive Portal Emulation
        switch mode {
        case .redirect302(let targetURL):
            let response = "HTTP/1.1 302 Found\r\nLocation: \(targetURL)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
            return

        case .htmlLoginForm(let formHTML):
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(formHTML.utf8.count)\r\nConnection: close\r\n\r\n\(formHTML)"
            sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
            return

        case .appleHotspotDetectSuccess:
            let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
            return

        case .none:
            break
        }

        // 3. Apple Captive Probe Path Detection: /hotspot-detect.html
        if path.contains("hotspot-detect.html") {
            let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
            return
        }

        // 4. Fault Injection: Force 416
        if is416 {
            let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(currentPayload.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
            return
        }

        // 5. Standard HEAD Handling
        if method == "HEAD" {
            var headerLines = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/octet-stream",
                "Content-Length: \(currentPayload.count)",
                "Connection: close"
            ]
            if !noRanges {
                headerLines.append("Accept-Ranges: bytes")
            }
            let response = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
            sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
            return
        }

        // 6. Range GET Request Handling
        if method == "GET", !noRanges, let rangeHeader = headers["range"] {
            if let parsedRange = parseByteRange(rangeHeader, totalBytes: currentPayload.count) {
                let start = parsedRange.0
                let end = parsedRange.1

                if start > end || start >= currentPayload.count {
                    let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(currentPayload.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    sendResponseData(Data(response.utf8), on: connection, dropAfterBytes: dropAfter)
                    return
                }

                let slice = currentPayload.subdata(in: start..<(end + 1))
                let headerLines = [
                    "HTTP/1.1 206 Partial Content",
                    "Content-Type: application/octet-stream",
                    "Content-Range: bytes \(start)-\(end)/\(currentPayload.count)",
                    "Content-Length: \(slice.count)",
                    "Accept-Ranges: bytes",
                    "Connection: close"
                ]
                var responseData = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
                responseData.append(slice)
                sendResponseData(responseData, on: connection, dropAfterBytes: dropAfter)
                return
            }
        }

        // 7. Full GET Request Handling
        var headerLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/octet-stream",
            "Content-Length: \(currentPayload.count)",
            "Connection: close"
        ]
        if !noRanges {
            headerLines.append("Accept-Ranges: bytes")
        }
        var responseData = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        responseData.append(currentPayload)
        sendResponseData(responseData, on: connection, dropAfterBytes: dropAfter)
    }

    private func sendResponseData(_ data: Data, on connection: NWConnection, dropAfterBytes: Int?) {
        if let dropLimit = dropAfterBytes, dropLimit < data.count {
            let partial = data.prefix(dropLimit)
            connection.send(content: partial, completion: .contentProcessed { [weak self, weak connection] _ in
                connection?.cancel()
                if let conn = connection {
                    self?.removeConnection(conn)
                }
            })
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] _ in
            connection?.cancel()
            if let conn = connection {
                self?.removeConnection(conn)
            }
        })
    }

    private func parseByteRange(_ rangeHeader: String, totalBytes: Int) -> (Int, Int)? {
        // Expected format: "bytes=start-end" or "bytes=start-"
        guard rangeHeader.hasPrefix("bytes=") else { return nil }
        let spec = rangeHeader.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let tokens = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard tokens.count == 2 else { return nil }

        let startStr = String(tokens[0])
        let endStr = String(tokens[1])

        if !startStr.isEmpty && !endStr.isEmpty {
            guard let start = Int(startStr), let end = Int(endStr) else { return nil }
            return (start, min(end, totalBytes - 1))
        } else if !startStr.isEmpty && endStr.isEmpty {
            guard let start = Int(startStr) else { return nil }
            return (start, totalBytes - 1)
        } else if startStr.isEmpty && !endStr.isEmpty {
            // Suffix range: bytes=-500
            guard let suffixLen = Int(endStr) else { return nil }
            let start = max(0, totalBytes - suffixLen)
            return (start, totalBytes - 1)
        }
        return nil
    }
}
