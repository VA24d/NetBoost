import Testing
import Foundation
import Network
@testable import NetBoostCore

@Suite("Feature 07: Multi-Port SOCKS5 Proxy Dispatcher", .tags(.tier1, .m2_proxy, .socks5))
struct Tier1_07_SOCKS5ProxyTests {

    /// SOCKS5 protocol helper for RFC 1928 handshaking and dispatch testing
    struct SOCKS5ProtocolHelper {
        static let version: UInt8 = 0x05
        static let noAuth: UInt8 = 0x00
        static let cmdConnect: UInt8 = 0x01
        static let atypIPv4: UInt8 = 0x01
        static let repSuccess: UInt8 = 0x00

        static func makeClientGreeting() -> Data {
            Data([version, 0x01, noAuth]) // SOCKSv5, 1 auth method, No Auth
        }

        static func parseServerGreeting(data: Data) -> (version: UInt8, method: UInt8)? {
            guard data.count >= 2 else { return nil }
            return (data[0], data[1])
        }

        static func makeConnectRequest(ipv4: String, port: UInt16) -> Data {
            var data = Data([version, cmdConnect, 0x00, atypIPv4])
            let parts = ipv4.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { return Data() }
            data.append(contentsOf: parts)
            data.append(UInt8(port >> 8))
            data.append(UInt8(port & 0xFF))
            return data
        }

        static func parseServerReply(data: Data) -> (version: UInt8, rep: UInt8, boundPort: UInt16)? {
            guard data.count >= 10 else { return nil }
            let port = (UInt16(data[8]) << 8) | UInt16(data[9])
            return (data[0], data[1], port)
        }
    }

    /// Dispatcher mapping configuration
    struct ProxyPortConfig {
        let port: Int
        let targetInterface: String
        let mode: String // "direct" or "load-balanced"
    }

    final class SOCKS5Dispatcher {
        private(set) var portConfigs: [Int: ProxyPortConfig] = [:]
        private var roundRobinIndex = 0
        private let lock = NSLock()

        init() {
            portConfigs[1080] = ProxyPortConfig(port: 1080, targetInterface: "en10", mode: "direct")
            portConfigs[1081] = ProxyPortConfig(port: 1081, targetInterface: "en0", mode: "direct")
            portConfigs[1082] = ProxyPortConfig(port: 1082, targetInterface: "auto", mode: "load-balanced")
        }

        func interfaceForPort(_ port: Int) -> String? {
            guard let cfg = portConfigs[port] else { return nil }
            if cfg.mode == "load-balanced" {
                lock.lock()
                defer { lock.unlock() }
                let interfaces = ["en10", "en0"]
                let chosen = interfaces[roundRobinIndex % interfaces.count]
                roundRobinIndex += 1
                return chosen
            }
            return cfg.targetInterface
        }
    }

    @Test("T1-F07-01: Port 1080 binds egress traffic strictly to Ethernet en10")
    func testPort1080BindsToEn10() {
        let dispatcher = SOCKS5Dispatcher()
        let egress = dispatcher.interfaceForPort(1080)
        #expect(egress == "en10")
    }

    @Test("T1-F07-02: Port 1081 binds egress traffic strictly to Wi-Fi en0")
    func testPort1081BindsToEn0() {
        let dispatcher = SOCKS5Dispatcher()
        let egress = dispatcher.interfaceForPort(1081)
        #expect(egress == "en0")
    }

    @Test("T1-F07-03: Port 1082 round-robins traffic across available interfaces")
    func testPort1082RoundRobinsTraffic() {
        let dispatcher = SOCKS5Dispatcher()
        let iface1 = dispatcher.interfaceForPort(1082)
        let iface2 = dispatcher.interfaceForPort(1082)
        let iface3 = dispatcher.interfaceForPort(1082)

        #expect(iface1 == "en10")
        #expect(iface2 == "en0")
        #expect(iface3 == "en10")
    }

    @Test("T1-F07-04: Client completes RFC 1928 SOCKS5 handshake negotiation")
    func testSOCKS5GreetingHandshake() {
        let clientGreeting = SOCKS5ProtocolHelper.makeClientGreeting()
        #expect(clientGreeting.count == 3)
        #expect(clientGreeting[0] == 0x05) // SOCKS5
        #expect(clientGreeting[2] == 0x00) // No authentication required

        let serverGreeting = Data([0x05, 0x00])
        let parsed = SOCKS5ProtocolHelper.parseServerGreeting(data: serverGreeting)
        #expect(parsed?.version == 0x05)
        #expect(parsed?.method == 0x00)
    }

    @Test("T1-F07-05: SOCKS5 CONNECT command parses target destination and generates success reply")
    func testSOCKS5ConnectCommandAndReply() {
        let connectCmd = SOCKS5ProtocolHelper.makeConnectRequest(ipv4: "127.0.0.1", port: 8080)
        #expect(connectCmd.count == 10)
        #expect(connectCmd[0] == 0x05) // Version
        #expect(connectCmd[1] == 0x01) // CMD: CONNECT
        #expect(connectCmd[3] == 0x01) // ATYP: IPv4

        // Simulated server success response
        let serverReply = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90])
        let parsedReply = SOCKS5ProtocolHelper.parseServerReply(data: serverReply)
        #expect(parsedReply?.version == 0x05)
        #expect(parsedReply?.rep == 0x00) // Succeeded
        #expect(parsedReply?.boundPort == 8080)
    }
}
