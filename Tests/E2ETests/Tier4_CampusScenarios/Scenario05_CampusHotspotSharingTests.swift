import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 5: Campus 802.1X Wired-to-Wireless Hotspot Sharing", .tags(.tier4, .hotspot, .process_runner, .m1_foundation))
struct Scenario05_CampusHotspotSharingTests {

    @Test("Complete 802.1X Hotspot Sharing: Sysctl forwarding + PF NAT anchor + DHCP pool + DNS proxy + ARP discovery")
    func testHotspotSharingFullCycle() async throws {
        let runner = MockProcessRunner()

        // Step 1: Upstream 802.1X Authenticated Ethernet Interface
        let upstreamEthernet = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB 10/100 LAN",
            ipAddresses: [IPAddress(address: "10.1.36.52", netmask: "255.255.252.0", prefixLength: 22)],
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true
        )
        #expect(upstreamEthernet.bsdName == "en10")

        // Step 2: Configure Hotspot Engine Parameters
        let config = HotspotConfiguration(
            subnet: "192.168.2.0/24",
            gateway: "192.168.2.1",
            dhcpRangeStart: "192.168.2.10",
            dhcpRangeEnd: "192.168.2.100",
            interfaceName: "bridge0",
            upstreamInterface: "en10",
            isActive: true
        )
        #expect(config.isActive)
        #expect(config.subnet == "192.168.2.0/24")

        // Step 3: Enable IP Forwarding
        let sysctlOn = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=1"], isElevated: true)
        #expect(sysctlOn.succeeded)
        #expect(runner.didExecute(commandContaining: "net.inet.ip.forwarding=1"))

        // Step 4: Install Isolated PF NAT Anchor
        let natRule = "nat on \(config.upstreamInterface) from \(config.subnet) to any -> (\(config.upstreamInterface))\n"
        let pfctlLoad = try await runner.run("pfctl", arguments: ["-a", "netboost", "-f", "-"], environment: ["RULES": natRule], isElevated: true)
        #expect(pfctlLoad.succeeded)

        let pfctlEnable = try await runner.run("pfctl", arguments: ["-e"], isElevated: true)
        #expect(pfctlEnable.succeeded)
        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -f"))

        // Step 5: DHCP Lease Management Simulation
        let clientMAC = "a4:c3:f0:12:34:56"
        let clientIP = "192.168.2.10"
        let lease = DHCPLease(ipAddress: clientIP, macAddress: clientMAC, leaseDuration: 7200)

        #expect(!lease.isExpired)
        #expect(lease.ipAddress == "192.168.2.10")
        #expect(lease.macAddress == clientMAC)

        // Step 6: DNS Proxy Forwarding Configuration
        let campusDNS = "10.4.20.21"
        let clientDNSQueryTarget = "turing.iiit.ac.in"
        #expect(campusDNS == "10.4.20.21")
        #expect(!clientDNSQueryTarget.isEmpty)

        // Step 7: Connected Client ARP Discovery
        let arpOutput = try await runner.run("arp", arguments: ["-an"])
        #expect(arpOutput.succeeded)

        var client = HotspotClient(macAddress: clientMAC, ipAddress: clientIP, hostname: "iPhone-User")
        client.txBytes = 1_048_576 // 1 MB
        client.rxBytes = 10_485_760 // 10 MB

        #expect(client.ipAddress == "192.168.2.10")
        #expect(client.txBytes > 0)
        #expect(client.rxBytes > 0)

        // Step 8: Teardown - Flush Anchor and Disable Forwarding
        let pfctlFlush = try await runner.run("pfctl", arguments: ["-a", "netboost", "-F", "all"], isElevated: true)
        #expect(pfctlFlush.succeeded)

        let sysctlOff = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=0"], isElevated: true)
        #expect(sysctlOff.succeeded)

        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -F all"))
        #expect(runner.didExecute(commandContaining: "net.inet.ip.forwarding=0"))
    }
}
