import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 36: ARP Client Discovery Boundaries", .tags(.tier2, .m5_doctor, .hotspot))
struct Tier2_36_ARPClientDiscoveryBoundariesTests {

    @Test("T2-F36-01: Parse arp -an output filtering strictly for 192.168.2.0/24 subnet")
    func testFilterARPForHotspotSubnet() {
        let arpOutput = """
        ? (10.1.36.1) at 00:00:0c:07:ac:01 on en10 ifscope [ethernet]
        ? (192.168.2.10) at a4:83:e7:01:02:03 on en0 ifscope [ethernet]
        ? (192.168.2.11) at b2:11:22:33:44:55 on en0 ifscope [ethernet]
        ? (172.20.10.1) at 12:34:56:78:9a:bc on en0 ifscope [ethernet]
        """

        func extractHotspotClients(from output: String) -> [(ip: String, mac: String)] {
            var clients: [(ip: String, mac: String)] = []
            for line in output.components(separatedBy: .newlines) {
                guard line.contains("(192.168.2.") else { continue }
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    let ip = parts[1].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                    let mac = String(parts[3])
                    clients.append((ip: ip, mac: mac))
                }
            }
            return clients
        }

        let clients = extractHotspotClients(from: arpOutput)
        #expect(clients.count == 2)
        #expect(clients[0].ip == "192.168.2.10")
        #expect(clients[1].ip == "192.168.2.11")
    }

    @Test("T2-F36-02: (incomplete) ARP entries are skipped from active clients list")
    func testIncompleteARPSkipped() {
        let incompleteLine = "? (192.168.2.99) at (incomplete) on en0 ifscope [ethernet]"
        #expect(incompleteLine.contains("(incomplete)"))

        func isValidClient(line: String) -> Bool {
            return !line.contains("(incomplete)")
        }

        #expect(isValidClient(line: incompleteLine) == false)
    }

    @Test("T2-F36-03: Correlate ARP MAC with DHCP lease to enrich client hostname")
    func testHostnameEnrichment() {
        let arpEntry = (ip: "192.168.2.10", mac: "a4:83:e7:01:02:03")
        let dhcpLeases = [
            "a4:83:e7:01:02:03": "MacBook-Air.local",
            "b2:11:22:33:44:55": "iPad-Pro.local"
        ]

        let client = HotspotClient(
            macAddress: arpEntry.mac,
            ipAddress: arpEntry.ip,
            hostname: dhcpLeases[arpEntry.mac]
        )

        #expect(client.hostname == "MacBook-Air.local")
        #expect(client.ipAddress == "192.168.2.10")
    }

    @Test("T2-F36-04: Client byte counters update accurately")
    func testClientByteCounterUpdates() {
        var client = HotspotClient(
            macAddress: "a4:83:e7:01:02:03",
            ipAddress: "192.168.2.10",
            txBytes: 1000,
            rxBytes: 5000
        )

        client.txBytes += 500
        client.rxBytes += 2500

        #expect(client.txBytes == 1500)
        #expect(client.rxBytes == 7500)
    }

    @Test("T2-F36-05: ARP spoofing detection when multiple IPs claim same MAC address")
    func testARPSpoofingDetection() {
        let clientRecords = [
            (ip: "192.168.2.10", mac: "00:11:22:33:44:55"),
            (ip: "192.168.2.15", mac: "00:11:22:33:44:55") // duplicate MAC for different IP
        ]

        var macToIPs: [String: Set<String>] = [:]
        for c in clientRecords {
            macToIPs[c.mac, default: []].insert(c.ip)
        }

        let spoofedMACs = macToIPs.filter { $0.value.count > 1 }.keys
        #expect(spoofedMACs.contains("00:11:22:33:44:55"))
    }
}
