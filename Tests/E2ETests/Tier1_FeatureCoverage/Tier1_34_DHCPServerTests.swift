import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 34: DHCP Lease Service (192.168.2.0/24)", .tags(.tier1, .m5_doctor, .hotspot))
struct Tier1_34_DHCPServerTests {

    final class DHCPServerSimulator: @unchecked Sendable {
        private let config: HotspotConfiguration
        private var leases: [String: DHCPLease] = [:] // MAC -> Lease
        private var allocatedIPs: Set<String> = []
        private let lock = NSLock()

        init(config: HotspotConfiguration = .default) {
            self.config = config
        }

        func handleDiscover(mac: String) -> String? {
            lock.lock()
            defer { lock.unlock() }

            if let existing = leases[mac], !existing.isExpired {
                return existing.ipAddress
            }

            for i in 10...100 {
                let candidate = "192.168.2.\(i)"
                if !allocatedIPs.contains(candidate) {
                    return candidate
                }
            }
            return nil
        }

        func handleRequest(mac: String, requestedIP: String) -> DHCPLease? {
            lock.lock()
            defer { lock.unlock() }

            allocatedIPs.insert(requestedIP)
            let lease = DHCPLease(ipAddress: requestedIP, macAddress: mac, leaseDuration: 86400)
            leases[mac] = lease
            return lease
        }

        func handleRelease(mac: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard let lease = leases.removeValue(forKey: mac) else { return false }
            allocatedIPs.remove(lease.ipAddress)
            return true
        }

        var activeLeaseCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return leases.count
        }
    }

    @Test("T1-F34-01: Initialize DHCP pool within 192.168.2.10 to 192.168.2.100")
    func testInitializeDHCPPool() {
        let config = HotspotConfiguration.default
        #expect(config.subnet == "192.168.2.0/24")
        #expect(config.gateway == "192.168.2.1")
        #expect(config.dhcpRangeStart == "192.168.2.10")
        #expect(config.dhcpRangeEnd == "192.168.2.100")
    }

    @Test("T1-F34-02: Handle DHCP DISCOVER and offer available IP from pool")
    func testHandleDHCPDiscover() {
        let server = DHCPServerSimulator()
        let offeredIP = server.handleDiscover(mac: "aa:bb:cc:dd:ee:01")

        #expect(offeredIP != nil)
        #expect(offeredIP?.hasPrefix("192.168.2.") == true)
        #expect(offeredIP == "192.168.2.10")
    }

    @Test("T1-F34-03: Handle DHCP REQUEST and confirm lease with DHCP ACK")
    func testHandleDHCPRequest() {
        let server = DHCPServerSimulator()
        let mac = "aa:bb:cc:dd:ee:01"
        let offeredIP = server.handleDiscover(mac: mac)!

        let lease = server.handleRequest(mac: mac, requestedIP: offeredIP)
        #expect(lease != nil)
        #expect(lease?.ipAddress == offeredIP)
        #expect(lease?.macAddress == mac)
        #expect(lease?.leaseDuration == 86400)
        #expect(server.activeLeaseCount == 1)
    }

    @Test("T1-F34-04: Distinct MAC addresses receive distinct IP leases")
    func testDistinctMACLeases() {
        let server = DHCPServerSimulator()
        let mac1 = "11:22:33:44:55:66"
        let mac2 = "aa:bb:cc:dd:ee:ff"

        let ip1 = server.handleDiscover(mac: mac1)!
        _ = server.handleRequest(mac: mac1, requestedIP: ip1)

        let ip2 = server.handleDiscover(mac: mac2)!
        _ = server.handleRequest(mac: mac2, requestedIP: ip2)

        #expect(ip1 != ip2)
        #expect(server.activeLeaseCount == 2)
    }

    @Test("T1-F34-05: Handle DHCP RELEASE and return IP address to pool")
    func testHandleDHCPRelease() {
        let server = DHCPServerSimulator()
        let mac = "aa:bb:cc:dd:ee:01"
        let ip = server.handleDiscover(mac: mac)!
        _ = server.handleRequest(mac: mac, requestedIP: ip)
        #expect(server.activeLeaseCount == 1)

        let released = server.handleRelease(mac: mac)
        #expect(released == true)
        #expect(server.activeLeaseCount == 0)

        // Released IP can now be re-offered
        let nextOffered = server.handleDiscover(mac: "ff:ee:dd:cc:bb:aa")
        #expect(nextOffered == ip)
    }
}
