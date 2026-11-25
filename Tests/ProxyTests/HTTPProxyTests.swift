import Foundation
import Testing
import Darwin
@testable import NetBoostCore

@Suite("HTTP Proxy Unit & Integration Tests")
struct HTTPProxyTests {

    @Test("HTTP Proxy request line parser: CONNECT method")
    func testParseConnectRequest() {
        let raw = "CONNECT turing.iiit.ac.in:443 HTTP/1.1\r\nHost: turing.iiit.ac.in:443\r\n\r\n"
        let parsed = HTTPProxyServer.parseRequest(raw)
        #expect(parsed == .connect(host: "turing.iiit.ac.in", port: 443))

        let defaultPortRaw = "CONNECT campus.internal HTTP/1.1\r\nHost: campus.internal\r\n\r\n"
        let defaultParsed = HTTPProxyServer.parseRequest(defaultPortRaw)
        #expect(defaultParsed == .connect(host: "campus.internal", port: 443))

        let ipv6Raw = "CONNECT [::1]:443 HTTP/1.1\r\nHost: [::1]:443\r\n\r\n"
        #expect(HTTPProxyServer.parseRequest(ipv6Raw) == .connect(host: "::1", port: 443))

        let ipv6DefaultRaw = "CONNECT [2001:db8::1] HTTP/1.1\r\nHost: [2001:db8::1]\r\n\r\n"
        #expect(HTTPProxyServer.parseRequest(ipv6DefaultRaw) == .connect(host: "2001:db8::1", port: 443))
    }

    @Test("HTTP Proxy request line parser: Standard GET and keep-alive header")
    func testParseStandardGetRequest() {
        let raw = "GET http://turing.iiit.ac.in/api/status HTTP/1.1\r\nHost: turing.iiit.ac.in\r\nProxy-Connection: keep-alive\r\n\r\n"
        let parsed = HTTPProxyServer.parseRequest(raw)
        #expect(parsed == .standard(method: "GET", url: "http://turing.iiit.ac.in/api/status", keepAlive: true))

        let rawClose = "POST http://turing.iiit.ac.in/api/jobs HTTP/1.1\r\nHost: turing.iiit.ac.in\r\nConnection: close\r\n\r\n"
        let parsedClose = HTTPProxyServer.parseRequest(rawClose)
        #expect(parsedClose == .standard(method: "POST", url: "http://turing.iiit.ac.in/api/jobs", keepAlive: false))
    }

    @Test("HTTP Proxy request parser rejects malformed inputs")
    func testParseInvalidRequests() {
        #expect(HTTPProxyServer.parseRequest("") == .invalid)
        #expect(HTTPProxyServer.parseRequest("INVALID") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT :443 HTTP/1.1") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT target:99999 HTTP/1.1") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT target:invalidPort HTTP/1.1") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT []:443 HTTP/1.1") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT [::1]: HTTP/1.1") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT [::1]:99999 HTTP/1.1") == .invalid)
        #expect(HTTPProxyServer.parseRequest("CONNECT [::1 HTTP/1.1") == .invalid)
    }

    @Test("HTTP Proxy response message formatting")
    func testResponseFormatting() {
        let connectResp = HTTPProxyServer.makeConnectSuccessResponse()
        #expect(connectResp == "HTTP/1.1 200 Connection Established\r\nProxy-Agent: NetBoost/1.0\r\n\r\n")

        let badResp = HTTPProxyServer.makeBadRequestResponse()
        #expect(badResp.contains("400 Bad Request"))

        let timeoutResp = HTTPProxyServer.makeGatewayTimeoutResponse()
        #expect(timeoutResp.contains("504 Gateway Timeout"))

        let largeResp = HTTPProxyServer.makePayloadTooLargeResponse()
        #expect(largeResp.contains("431 Request Header Fields Too Large"))
    }

    @Test("Live HTTP Proxy: CONNECT tunneling with raw byte streaming")
    func testLiveHTTPConnectTunneling() async throws {
        // 1. Mock server
        let mockTarget = MockSOCKS5TargetServer(mode: .rawEcho)
        let targetPort = try await mockTarget.start()
        defer { mockTarget.stop() }

        // 2. HTTP Proxy on ephemeral port
        let proxy = HTTPProxyServer(port: 0, targetInterface: "lo0")
        try await proxy.start()
        defer { proxy.stop() }
        let proxyPort = proxy.boundPort

        #expect(proxy.isRunning == true)

        // 3. Connect client socket
        let clientFd = socket(AF_INET, SOCK_STREAM, 0)
        guard clientFd >= 0 else {
            Issue.record("Failed to create client socket")
            return
        }
        defer { Darwin.close(clientFd) }
        var one: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connRes == 0)

        // 4. Send CONNECT request
        let connectReq = "CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n"
        let reqData = Data(connectReq.utf8)
        _ = reqData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, reqData.count) }

        // 5. Read 200 Connection Established
        var respBuf = [UInt8](repeating: 0, count: 128)
        let readRespCount = Darwin.read(clientFd, &respBuf, respBuf.count)
        #expect(readRespCount > 0)
        let respString = String(decoding: respBuf.prefix(readRespCount), as: UTF8.self)
        #expect(respString.hasPrefix("HTTP/1.1 200 Connection Established"))
        #expect(respString.contains("Proxy-Agent: NetBoost/1.0"))

        // 6. Send payload through transparent tunnel
        let payload = "NetBoost HTTP CONNECT Raw Tunnel Payload\n"
        let payloadData = Data(payload.utf8)
        _ = payloadData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, payloadData.count) }

        var echoBuf = [UInt8](repeating: 0, count: payloadData.count)
        let readEchoCount = Darwin.read(clientFd, &echoBuf, payloadData.count)
        #expect(readEchoCount == payloadData.count)
        let echoedString = String(decoding: echoBuf, as: UTF8.self)
        #expect(echoedString == payload)

        _ = Darwin.shutdown(clientFd, SHUT_RDWR)
    }

    @Test("Live HTTP Proxy: Direct GET request forwarding and origin-form rewriting")
    func testLiveHTTPDirectGetProxying() async throws {
        let mockTarget = MockSOCKS5TargetServer(mode: .httpEcho)
        let targetPort = try await mockTarget.start()
        defer { mockTarget.stop() }

        let proxy = HTTPProxyServer(port: 0, targetInterface: "lo0")
        try await proxy.start()
        defer { proxy.stop() }
        let proxyPort = proxy.boundPort

        let clientFd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(clientFd) }
        var one: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let getReq = "GET http://127.0.0.1:\(targetPort)/campus-status HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Connection: keep-alive\r\n\r\n"
        let getReqData = Data(getReq.utf8)
        _ = getReqData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, getReqData.count) }

        var respBuf = [UInt8](repeating: 0, count: 512)
        let readCount = Darwin.read(clientFd, &respBuf, respBuf.count)
        #expect(readCount > 0)
        let respString = String(decoding: respBuf.prefix(readCount), as: UTF8.self)
        #expect(respString.contains("HTTP/1.1 200 OK"))
        #expect(respString.contains("Echo: Received"))

        _ = Darwin.shutdown(clientFd, SHUT_RDWR)
    }

    @Test("Live HTTP Proxy: Header exceeding 64KB is rejected with 431")
    func testHeaderExceedingLimitRejection() async throws {
        let proxy = HTTPProxyServer(port: 0, targetInterface: "lo0")
        try await proxy.start()
        defer { proxy.stop() }
        let proxyPort = proxy.boundPort

        let clientFd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(clientFd) }
        var one: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Send 66KB of headers without \r\n\r\n
        let hugeHeader = String(repeating: "X-Test-Header: Value\r\n", count: 3000)
        let headerData = Data(hugeHeader.utf8)
        #expect(headerData.count > 65536)

        _ = headerData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, headerData.count) }

        var respBuf = [UInt8](repeating: 0, count: 256)
        let readCount = Darwin.read(clientFd, &respBuf, respBuf.count)
        #expect(readCount > 0)
        let respString = String(decoding: respBuf.prefix(readCount), as: UTF8.self)
        #expect(respString.contains("431 Request Header Fields Too Large"))
    }

    @Test("Live HTTP Proxy: POST forwards UTF-8 and raw binary bodies once without duplication")
    func testLiveHTTPPostBinaryAndNoDuplication() async throws {
        let mockTarget = MockSOCKS5TargetServer(mode: .rawEcho)
        let targetPort = try await mockTarget.start()
        defer { mockTarget.stop() }

        let proxy = HTTPProxyServer(port: 0, targetInterface: "lo0")
        try await proxy.start()
        defer { proxy.stop() }
        let proxyPort = proxy.boundPort

        // Send a POST with non-UTF8 binary bytes immediately after \r\n\r\n
        let binaryBody = Data([0xFF, 0xFE, 0x00, 0x80, 0x99, 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02])
        let headerStr = "POST http://127.0.0.1:\(targetPort)/upload HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\nContent-Length: \(binaryBody.count)\r\nProxy-Connection: keep-alive\r\n\r\n"
        var fullRequest = Data(headerStr.utf8)
        fullRequest.append(binaryBody)

        let clientFd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(clientFd) }
        var one: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connRes == 0)

        _ = fullRequest.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, fullRequest.count) }

        let expectedPrefix = Data("POST /upload HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\nContent-Length: \(binaryBody.count)\r\nConnection: keep-alive\r\n\r\n".utf8)
        var expectedEcho = expectedPrefix
        expectedEcho.append(binaryBody)

        var received = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while received.count < expectedEcho.count {
            let n = Darwin.read(clientFd, &buf, buf.count)
            if n <= 0 { break }
            received.append(buf, count: n)
        }
        _ = Darwin.shutdown(clientFd, SHUT_RDWR)

        #expect(received == expectedEcho)
        #expect(received.count == expectedEcho.count)
    }

    @Test("Live HTTP Proxy: CONNECT [::1]:port connects over IPv6 loopback")
    func testLiveHTTPConnectIPv6() async throws {
        // Start an IPv6 TCP echo listener on ::1
        let targetFd = socket(AF_INET6, SOCK_STREAM, 0)
        guard targetFd >= 0 else {
            Issue.record("Failed to create IPv6 socket")
            return
        }
        defer { Darwin.close(targetFd) }
        var one: Int32 = 1
        setsockopt(targetFd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var v6Addr = sockaddr_in6()
        v6Addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6Addr.sin6_family = sa_family_t(AF_INET6)
        v6Addr.sin6_port = 0
        v6Addr.sin6_addr = in6addr_loopback

        let bindRes = withUnsafePointer(to: &v6Addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(targetFd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindRes == 0, Darwin.listen(targetFd, 4) == 0 else {
            // Skip gracefully if IPv6 loopback bind is disabled in environment
            return
        }

        var boundAddr = sockaddr_in6()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(targetFd, sa, &boundLen)
            }
        }
        let targetPort = Int(UInt16(bigEndian: boundAddr.sin6_port))

        let acceptTask = Task.detached {
            var pfd = pollfd(fd: targetFd, events: Int16(POLLIN), revents: 0)
            let pollRes = Darwin.poll(&pfd, 1, 3000)
            guard pollRes > 0 else { return }

            var client = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let conn = withUnsafeMutablePointer(to: &client) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(targetFd, sa, &len)
                }
            }
            if conn >= 0 {
                var buf = [UInt8](repeating: 0, count: 64)
                let n = Darwin.read(conn, &buf, buf.count)
                if n > 0 {
                    _ = buf.prefix(n).withUnsafeBytes { ptr in
                        Darwin.write(conn, ptr.baseAddress!, n)
                    }
                }
                Darwin.close(conn)
            }
        }

        let proxy = HTTPProxyServer(port: 0, targetInterface: "lo0")
        try await proxy.start()
        defer { proxy.stop() }

        let clientFd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(clientFd) }
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxy.boundPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connRes == 0)

        let reqData = Data("CONNECT [::1]:\(targetPort) HTTP/1.1\r\nHost: [::1]:\(targetPort)\r\n\r\n".utf8)
        _ = reqData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, reqData.count) }

        var respBuf = [UInt8](repeating: 0, count: 128)
        let n = Darwin.read(clientFd, &respBuf, respBuf.count)
        #expect(n > 0)
        let respStr = String(decoding: respBuf.prefix(n), as: UTF8.self)
        #expect(respStr.hasPrefix("HTTP/1.1 200 Connection Established"))

        let ping = Data("v6ok".utf8)
        _ = ping.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, ping.count) }
        var echoBuf = [UInt8](repeating: 0, count: 4)
        let echoN = Darwin.read(clientFd, &echoBuf, 4)
        #expect(echoN == 4)
        #expect(String(decoding: echoBuf, as: UTF8.self) == "v6ok")

        _ = Darwin.shutdown(clientFd, SHUT_RDWR)
        await acceptTask.value
    }
}
