import Testing
import Foundation
@testable import NetBoostCore

@Suite("Hotspot Sharing: ARPScanner Unit & Integration Tests")
struct ARPScannerTests {

    @Test("Parse ARP table filtering for 192.168.2.0/24 subnet and excluding gateway")
    func testParseARPTableHotspotSubnet() {
        let mockARP = """
        ? (10.1.36.1) at 00:00:0c:07:ac:01 on en10 ifscope [ethernet]
        ? (192.168.2.1) at 00:11:22:33:44:00 on en0 ifscope [ethernet]
        ? (192.168.2.15) at a4:83:e7:22:11:00 on en0 ifscope [ethernet]
        ? (192.168.2.16) at b8:27:eb:33:44:55 on en0 ifscope [ethernet]
        """

        let clients = ARPScanner.parseHotspotClients(arpOutput: mockARP, leases: [])
        #expect(clients.count == 2)
        #expect(clients.contains { $0.ipAddress == "192.168.2.15" && $0.macAddress == "a4:83:e7:22:11:00" })
        #expect(clients.contains { $0.ipAddress == "192.168.2.16" && $0.macAddress == "b8:27:eb:33:44:55" })
        #expect(!clients.contains { $0.ipAddress == "192.168.2.1" }) // Gateway excluded
    }

    @Test("Correlate client IP/MAC with active DHCP leases to resolve hostnames")
    func testCorrelateWithLeases() {
        let mockARP = "? (192.168.2.20) at a4:83:e7:99:88:77 on en0 ifscope [ethernet]"
        let leases = [
            DHCPLease(ipAddress: "192.168.2.20", macAddress: "a4:83:e7:99:88:77", hostname: "iPad-Client")
        ]

        let clients = ARPScanner.parseHotspotClients(arpOutput: mockARP, leases: leases)
        #expect(clients.count == 1)
        #expect(clients.first?.hostname == "iPad-Client")
    }

    @Test("Client with unassigned DHCP lease hostname resolves to nil without reverse DNS PTR")
    func testClientWithoutHostname() {
        let mockARP = "? (192.168.2.20) at a4:83:e7:99:88:77 on en0 ifscope [ethernet]"
        let leases = [
            DHCPLease(ipAddress: "192.168.2.20", macAddress: "a4:83:e7:99:88:77", hostname: nil)
        ]

        let clients = ARPScanner.parseHotspotClients(arpOutput: mockARP, leases: leases)
        #expect(clients.count == 1)
        #expect(clients.first?.hostname == nil)
    }

    @Test("Newly parsed clients initialize byte counters to 0 and recordTraffic updates metrics")
    func testClientDynamicThroughputMetrics() {
        let mockARP = "? (192.168.2.20) at a4:83:e7:99:88:77 on en0 ifscope [ethernet]"
        let clients = ARPScanner.parseHotspotClients(arpOutput: mockARP, leases: [])
        #expect(clients.first?.txBytes == 0)
        #expect(clients.first?.rxBytes == 0)

        let scanner = ARPScanner()
        let mac = "a4:83:e7:99:88:77"
        scanner.recordTraffic(mac: mac, txDelta: 500, rxDelta: 1000)
        let stats = scanner.throughput(for: mac)
        #expect(stats.tx == 500)
        #expect(stats.rx == 1000)
    }

    @Test("Record and accumulate client throughput statistics")
    func testRecordTrafficMetrics() {
        let scanner = ARPScanner()
        let mac = "a4:83:e7:22:11:00"

        scanner.recordTraffic(mac: mac, txDelta: 1024, rxDelta: 2048)
        scanner.recordTraffic(mac: mac, txDelta: 512, rxDelta: 1024)

        let stats = scanner.throughput(for: mac)
        #expect(stats.tx == 1536)
        #expect(stats.rx == 3072)
    }

    @Test("HotspotClient model maintains byte counters and identity")
    func testHotspotClientModel() {
        var client = HotspotClient(
            macAddress: "a4:83:e7:22:11:00",
            ipAddress: "192.168.2.15",
            hostname: "iPhone",
            txBytes: 1000,
            rxBytes: 2000
        )

        #expect(client.id == "a4:83:e7:22:11:00")
        client.txBytes += 500
        client.rxBytes += 1000
        #expect(client.txBytes == 1500)
        #expect(client.rxBytes == 3000)
    }
}
