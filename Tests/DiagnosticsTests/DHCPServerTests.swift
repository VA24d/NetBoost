import Testing
import Foundation
@testable import NetBoostCore

@Suite("Hotspot Sharing: DHCPServer Unit & Integration Tests")
struct DHCPServerTests {

    @Test("DHCP server initializes with 192.168.2.0/24 defaults")
    func testDHCPServerDefaults() {
        let server = DHCPServer()
        #expect(server.activeLeaseCount == 0)
        #expect(server.allLeases.isEmpty)
    }

    @Test("Handle DISCOVER returns first available IP 192.168.2.10")
    func testHandleDiscover() {
        let server = DHCPServer()
        let ip = server.handleDiscover(mac: "aa:bb:cc:dd:ee:01")

        #expect(ip == "192.168.2.10")
    }

    @Test("Handle REQUEST binds IP to client MAC and confirms active lease")
    func testHandleRequest() {
        let server = DHCPServer()
        let mac = "aa:bb:cc:dd:ee:01"
        let ip = server.handleDiscover(mac: mac)!

        let lease = server.handleRequest(mac: mac, requestedIP: ip, duration: 86400)
        #expect(lease != nil)
        #expect(lease?.ipAddress == ip)
        #expect(lease?.macAddress == mac)
        #expect(lease?.leaseDuration == 86400)
        #expect(lease?.isExpired == false)
        #expect(server.activeLeaseCount == 1)
    }

    @Test("Distinct clients receive distinct IP allocations")
    func testDistinctAllocations() {
        let server = DHCPServer()
        let mac1 = "11:22:33:44:55:01"
        let mac2 = "11:22:33:44:55:02"

        let lease1 = server.allocate(mac: mac1)
        let lease2 = server.allocate(mac: mac2)

        #expect(lease1?.ipAddress != lease2?.ipAddress)
        #expect(lease1?.ipAddress == "192.168.2.10")
        #expect(lease2?.ipAddress == "192.168.2.11")
        #expect(server.activeLeaseCount == 2)
    }

    @Test("Re-request from same MAC renews existing lease")
    func testLeaseRenewal() {
        let server = DHCPServer()
        let mac = "aa:bb:cc:dd:ee:ff"

        let lease1 = server.allocate(mac: mac)
        let lease2 = server.allocate(mac: mac)

        #expect(lease1?.ipAddress == lease2?.ipAddress)
        #expect(server.activeLeaseCount == 1)
    }

    @Test("Release returns IP address back to pool")
    func testReleaseReturnsIP() {
        let server = DHCPServer()
        let mac = "aa:bb:cc:dd:ee:01"
        let lease = server.allocate(mac: mac)
        #expect(lease?.ipAddress == "192.168.2.10")
        #expect(server.activeLeaseCount == 1)

        let released = server.handleRelease(mac: mac)
        #expect(released == true)
        #expect(server.activeLeaseCount == 0)

        // New client can now claim 192.168.2.10
        let newLease = server.allocate(mac: "aa:bb:cc:dd:ee:02")
        #expect(newLease?.ipAddress == "192.168.2.10")
    }

    @Test("Pool exhaustion occurs after 91 allocations")
    func testPoolExhaustion() {
        let server = DHCPServer()

        for i in 0..<91 {
            let mac = String(format: "00:11:22:33:44:%02x", i)
            let lease = server.allocate(mac: mac)
            #expect(lease != nil)
        }
        #expect(server.activeLeaseCount == 91)

        // 92nd allocation returns nil
        let overflow = server.allocate(mac: "ff:ff:ff:ff:ff:ff")
        #expect(overflow == nil)
    }
}
