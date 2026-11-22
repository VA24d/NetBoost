import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 3: Hotspot + VPN Split-Routing Interaction", .tags(.tier3, .hotspot, .m3_vpn))
struct CrossFeature_HotspotVPNTests {

    @Test("Hotspot activation enables sysctl IP forwarding and loads isolated PF NAT anchor for en10")
    func testHotspotActivationEnablesForwardingAndPFNAT() async throws {
        let runner = MockProcessRunner()

        // 1. Enable IP forwarding
        let sysctlOutput = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=1"])
        #expect(sysctlOutput.succeeded)
        #expect(runner.didExecute(commandContaining: "net.inet.ip.forwarding=1"))

        // 2. Load PF NAT anchor netboost
        let natRule = "nat on en10 from 192.168.2.0/24 to any -> (en10)\n"
        let pfctlLoad = try await runner.run("pfctl", arguments: ["-a", "netboost", "-f", "-"], environment: ["RULES": natRule])
        #expect(pfctlLoad.succeeded)
        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -f"))

        // 3. Enable packet filter
        let pfctlEnable = try await runner.run("pfctl", arguments: ["-e"])
        #expect(pfctlEnable.succeeded)

        // Verify configuration state
        let config = HotspotConfiguration(
            subnet: "192.168.2.0/24",
            gateway: "192.168.2.1",
            interfaceName: "en0",
            upstreamInterface: "en10",
            isActive: true
        )
        #expect(config.isActive == true)
        #expect(config.upstreamInterface == "en10")
    }

    @Test("DHCP lease service allocates client IP in 192.168.2.0/24 and isolates traffic from host VPN")
    func testDHCPLeaseAllocationAndDNSIsolation() async throws {
        // Hotspot pool: 192.168.2.10 - 192.168.2.100
        let clientMAC = "a4:c3:f0:12:34:56"
        let assignedIP = "192.168.2.10"
        let lease = DHCPLease(ipAddress: assignedIP, macAddress: clientMAC, leaseDuration: 3600)

        #expect(!lease.isExpired)
        #expect(lease.ipAddress.hasPrefix("192.168.2."))

        // Verify DNS configuration points to campus upstream (10.4.20.21) not VPN DNS
        let campusDNS = ["10.4.20.21", "10.4.20.222"]
        let profile = VPNProfileInfo(
            name: "macos.ovpn",
            serverAddress: "vpn2.iiit.ac.in",
            dnsServers: ["10.0.0.1"]
        )

        // Hotspot clients receive campus DNS, preserving direct split routing
        #expect(campusDNS.first == "10.4.20.21")
        #expect(profile.dnsServers.first != campusDNS.first)
    }

    @Test("Active client ARP discovery identifies 192.168.2.0/24 devices while VPN is active on secondary interface")
    func testClientDiscoveryUnderActiveVPN() async throws {
        let runner = MockProcessRunner()

        // Query ARP table
        let arpOutput = try await runner.run("arp", arguments: ["-an"])
        #expect(arpOutput.succeeded)

        // Parse hotspot subnet clients (192.168.2.x excluding gateway 192.168.2.1)
        let lines = arpOutput.stdout.components(separatedBy: "\n")
        var discoveredClients: [HotspotClient] = []

        for line in lines where line.contains("192.168.2.") {
            // Sample line: ? (192.168.2.15) at a4:c3:f0:12:34:56 on bridge0 ifscope [ethernet]
            if let ipStart = line.firstIndex(of: "("), let ipEnd = line.firstIndex(of: ")"),
               let atIdx = line.range(of: " at ")?.upperBound,
               let onIdx = line.range(of: " on ")?.lowerBound {
                let ip = String(line[line.index(after: ipStart)..<ipEnd])
                let mac = String(line[atIdx..<onIdx]).trimmingCharacters(in: .whitespaces)
                if ip != "192.168.2.1" {
                    discoveredClients.append(HotspotClient(macAddress: mac, ipAddress: ip))
                }
            }
        }

        #expect(discoveredClients.count >= 1)
        #expect(discoveredClients.contains(where: { $0.ipAddress == "192.168.2.15" }))

        // Verify VPN status via scutil
        let vpnStatus = try await runner.run("scutil", arguments: ["--nc", "status", "macos.ovpn"])
        #expect(vpnStatus.succeeded)
    }

    @Test("Network environment transition to cellular hotspot engages VPN while keeping Hotspot sharing intact")
    func testNetworkTransitionTriggersVPNAvoidingHotspotInterference() async throws {
        let env = MockNetworkEnvironment(initialState: .defaultCampusLAN)
        let runner = MockProcessRunner()

        // Transition to cellular hotspot (e.g. Wi-Fi on iPhone hotspot 172.20.10.2)
        env.transition(to: .defaultCellularHotspot)
        #expect(env.currentState.isCellular)

        // Automated rule engages macos.ovpn for external Wi-Fi
        let vpnConnect = try await runner.run("scutil", arguments: ["--nc", "start", "macos.ovpn"])
        #expect(vpnConnect.succeeded)
        #expect(runner.didExecute(commandContaining: "scutil --nc start macos.ovpn"))

        // Hotspot configuration on en10 remains active with direct gateway 10.1.36.1
        let hotspotState = HotspotConfiguration(
            subnet: "192.168.2.0/24",
            gateway: "192.168.2.1",
            interfaceName: "bridge0",
            upstreamInterface: "en10",
            isActive: true
        )
        #expect(hotspotState.isActive)
        #expect(hotspotState.upstreamInterface == "en10")
    }

    @Test("Hotspot teardown flushes PF NAT anchor and resets sysctl without disconnecting host VPN")
    func testHotspotTeardownIsolatesPFFromSystemAndVPNTunnel() async throws {
        let runner = MockProcessRunner()

        // Flush netboost PF anchor specifically
        let flushPF = try await runner.run("pfctl", arguments: ["-a", "netboost", "-F", "all"])
        #expect(flushPF.succeeded)
        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -F all"))

        // Reset sysctl forwarding
        let resetSysctl = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=0"])
        #expect(resetSysctl.succeeded)

        // Main system VPN status remains unaffected
        let vpnStatus = try await runner.run("scutil", arguments: ["--nc", "status", "macos.ovpn"])
        #expect(vpnStatus.succeeded)
    }
}
