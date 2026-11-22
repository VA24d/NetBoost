import Foundation
import Network

public struct SimulatedToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String = "call_\(UUID().uuidString.prefix(8))", name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum LMStudioResponseMode: Sendable {
    case toolCalls([SimulatedToolCall])
    case text(String)
    case error500(String)
}

public final class MockLMStudioServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var isRunning = false
    private var port: UInt16 = 0

    public var responseMode: LMStudioResponseMode = .toolCalls([
        SimulatedToolCall(name: "fix_mtu", arguments: "{\"interface\":\"Wi-Fi\",\"mtu\":1280}"),
        SimulatedToolCall(name: "flush_dns", arguments: "{}")
    ])

    // Request tracking
    private var receivedBodies: [Data] = []
    private var receivedPaths: [String] = []

    public var recordedRequests: [(path: String, body: Data)] {
        lock.withLock {
            var result: [(path: String, body: Data)] = []
            for i in 0..<min(receivedPaths.count, receivedBodies.count) {
                result.append((path: receivedPaths[i], body: receivedBodies[i]))
            }
            return result
        }
    }

    public var lastReceivedBody: Data? {
        lock.withLock { receivedBodies.last }
    }

    public init() {}

    public func resetRecordedRequests() {
        lock.withLock {
            receivedBodies.removeAll()
            receivedPaths.removeAll()
        }
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyRunningPort: UInt16? = lock.withLock {
                if isRunning { return self.port }
                return nil
            }
            if let p = alreadyRunningPort {
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
                            self.lock.withLock {
                                self.port = assignedPort
                                self.isRunning = true
                            }
                            continuation.resume(returning: assignedPort)
                        } else {
                            continuation.resume(throwing: NSError(domain: "MockLMStudioServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to determine bound port"]))
                        }
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] conn in
                    self?.handleNewConnection(conn)
                }

                listener.start(queue: .global())
            } catch {
                continuation.resume(throwing: error)
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
                self.receiveHTTPData(on: connection, buffer: Data())
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

    private func receiveHTTPData(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }

            if error != nil {
                connection.cancel()
                self.removeConnection(connection)
                return
            }

            var current = buffer
            if let data = data {
                current.append(data)
            }

            if let headerEnd = current.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = current.subdata(in: 0..<headerEnd.lowerBound)
                let bodyData = current.subdata(in: headerEnd.upperBound..<current.count)

                if let headerStr = String(data: headerData, encoding: .utf8) {
                    // Check Content-Length to see if body is complete
                    var contentLength = 0
                    for line in headerStr.components(separatedBy: "\r\n") {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            let valStr = lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                            contentLength = Int(valStr) ?? 0
                        }
                    }

                    if bodyData.count >= contentLength {
                        self.processRequest(headerStr: headerStr, bodyData: bodyData.prefix(contentLength), on: connection)
                        return
                    }
                }
            }

            if isComplete {
                connection.cancel()
                self.removeConnection(connection)
            } else {
                self.receiveHTTPData(on: connection, buffer: current)
            }
        }
    }

    private func processRequest(headerStr: String, bodyData: Data, on connection: NWConnection) {
        let lines = headerStr.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? "GET / HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"

        let mode = lock.withLock { () -> LMStudioResponseMode in
            receivedPaths.append(path)
            receivedBodies.append(bodyData)
            return responseMode
        }

        let responseJSON: String
        var statusCode = 200
        var statusText = "OK"

        if path.contains("/v1/models") {
            responseJSON = """
            {
              "object": "list",
              "data": [
                {
                  "id": "qwen2.5-coder-7b-instruct",
                  "object": "model",
                  "created": 1700000000,
                  "owned_by": "lmstudio"
                }
              ]
            }
            """
        } else {
            // /v1/chat/completions or other endpoint
            switch mode {
            case .error500(let msg):
                statusCode = 500
                statusText = "Internal Server Error"
                responseJSON = "{\"error\":{\"message\":\"\(msg)\",\"type\":\"server_error\"}}"

            case .text(let text):
                let escaped = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
                responseJSON = """
                {
                  "id": "chatcmpl-mock-\(UUID().uuidString.prefix(6))",
                  "object": "chat.completion",
                  "created": 1700000000,
                  "model": "qwen2.5-coder-7b-instruct",
                  "choices": [
                    {
                      "index": 0,
                      "message": {
                        "role": "assistant",
                        "content": "\(escaped)"
                      },
                      "finish_reason": "stop"
                    }
                  ],
                  "usage": {
                    "prompt_tokens": 50,
                    "completion_tokens": 20,
                    "total_tokens": 70
                  }
                }
                """

            case .toolCalls(let tools):
                var toolCallsJSON: [String] = []
                for tool in tools {
                    let escapedArgs = tool.arguments.replacingOccurrences(of: "\"", with: "\\\"")
                    toolCallsJSON.append("""
                    {
                      "id": "\(tool.id)",
                      "type": "function",
                      "function": {
                        "name": "\(tool.name)",
                        "arguments": "\(escapedArgs)"
                      }
                    }
                    """)
                }
                let joinedTools = toolCallsJSON.joined(separator: ",\n")

                responseJSON = """
                {
                  "id": "chatcmpl-mock-\(UUID().uuidString.prefix(6))",
                  "object": "chat.completion",
                  "created": 1700000000,
                  "model": "qwen2.5-coder-7b-instruct",
                  "choices": [
                    {
                      "index": 0,
                      "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [
                          \(joinedTools)
                        ]
                      },
                      "finish_reason": "tool_calls"
                    }
                  ],
                  "usage": {
                    "prompt_tokens": 80,
                    "completion_tokens": 30,
                    "total_tokens": 110
                  }
                }
                """
            }
        }

        let bodyBytes = Data(responseJSON.utf8)
        let headerResponse = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
        var fullResponse = Data(headerResponse.utf8)
        fullResponse.append(bodyBytes)

        connection.send(content: fullResponse, completion: .contentProcessed { [weak self, weak connection] _ in
            connection?.cancel()
            if let conn = connection {
                self?.removeConnection(conn)
            }
        })
    }
}
