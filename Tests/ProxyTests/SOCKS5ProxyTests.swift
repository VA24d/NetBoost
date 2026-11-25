import Foundation
import Testing
import Darwin
@testable import NetBoostCore

@Suite("SOCKS5 Proxy Unit & Integration Tests")
struct SOCKS5ProxyTests {

    @Test("SOCKS5 protocol version validation")
    func testVersionValidation() {
        #expect(SOCKS5Server.validateVersion(0x05) == true)
        #expect(SOCKS5Server.validateVersion(0x04) == false)
        #expect(SOCKS5Server.validateVersion(0x00) == false)
        #expect(SOCKS5Server.validateVersion(0x06) == false)
    }

    @Test("SOCKS5 auth method negotiation selects No Auth (0x00) or rejects (0xFF)")
    func testAuthMethodNegotiation() {
        #expect(SOCKS5Server.selectAuthMethod(offered: [0x00]) == 0x00)
        #expect(SOCKS5Server.selectAuthMethod(offered: [0x02, 0x00, 0x01]) == 0x00)
        #expect(SOCKS5Server.selectAuthMethod(offered: [0x02]) == 0xFF)
        #expect(SOCKS5Server.selectAuthMethod(offered: []) == 0xFF)
    }

    @Test("SOCKS5 address type classification")
    func testAddressTypeParsing() {
        #expect(SOCKS5Server.parseAddressType(0x01) == "IPv4")
        #expect(SOCKS5Server.parseAddressType(0x03) == "Domain")
        #expect(SOCKS5Server.parseAddressType(0x04) == "IPv6")
        #expect(SOCKS5Server.parseAddressType(0x00) == nil)
        #expect(SOCKS5Server.parseAddressType(0x08) == nil)
    }

    @Test("POSIX error code mapping to SOCKS5 reply codes")
    func testPOSIXErrorMapping() {
        #expect(SOCKS5Server.mapPOSIXErrorToSOCKS5Reply(errno: ENETUNREACH) == 0x03)
        #expect(SOCKS5Server.mapPOSIXErrorToSOCKS5Reply(errno: EHOSTUNREACH) == 0x04)
        #expect(SOCKS5Server.mapPOSIXErrorToSOCKS5Reply(errno: ECONNREFUSED) == 0x05)
        #expect(SOCKS5Server.mapPOSIXErrorToSOCKS5Reply(errno: ETIMEDOUT) == 0x06)
        #expect(SOCKS5Server.mapPOSIXErrorToSOCKS5Reply(errno: EPERM) == 0x01)
    }

    @Test("Live SOCKS5 Server: Handshake, CONNECT command, and raw echo tunneling")
    func testLiveSOCKS5ServerEcho() async throws {
        // 1. Start mock target echo server
        let mockTarget = MockSOCKS5TargetServer(mode: .rawEcho)
        let targetPort = try await mockTarget.start()
        defer { mockTarget.stop() }

        #expect(targetPort > 0)

        // 2. Start SOCKS5 proxy server on ephemeral port (0)
        let proxy = SOCKS5Server(port: 0, targetInterface: "lo0")
        try await proxy.start()
        defer { proxy.stop() }

        let proxyPort = proxy.boundPort
        #expect(proxyPort > 0)
        #expect(proxy.isRunning == true)

        // 3. Connect client socket to proxy
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

        // 4. Send client greeting: VER=0x05, NMETHODS=1, METHOD=0x00
        let greeting = Data([0x05, 0x01, 0x00])
        _ = greeting.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, greeting.count) }

        // Read server greeting
        var greetingResp = [UInt8](repeating: 0, count: 2)
        let readGreetingCount = Darwin.read(clientFd, &greetingResp, 2)
        #expect(readGreetingCount == 2)
        #expect(greetingResp[0] == 0x05)
        #expect(greetingResp[1] == 0x00)

        // 5. Send CONNECT command: VER=0x05, CMD=0x01, RSV=0x00, ATYP=0x01, IP=127.0.0.1, Port=targetPort
        var connectReq = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        connectReq.append(UInt8((targetPort >> 8) & 0xFF))
        connectReq.append(UInt8(targetPort & 0xFF))
        _ = connectReq.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, connectReq.count) }

        // Read server connect reply (10 bytes)
        var connectReply = [UInt8](repeating: 0, count: 10)
        let readReplyCount = Darwin.read(clientFd, &connectReply, 10)
        #expect(readReplyCount == 10)
        #expect(connectReply[0] == 0x05) // VER
        #expect(connectReply[1] == 0x00) // REP: Succeeded
        #expect(connectReply[3] == 0x01) // ATYP: IPv4

        // 6. Test bidirectional data exchange
        let testPayload = "NetBoost SOCKS5 Bidirectional Tunnel Test Data\n"
        let payloadData = Data(testPayload.utf8)
        _ = payloadData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, payloadData.count) }

        var echoBuffer = [UInt8](repeating: 0, count: payloadData.count)
        let echoReadCount = Darwin.read(clientFd, &echoBuffer, payloadData.count)
        #expect(echoReadCount == payloadData.count)
        let echoedString = String(decoding: echoBuffer, as: UTF8.self)
        #expect(echoedString == testPayload)

        _ = Darwin.shutdown(clientFd, SHUT_RDWR)

        // 7. Verify mock server tracking
        #expect(mockTarget.totalBytesReceived > 0)
        #expect(mockTarget.totalBytesSent > 0)
    }

    @Test("Live SOCKS5 Server: Domain Name (ATYP 0x03) target resolution")
    func testLiveSOCKS5DomainConnect() async throws {
        let mockTarget = MockSOCKS5TargetServer(mode: .rawEcho)
        let targetPort = try await mockTarget.start()
        defer { mockTarget.stop() }

        let proxy = SOCKS5Server(port: 0, targetInterface: "lo0")
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

        let connRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connRes == 0)

        // Handshake
        let greeting = Data([0x05, 0x01, 0x00])
        _ = greeting.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, greeting.count) }
        var greetingResp = [UInt8](repeating: 0, count: 2)
        _ = Darwin.read(clientFd, &greetingResp, 2)
        #expect(greetingResp[1] == 0x00)

        // CONNECT with ATYP 0x03: "localhost"
        let domain = "localhost"
        var connectReq = Data([0x05, 0x01, 0x00, 0x03, UInt8(domain.utf8.count)])
        connectReq.append(contentsOf: domain.utf8)
        connectReq.append(UInt8((targetPort >> 8) & 0xFF))
        connectReq.append(UInt8(targetPort & 0xFF))
        _ = connectReq.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, connectReq.count) }

        var connectReply = [UInt8](repeating: 0, count: 10)
        let readReplyCount = Darwin.read(clientFd, &connectReply, 10)
        #expect(readReplyCount == 10)
        #expect(connectReply[1] == 0x00) // Succeeded

        _ = Darwin.shutdown(clientFd, SHUT_RDWR)
    }

    @Test("Live SOCKS5 Server: Target connection to closed port returns 0x05 Connection Refused")
    func testTargetConnectionRefusedReply() async throws {
        let proxy = SOCKS5Server(port: 0, targetInterface: "lo0")
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

        // Handshake
        let greeting = Data([0x05, 0x01, 0x00])
        _ = greeting.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, greeting.count) }
        var greetingResp = [UInt8](repeating: 0, count: 2)
        _ = Darwin.read(clientFd, &greetingResp, 2)

        // Connect to port 1 (which is closed on loopback)
        let connectReq = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 1])
        _ = connectReq.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, connectReq.count) }

        var reply = [UInt8](repeating: 0, count: 10)
        let replyCount = Darwin.read(clientFd, &reply, 10)
        #expect(replyCount == 10)
        #expect(reply[0] == 0x05)
        #expect(reply[1] == 0x05) // Connection refused
    }

    @Test("Live SOCKS5 Server: Unsupported command (0x02 BIND) returns 0x07")
    func testUnsupportedCommandReply() async throws {
        let proxy = SOCKS5Server(port: 0, targetInterface: "lo0")
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

        // Handshake
        let greeting = Data([0x05, 0x01, 0x00])
        _ = greeting.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, greeting.count) }
        var greetingResp = [UInt8](repeating: 0, count: 2)
        _ = Darwin.read(clientFd, &greetingResp, 2)

        // CMD: 0x02 (BIND)
        let bindReq = Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80])
        _ = bindReq.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, bindReq.count) }

        var reply = [UInt8](repeating: 0, count: 10)
        let replyCount = Darwin.read(clientFd, &reply, 10)
        #expect(replyCount == 10)
        #expect(reply[1] == 0x07) // Command not supported
    }

    @Test("Live SOCKS5 Server: Bidirectional byte attribution never swaps asymmetric counts")
    func testBidirectionalByteAttributionAccuracy() async throws {
        let serverReply = Data(repeating: 0xAB, count: 512)
        let mockTarget = MockSOCKS5TargetServer(mode: .fixedData(serverReply))
        let targetPort = try await mockTarget.start()
        defer { mockTarget.stop() }

        let proxy = SOCKS5Server(port: 0, targetInterface: "lo0")
        try await proxy.start()
        defer { proxy.stop() }

        let clientFd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(clientFd) }
        var one: Int32 = 1
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

        // Handshake + CONNECT
        let greeting = Data([0x05, 0x01, 0x00])
        _ = greeting.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, greeting.count) }
        var greetResp = [UInt8](repeating: 0, count: 2)
        _ = Darwin.read(clientFd, &greetResp, 2)

        var connectReq = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        connectReq.append(UInt8((targetPort >> 8) & 0xFF))
        connectReq.append(UInt8(targetPort & 0xFF))
        _ = connectReq.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, connectReq.count) }
        var reply = [UInt8](repeating: 0, count: 10)
        _ = Darwin.read(clientFd, &reply, 10)
        #expect(reply[1] == 0x00)

        // Client sends 64 bytes; target replies with 512 bytes
        let clientPayload = Data(repeating: 0x01, count: 64)
        _ = clientPayload.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, clientPayload.count) }

        var received = Data()
        var buf = [UInt8](repeating: 0, count: 512)
        while received.count < 512 {
            let n = Darwin.read(clientFd, &buf, buf.count)
            if n <= 0 { break }
            received.append(buf, count: n)
        }
        #expect(received == serverReply)

        _ = Darwin.shutdown(clientFd, SHUT_RDWR)

        let settled = try await TestAssertions.pollUntil(timeout: 2.0) {
            proxy.totalBytesRead == 64 && proxy.totalBytesWritten == 512
        }
        #expect(settled)
        #expect(proxy.totalBytesRead == 64)
        #expect(proxy.totalBytesWritten == 512)
    }
}
