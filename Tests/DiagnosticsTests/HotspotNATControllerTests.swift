import Testing
import Foundation
import Darwin
@testable import NetBoostCore

@Suite("Hotspot Sharing: HotspotNATController Unit & Integration Tests")
struct HotspotNATControllerTests {

    @Test("SysctlForwardingController commands and state parsing")
    func testSysctlForwardingController() {
        let queryCmd = SysctlForwardingController.makeQueryCommand()
        #expect(queryCmd == ["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"])

        let enableCmd = SysctlForwardingController.makeEnableCommand()
        #expect(enableCmd == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"])

        let disableCmd = SysctlForwardingController.makeDisableCommand()
        #expect(disableCmd == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"])

        #expect(SysctlForwardingController.parseForwardingState(output: "1\n") == true)
        #expect(SysctlForwardingController.parseForwardingState(output: "1") == true)
        #expect(SysctlForwardingController.parseForwardingState(output: "0\n") == false)
        #expect(SysctlForwardingController.parseForwardingState(output: "0") == false)
    }

    @Test("PFNATAnchorManager generates exact isolated NAT anchor rules")
    func testPFNATAnchorRules() {
        let manager = PFNATAnchorManager(
            anchorName: "netboost",
            upstreamInterface: "en10",
            clientSubnet: "192.168.2.0/24"
        )

        let rule = manager.generateNATRule()
        #expect(rule.contains("nat on en10 from 192.168.2.0/24 to any -> (en10)"))
        #expect(rule.contains("pass out quick on en10 from 192.168.2.0/24 to any keep state"))

        let loadCmd = manager.makeLoadAnchorCommand(ruleFile: "/tmp/test.pf")
        #expect(loadCmd == ["/sbin/pfctl", "-a", "netboost", "-f", "/tmp/test.pf"])

        let enableCmd = manager.makeEnablePFCommand()
        #expect(enableCmd == ["/sbin/pfctl", "-e"])

        let flushCmd = manager.makeFlushAnchorCommand()
        #expect(flushCmd == ["/sbin/pfctl", "-a", "netboost", "-F", "all"])
    }

    @Test("HotspotNATController initial state and configuration defaults")
    func testHotspotInitialState() {
        let controller = HotspotNATController()
        #expect(controller.isActive == false)
        #expect(controller.configuration.ssid == "NetBoost")
        #expect(controller.configuration.password == "12345678")
        #expect(controller.configuration.subnet == "192.168.2.0/24")
        #expect(controller.configuration.gateway == "192.168.2.1")
        #expect(controller.configuration.upstreamInterface == "en10")
        #expect(controller.configuration.interfaceName == "en0")
    }

    @Test("NAT plist generation preserves dollar signs and quotes without shell expansion")
    func testNATPlistSpecialCharacters() async throws {
        let specialSSID = "Net$Boost\"'$(whoami)"
        let specialPassword = "P@ss$HOME\"'`$(rm -rf /)!1"
        let config = HotspotConfiguration(
            ssid: specialSSID,
            password: specialPassword,
            securityType: .wpa3Personal,
            subnet: "192.168.2.0/24",
            gateway: "192.168.2.1",
            interfaceName: "en0",
            upstreamInterface: "en10"
        )

        let plistData = try HotspotNATController.makeNATPropertyListData(
            configuration: config,
            upstreamInterface: "en10",
            downstreamInterface: "en0"
        )

        let tempFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("test_nat_\(UUID().uuidString).plist")
        try plistData.write(to: URL(fileURLWithPath: tempFile))
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let lint = try await ShellCommand.run("/usr/bin/plutil", arguments: ["-lint", tempFile])
        #expect(lint.succeeded)

        let parsed = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        let nat = parsed?["NAT"] as? [String: Any]
        let airport = nat?["AirPort"] as? [String: Any]

        #expect(nat?["Enabled"] as? Int == 1)
        #expect(nat?["PrimaryInterface"] as? String == "en10")
        #expect(nat?["SharingInterfaces"] as? [String] == ["AirPort", "en0"])
        #expect(airport?["NetworkName"] as? String == specialSSID)
        #expect(airport?["NetworkPassword"] as? String == specialPassword)
        #expect(airport?["SecurityType"] as? String == HotspotSecurityType.wpa3Personal.rawValue)
    }

    @Test("PFNATAnchorManager updates dynamically when HotspotNATController configuration changes")
    func testDynamicPFManagerUpdates() {
        let customPF = PFNATAnchorManager(anchorName: "custom_anchor", upstreamInterface: "en10", clientSubnet: "192.168.2.0/24")
        let controller = HotspotNATController(pfManager: customPF)

        #expect(controller.effectivePFManager().upstreamInterface == "en10")
        #expect(controller.effectivePFManager().anchorName == "custom_anchor")

        var updated = controller.configuration
        updated.upstreamInterface = "en12"
        updated.subnet = "192.168.3.0/24"
        controller.updateConfiguration(updated)

        let effective = controller.effectivePFManager()
        #expect(effective.anchorName == "custom_anchor")
        #expect(effective.upstreamInterface == "en12")
        #expect(effective.clientSubnet == "192.168.3.0/24")
        #expect(effective.generateNATRule().contains("nat on en12 from 192.168.3.0/24 to any -> (en12)"))
    }

    @Test("Start and stop commands target both netboost and com.apple/netboost anchors and guard bridge100")
    func testStartAndStopCommandsIncludeAppleAnchorAndBridge100Guard() throws {
        let controller = HotspotNATController()
        let startWithoutBridge = try controller.buildStartCommand(
            ruleFile: "/tmp/my rules.pf",
            natPlistFile: "/tmp/nat plist.plist",
            upstreamInterface: "en10",
            downstreamInterface: "en0",
            bridge100Active: false
        )
        #expect(startWithoutBridge.contains("/sbin/ifconfig 'en0' alias '192.168.2.1'"))
        #expect(startWithoutBridge.contains("/sbin/pfctl -a 'netboost' -f '/tmp/my rules.pf'"))
        #expect(startWithoutBridge.contains("/sbin/pfctl -a 'com.apple/netboost' -f '/tmp/my rules.pf'"))
        #expect(startWithoutBridge.contains("/usr/bin/defaults import /Library/Preferences/SystemConfiguration/com.apple.nat '/tmp/nat plist.plist'"))

        let startWithBridge = try controller.buildStartCommand(
            ruleFile: "/tmp/test.pf",
            natPlistFile: "/tmp/nat.plist",
            upstreamInterface: "en10",
            downstreamInterface: "en0",
            bridge100Active: true
        )
        #expect(!startWithBridge.contains("alias"))

        let stopCmd = try controller.buildStopCommand()
        #expect(stopCmd.contains("/sbin/pfctl -a 'netboost' -F all"))
        #expect(stopCmd.contains("/sbin/pfctl -a 'com.apple/netboost' -F all"))
    }

    @Test("Strict BSD interface, gateway, and subnet validation rejects injection strings")
    func testStrictInputValidation() async {
        let controller = HotspotNATController()

        await #expect(throws: PrivilegeError.self) {
            try await controller.startHotspot(upstreamInterface: "en10; rm -rf /", downstreamInterface: "en0")
        }
        await #expect(throws: PrivilegeError.self) {
            try await controller.startHotspot(upstreamInterface: "en10", downstreamInterface: "en0 && id")
        }

        var badGateway = HotspotConfiguration.default
        badGateway.gateway = "192.168.2.1; whoami"
        await #expect(throws: PrivilegeError.self) {
            try await controller.startHotspot(configuration: badGateway)
        }

        var badSubnet = HotspotConfiguration.default
        badSubnet.subnet = "192.168.2.0/99"
        await #expect(throws: PrivilegeError.self) {
            try await controller.startHotspot(configuration: badSubnet)
        }

        // Reject same upstream/downstream, loopback/virtual interfaces, /0 CIDR, and out-of-subnet gateway
        #expect(throws: PrivilegeError.self) {
            try HotspotNATController.validateConfiguration(
                upstreamInterface: "en10",
                downstreamInterface: "en10",
                gateway: "192.168.2.1",
                subnet: "192.168.2.0/24"
            )
        }
        #expect(throws: PrivilegeError.self) {
            try HotspotNATController.validateConfiguration(
                upstreamInterface: "lo0",
                downstreamInterface: "en0",
                gateway: "192.168.2.1",
                subnet: "192.168.2.0/24"
            )
        }
        #expect(throws: PrivilegeError.self) {
            try HotspotNATController.validateConfiguration(
                upstreamInterface: "en10",
                downstreamInterface: "en0",
                gateway: "192.168.2.1",
                subnet: "0.0.0.0/0"
            )
        }
        #expect(throws: PrivilegeError.self) {
            try HotspotNATController.validateConfiguration(
                upstreamInterface: "en10",
                downstreamInterface: "en0",
                gateway: "192.168.3.1",
                subnet: "192.168.2.0/24"
            )
        }
    }

    @Test("PFNATAnchorManager orders scrub -> nat -> pass across multiple subnets and derives netmask")
    func testMultiSubnetPFRuleOrderAndNetmask() throws {
        let manager = PFNATAnchorManager(
            anchorName: "netboost",
            upstreamInterface: "en10",
            clientSubnet: "192.168.3.0/24"
        )
        let rules = manager.generateNATRules(additionalSubnets: ["192.168.2.0/24"])
        let lines = rules.components(separatedBy: .newlines).filter { !$0.isEmpty }

        let lastScrub = lines.lastIndex(where: { $0.hasPrefix("scrub ") }) ?? -1
        let firstNat = lines.firstIndex(where: { $0.hasPrefix("nat ") }) ?? -1
        let lastNat = lines.lastIndex(where: { $0.hasPrefix("nat ") }) ?? -1
        let firstPass = lines.firstIndex(where: { $0.hasPrefix("pass ") }) ?? -1
        #expect(lastScrub >= 0 && firstNat > lastScrub && firstPass > lastNat)

        let customConfig = HotspotConfiguration(
            subnet: "10.20.0.0/16",
            gateway: "10.20.0.1",
            dhcpRangeStart: "10.20.0.10",
            dhcpRangeEnd: "10.20.0.100",
            interfaceName: "en0",
            upstreamInterface: "en10"
        )
        let controller = HotspotNATController(configuration: customConfig)
        let cmd = try controller.buildStartCommand(
            ruleFile: "/tmp/test.pf",
            natPlistFile: "/tmp/nat.plist",
            upstreamInterface: "en10",
            downstreamInterface: "en0",
            bridge100Active: false
        )
        #expect(cmd.contains("netmask '255.255.0.0'"))
    }

    @Test("DHCPServer parses macOS bootpd lease blocks accurately")
    func testParseBootpdLeases() throws {
        let sample = """
        {
        \tname=iPad
        \tip_address=192.168.2.3
        \thw_address=1,66:61:c9:cc:5b:91
        \tidentifier=1,66:61:c9:cc:5b:91
        \tlease=0x69f236d1
        }
        {
        \tip_address=192.168.3.14
        \thw_address=1,0a:1b:2c:3d:4e:5f
        \tlease=0x69f21c48
        }
        """

        let parsed = DHCPServer.parseBootpdLeases(contents: sample)
        #expect(parsed.count == 2)
        #expect(parsed[0].hostname == "iPad")
        #expect(parsed[0].ipAddress == "192.168.2.3")
        #expect(parsed[0].macAddress == "66:61:c9:cc:5b:91")
        #expect(Int(parsed[0].expiresAt.timeIntervalSince1970) == 0x69f236d1)

        #expect(parsed[1].hostname == nil)
        #expect(parsed[1].ipAddress == "192.168.3.14")
        #expect(parsed[1].macAddress == "0a:1b:2c:3d:4e:5f")

        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("test_dhcpd_leases_\(UUID().uuidString)")
        try sample.write(toFile: tempPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let fromFile = DHCPServer.parseBootpdLeases(at: tempPath)
        #expect(fromFile.count == 2)
    }

    @Test("ARPScanner filters incomplete entries and supports multiple subnet prefixes")
    func testARPScannerFiltersIncompleteAndMultiPrefix() {
        let arpOutput = """
        ? (192.168.2.1) at 32:95:59:02:89:de on bridge100 ifscope [ethernet]
        ? (192.168.2.99) at (incomplete) on bridge100 ifscope [ethernet]
        ? (192.168.2.3) at 66:61:c9:cc:5b:91 on bridge100 ifscope [ethernet]
        ? (192.168.3.1) at 32:95:59:02:89:de on bridge100 ifscope [ethernet]
        ? (192.168.3.14) at a:1b:2c:3d:4e:5f on bridge100 ifscope [ethernet]
        """

        let leases = [
            DHCPLease(ipAddress: "192.168.2.3", macAddress: "66:61:c9:cc:5b:91", hostname: "iPad"),
            DHCPLease(ipAddress: "192.168.3.14", macAddress: "0a:1b:2c:3d:4e:5f", hostname: "MacBook")
        ]

        let clients = ARPScanner.parseHotspotClients(
            arpOutput: arpOutput,
            leases: leases,
            subnetPrefixes: ["192.168.2.", "192.168.3."]
        )

        #expect(clients.count == 2)
        #expect(clients.contains { $0.ipAddress == "192.168.2.3" && $0.hostname == "iPad" })
        #expect(clients.contains { $0.ipAddress == "192.168.3.14" && $0.hostname == "MacBook" })
        #expect(!clients.contains { $0.macAddress == "(incomplete)" })
    }

    private struct StaticMockResolver: DNSResolverProtocol {
        let mapping: [String: String]
        func resolve(domain: String, queryType: String, upstreamResolvers: [String]) -> String? {
            mapping["\(domain.lowercased())|\(queryType.uppercased())"]
        }
    }

    @Test("DNSProxy UDP listener answers real DNS A queries over localhost socket")
    func testDNSProxyUDPRoundtrip() throws {
        let resolver = StaticMockResolver(mapping: ["hotspot.test.local|A": "10.8.0.42"])
        let proxy = DNSProxy(resolver: resolver)
        try proxy.startUDPListener(port: 0)
        defer { proxy.stop() }

        guard let port = proxy.listeningPort else {
            Issue.record("Expected bound DNS UDP listening port")
            return
        }

        let clientSock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #expect(clientSock >= 0)
        defer { Darwin.close(clientSock) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        Darwin.setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &dest.sin_addr)

        // Standard DNS query for hotspot.test.local (Type A = 1, Class IN = 1)
        var queryPacket: [UInt8] = [
            0x12, 0x34, // ID
            0x01, 0x00, // RD=1
            0x00, 0x01, // QDCOUNT=1
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        for label in ["hotspot", "test", "local"] {
            queryPacket.append(UInt8(label.count))
            queryPacket.append(contentsOf: label.utf8)
        }
        queryPacket.append(0x00)
        queryPacket.append(contentsOf: [0x00, 0x01, 0x00, 0x01])

        let sent = queryPacket.withUnsafeBytes { raw in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(clientSock, raw.baseAddress, queryPacket.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        #expect(sent == queryPacket.count)

        var recvBuf = [UInt8](repeating: 0, count: 512)
        let received = Darwin.recvfrom(clientSock, &recvBuf, recvBuf.count, 0, nil, nil)
        #expect(received >= 16)
        #expect(recvBuf[0] == 0x12 && recvBuf[1] == 0x34)
        #expect((recvBuf[2] & 0x80) != 0) // QR=1
        #expect(recvBuf[7] == 1) // ANCOUNT=1
        // Last 4 bytes of single A record response are 10.8.0.42
        #expect(Array(recvBuf[(received - 4)..<received]) == [10, 8, 0, 42])
    }

    @Test("DHCPServer UDP listener handles DISCOVER -> OFFER -> REQUEST -> ACK -> RELEASE over localhost")
    func testDHCPServerUDPRoundtrip() throws {
        let server = DHCPServer()
        try server.startUDPListener(port: 0)
        defer { server.stop() }

        guard let port = server.listeningPort else {
            Issue.record("Expected bound DHCP UDP listening port")
            return
        }

        let clientSock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #expect(clientSock >= 0)
        defer { Darwin.close(clientSock) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        Darwin.setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &dest.sin_addr)

        func makeDHCPRequestPacket(msgType: UInt8, requestedIP: [UInt8]? = nil) -> [UInt8] {
            var pkt = [UInt8](repeating: 0, count: 240)
            pkt[0] = 1 // BOOTREQUEST
            pkt[1] = 1 // Ethernet
            pkt[2] = 6 // MAC length
            pkt[4] = 0xAA; pkt[5] = 0xBB; pkt[6] = 0xCC; pkt[7] = 0xDD // XID
            // chaddr MAC: 02:11:22:33:44:55
            pkt[28] = 0x02; pkt[29] = 0x11; pkt[30] = 0x22
            pkt[31] = 0x33; pkt[32] = 0x44; pkt[33] = 0x55
            // Magic cookie
            pkt[236] = 0x63; pkt[237] = 0x82; pkt[238] = 0x53; pkt[239] = 0x63
            pkt.append(contentsOf: [53, 1, msgType])
            if let ip = requestedIP {
                pkt.append(contentsOf: [50, 4])
                pkt.append(contentsOf: ip)
            }
            pkt.append(contentsOf: [12, 6])
            pkt.append(contentsOf: "iPhone".utf8)
            pkt.append(255)
            return pkt
        }

        func sendAndRecv(_ packet: [UInt8]) -> [UInt8]? {
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.sendto(clientSock, raw.baseAddress, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == packet.count else { return nil }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = Darwin.recvfrom(clientSock, &buf, buf.count, 0, nil, nil)
            guard n >= 240 else { return nil }
            return Array(buf[0..<n])
        }

        // 1. DISCOVER -> OFFER (192.168.2.10)
        let offer = sendAndRecv(makeDHCPRequestPacket(msgType: 1))
        #expect(offer != nil)
        #expect(offer?[0] == 2) // BOOTREPLY
        #expect(Array(offer![16..<20]) == [192, 168, 2, 10])

        // 2. REQUEST -> ACK (192.168.2.10)
        let ack = sendAndRecv(makeDHCPRequestPacket(msgType: 3, requestedIP: [192, 168, 2, 10]))
        #expect(ack != nil)
        #expect(Array(ack![16..<20]) == [192, 168, 2, 10])
        #expect(server.activeLeaseCount == 1)
        #expect(server.allLeases.first?.hostname == "iPhone")

        // 3. RELEASE -> clears active lease
        let releasePkt = makeDHCPRequestPacket(msgType: 7)
        _ = releasePkt.withUnsafeBytes { raw in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(clientSock, raw.baseAddress, releasePkt.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(server.activeLeaseCount == 0)
    }
}
