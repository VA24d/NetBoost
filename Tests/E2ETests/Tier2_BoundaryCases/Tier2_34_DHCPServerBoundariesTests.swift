import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 34: DHCP Lease Service Boundaries", .tags(.tier2, .m5_doctor, .hotspot))
struct Tier2_34_DHCPServerBoundariesTests {

    final class SimpleDHCPPool: @unchecked Sendable {
        private var leases: [String: DHCPLease] = [:] // MAC -> Lease
        private var allocatedIPs: Set<String> = []
        private let rangeStart = 10
        private let rangeEnd = 100

        func allocate(mac: String) -> DHCPLease? {
            // Check renewal
            if let existing = leases[mac], !existing.isExpired {
                return existing
            }

            // Find next available IP
            for i in rangeStart...rangeEnd {
                let ip = "192.168.2.\(i)"
                if !allocatedIPs.contains(ip) {
                    allocatedIPs.insert(ip)
                    let lease = DHCPLease(ipAddress: ip, macAddress: mac, leaseStart: Date(), leaseDuration: 3600)
                    leases[mac] = lease
                    return lease
                }
            }
            return nil // Pool exhausted
        }

        func release(mac: String) {
            if let lease = leases.removeValue(forKey: mac) {
                allocatedIPs.remove(lease.ipAddress)
            }
        }

        var activeLeaseCount: Int {
            leases.count
        }
    }

    @Test("T2-F34-01: DHCP pool exhaustion after 91 allocations returns nil")
    func testDHCPPoolExhaustion() {
        let pool = SimpleDHCPPool()

        // Allocate all 91 addresses (10 to 100 inclusive)
        for i in 0..<91 {
            let mac = String(format: "00:11:22:33:44:%02x", i)
            let lease = pool.allocate(mac: mac)
            #expect(lease != nil)
        }
        #expect(pool.activeLeaseCount == 91)

        // 92nd allocation must fail due to exhaustion
        let overflow = pool.allocate(mac: "00:11:22:33:44:ff")
        #expect(overflow == nil)
    }

    @Test("T2-F34-02: Rapid re-request from same MAC renews existing lease without reallocating IP")
    func testDHCPLeaseRenewal() {
        let pool = SimpleDHCPPool()
        let mac = "a4:83:e7:22:33:44"

        let lease1 = pool.allocate(mac: mac)
        let lease2 = pool.allocate(mac: mac)

        #expect(lease1?.ipAddress == lease2?.ipAddress)
        #expect(pool.activeLeaseCount == 1)
    }

    @Test("T2-F34-03: Releasing a lease returns IP to pool for future allocation")
    func testDHCPReleaseReturnsIP() {
        let pool = SimpleDHCPPool()
        let mac1 = "00:11:22:33:44:01"
        let lease1 = pool.allocate(mac: mac1)
        #expect(lease1?.ipAddress == "192.168.2.10")

        pool.release(mac: mac1)
        #expect(pool.activeLeaseCount == 0)

        // New client can now claim that same IP
        let mac2 = "00:11:22:33:44:02"
        let lease2 = pool.allocate(mac: mac2)
        #expect(lease2?.ipAddress == "192.168.2.10")
    }

    @Test("T2-F34-04: Expired lease detection via isExpired property")
    func testExpiredLeaseDetection() {
        let expiredLease = DHCPLease(
            ipAddress: "192.168.2.20",
            macAddress: "00:11:22:33:44:55",
            leaseStart: Date().addingTimeInterval(-7200), // 2 hours ago
            leaseDuration: 3600 // 1 hour duration
        )

        #expect(expiredLease.isExpired == true)

        let activeLease = DHCPLease(
            ipAddress: "192.168.2.21",
            macAddress: "00:11:22:33:44:66",
            leaseStart: Date(),
            leaseDuration: 3600
        )

        #expect(activeLease.isExpired == false)
    }

    @Test("T2-F34-05: HotspotConfiguration default parameters match 192.168.2.0/24 specifications")
    func testHotspotConfigurationDefaults() {
        let config = HotspotConfiguration.default
        #expect(config.subnet == "192.168.2.0/24")
        #expect(config.gateway == "192.168.2.1")
        #expect(config.dhcpRangeStart == "192.168.2.10")
        #expect(config.dhcpRangeEnd == "192.168.2.100")
        #expect(config.upstreamInterface == "en10")
        #expect(config.interfaceName == "en0")
    }
}
