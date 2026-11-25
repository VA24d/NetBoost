import Foundation
import Testing
import Darwin
@testable import NetBoostCore

@Suite("Interface Proxy Dispatcher Unit & Integration Tests")
struct InterfaceProxyDispatcherTests {

    @Test("Dispatcher default port configurations")
    func testDefaultPortConfigurations() {
        let dispatcher = InterfaceProxyDispatcher()
        let config1080 = dispatcher.portConfigs[1080]
        let config1081 = dispatcher.portConfigs[1081]
        let config1082 = dispatcher.portConfigs[1082]

        #expect(config1080?.targetInterface == "en10")
        #expect(config1080?.mode == .direct)

        #expect(config1081?.targetInterface == "en0")
        #expect(config1081?.mode == .direct)

        #expect(config1082?.targetInterface == "auto")
        #expect(config1082?.mode == .loadBalanced)
    }

    @Test("Port 1082 round-robins across available interfaces")
    func testRoundRobinLoadBalancing() {
        let dispatcher = InterfaceProxyDispatcher(
            ports: [1082: "auto"],
            loadBalancedInterfaces: ["en10", "en0"]
        )

        let if1 = dispatcher.interfaceForPort(1082)
        let if2 = dispatcher.interfaceForPort(1082)
        let if3 = dispatcher.interfaceForPort(1082)
        let if4 = dispatcher.interfaceForPort(1082)

        #expect(if1 == "en10")
        #expect(if2 == "en0")
        #expect(if3 == "en10")
        #expect(if4 == "en0")
    }

    @Test("Custom multi-interface load balancing (en10, en0, en9)")
    func testMultiInterfaceLoadBalancing() {
        let dispatcher = InterfaceProxyDispatcher(
            ports: [1082: "auto"],
            loadBalancedInterfaces: ["en10", "en0", "en9"]
        )

        #expect(dispatcher.nextLoadBalancedInterface() == "en10")
        #expect(dispatcher.nextLoadBalancedInterface() == "en0")
        #expect(dispatcher.nextLoadBalancedInterface() == "en9")
        #expect(dispatcher.nextLoadBalancedInterface() == "en10")
    }

    @Test("Shell snippet generation for proxy ports")
    func testShellSnippetGeneration() {
        let dispatcher = InterfaceProxyDispatcher()
        #expect(dispatcher.generateShellSnippet(port: 1080) == "export ALL_PROXY=socks5://127.0.0.1:1080")
        #expect(dispatcher.generateShellSnippet(port: 1081) == "export ALL_PROXY=socks5://127.0.0.1:1081")
        #expect(dispatcher.generateShellSnippet(port: 1082) == "export ALL_PROXY=socks5://127.0.0.1:1082")
    }

    @Test("Port collision detection throws ProxyError.portAlreadyInUse")
    func testPortCollisionDetection() async throws {
        let firstServer = SOCKS5Server(port: 0, targetInterface: "lo0")
        try await firstServer.start()
        defer { firstServer.stop() }
        let occupiedPort = firstServer.boundPort

        let dispatcher = InterfaceProxyDispatcher()
        await #expect(throws: ProxyError.self) {
            try await dispatcher.start(ports: [occupiedPort: "lo0"])
        }
    }

    @Test("Live Dispatcher: Dual-protocol auto-detection on identical port")
    func testDualProtocolAutoDetection() async throws {
        let mockTarget = MockSOCKS5TargetServer(mode: .rawEcho)
        let targetPort = try await mockTarget.start()
        defer { mockTarget.stop() }

        let dispatcher = InterfaceProxyDispatcher(
            ports: [0: "lo0"],
            loadBalancedInterfaces: ["lo0"]
        )
        try await dispatcher.start(ports: [0: "lo0"])
        defer {
            Task { try? await dispatcher.stop() }
        }

        let testPort = dispatcher.boundPorts[0] ?? 0
        #expect(testPort > 0)
        #expect(dispatcher.isRunning == true)

        // 1. First client connects using SOCKS5 protocol
        do {
            let clientFd = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(clientFd) }
            var one: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(testPort).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let connRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            #expect(connRes == 0)

            // SOCKS5 Greeting: 0x05, 0x01, 0x00
            let greeting = Data([0x05, 0x01, 0x00])
            _ = greeting.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, greeting.count) }

            var greetResp = [UInt8](repeating: 0, count: 2)
            _ = Darwin.read(clientFd, &greetResp, 2)
            #expect(greetResp[0] == 0x05)
            #expect(greetResp[1] == 0x00)

            // SOCKS5 CONNECT to targetPort
            var connectReq = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
            connectReq.append(UInt8((targetPort >> 8) & 0xFF))
            connectReq.append(UInt8(targetPort & 0xFF))
            _ = connectReq.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, connectReq.count) }

            var connectResp = [UInt8](repeating: 0, count: 10)
            _ = Darwin.read(clientFd, &connectResp, 10)
            #expect(connectResp[1] == 0x00) // Succeeded

            // Send payload through tunnel
            let payload = "SOCKS5 Tunnel Through Unified Dispatcher Port\n"
            let pData = Data(payload.utf8)
            _ = pData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, pData.count) }

            var echoBuf = [UInt8](repeating: 0, count: pData.count)
            let readEcho = Darwin.read(clientFd, &echoBuf, pData.count)
            #expect(readEcho == pData.count)
            #expect(String(decoding: echoBuf, as: UTF8.self) == payload)

            _ = Darwin.shutdown(clientFd, SHUT_RDWR)
        }

        // 2. Second client connects using HTTP CONNECT on the EXACT SAME port
        do {
            let clientFd = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(clientFd) }
            var one: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(testPort).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let connRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            #expect(connRes == 0)

            // Send HTTP CONNECT
            let httpReq = "CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n"
            let reqData = Data(httpReq.utf8)
            _ = reqData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, reqData.count) }

            var respBuf = [UInt8](repeating: 0, count: 128)
            let readCount = Darwin.read(clientFd, &respBuf, respBuf.count)
            #expect(readCount > 0)
            let respStr = String(decoding: respBuf.prefix(readCount), as: UTF8.self)
            #expect(respStr.hasPrefix("HTTP/1.1 200 Connection Established"))

            // Send payload through tunnel
            let payload = "HTTP CONNECT Tunnel Through Unified Dispatcher Port\n"
            let pData = Data(payload.utf8)
            _ = pData.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, pData.count) }

            var echoBuf = [UInt8](repeating: 0, count: pData.count)
            let readEcho = Darwin.read(clientFd, &echoBuf, pData.count)
            #expect(readEcho == pData.count)
            #expect(String(decoding: echoBuf, as: UTF8.self) == payload)

            _ = Darwin.shutdown(clientFd, SHUT_RDWR)
        }

        // 3. Verify live activeConnections metrics (targetHost, targetPort, bytesRead, bytesWritten)
        do {
            let serverReply = Data(repeating: 0x5A, count: 256)
            let asymmetricTarget = MockSOCKS5TargetServer(mode: .fixedData(serverReply))
            let asymPort = try await asymmetricTarget.start()
            defer { asymmetricTarget.stop() }

            let clientFd = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(clientFd) }
            var one: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(testPort).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let connRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(clientFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            #expect(connRes == 0)

            let httpReq = "CONNECT 127.0.0.1:\(asymPort) HTTP/1.1\r\nHost: 127.0.0.1:\(asymPort)\r\n\r\n"
            _ = Data(httpReq.utf8).withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, httpReq.utf8.count) }
            var respBuf = [UInt8](repeating: 0, count: 128)
            _ = Darwin.read(clientFd, &respBuf, respBuf.count)

            let clientSend = Data(repeating: 0x11, count: 32)
            _ = clientSend.withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress!, clientSend.count) }

            var echoRecv = Data()
            var buf = [UInt8](repeating: 0, count: 256)
            while echoRecv.count < 256 {
                let n = Darwin.read(clientFd, &buf, buf.count)
                if n <= 0 { break }
                echoRecv.append(buf, count: n)
            }
            #expect(echoRecv.count == 256)

            let liveUpdated = try await TestAssertions.pollUntil(timeout: 2.0) {
                guard let conn = dispatcher.activeConnections.first(where: { $0.targetPort == Int(asymPort) }) else {
                    return false
                }
                return conn.targetHost == "127.0.0.1" && conn.bytesRead == 32 && conn.bytesWritten == 256
            }
            #expect(liveUpdated)
            _ = Darwin.shutdown(clientFd, SHUT_RDWR)
        }

        try await dispatcher.stop()
        #expect(dispatcher.isRunning == false)
    }
}
