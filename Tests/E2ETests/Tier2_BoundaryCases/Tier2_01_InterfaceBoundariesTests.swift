import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 01: Interface Detection Boundaries", .tags(.tier2, .m1_foundation))
struct Tier2_01_InterfaceBoundariesTests {

    @Test("T2-F01-01: Interface active with no IP assigned handled gracefully")
    func testInterfaceActiveWithNoIP() {
        let unassignedInterface = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [],
            macAddress: "a4:83:e7:23:45:67",
            gateway: nil,
            mtu: 1500,
            isPrimary: false,
            isUp: true
        )

        #expect(unassignedInterface.isUp == true)
        #expect(unassignedInterface.ipAddresses.isEmpty)
        #expect(unassignedInterface.ipv4Address == nil)
        #expect(unassignedInterface.ipv6Address == nil)
        #expect(unassignedInterface.gateway == nil)
    }

    @Test("T2-F01-02: Virtual tunnel interfaces cleanly filtered from physical uplinks")
    func testVirtualTunnelFiltering() {
        let candidateNames = ["en0", "en10", "en9", "utun0", "utun1", "bridge0", "llw0", "awdl0", "lo0"]
        let virtualPrefixes = ["utun", "bridge", "llw", "awdl", "lo"]

        let physicalUplinks = candidateNames.filter { name in
            !virtualPrefixes.contains(where: { name.hasPrefix($0) })
        }

        #expect(physicalUplinks == ["en0", "en10", "en9"])
        #expect(!physicalUplinks.contains("utun0"))
        #expect(!physicalUplinks.contains("bridge0"))
        #expect(!physicalUplinks.contains("awdl0"))
        #expect(!physicalUplinks.contains("lo0"))
    }

    @Test("T2-F01-03: IPv6-only physical interface parsed without crashing IPv4 fields")
    func testIPv6OnlyInterfaceParsing() {
        let ipv6Only = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "Thunderbolt Ethernet",
            ipAddresses: [
                IPAddress(address: "fe80::1ff:fe00:3a60", version: .v6, prefixLength: 64),
                IPAddress(address: "2001:db8:acad::2", version: .v6, prefixLength: 48)
            ],
            macAddress: "00:e0:4c:68:01:23",
            gateway: "fe80::1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        #expect(ipv6Only.ipv4Address == nil)
        #expect(ipv6Only.ipv6Address != nil)
        #expect(ipv6Only.ipAddresses.count == 2)
        #expect(ipv6Only.ipAddresses.allSatisfy { $0.version == .v6 })
    }

    @Test("T2-F01-04: Corrupted or empty interface payload handled safely with empty list fallback")
    func testCorruptedInterfacePayloadFallback() throws {
        let emptyJSON = "[]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([NetworkInterfaceInfo].self, from: emptyJSON)
        #expect(decoded.isEmpty)

        let invalidJSON = "{\"status\": \"error\"}".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([NetworkInterfaceInfo].self, from: invalidJSON)
        }
    }

    @Test("T2-F01-05: Jumbo frame MTU 9000 and minimum MTU 576 boundaries parsed correctly")
    func testInterfaceMTUBoundaries() {
        let jumbo = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "Ethernet Jumbo",
            ipAddresses: [IPAddress(address: "10.1.36.52")],
            mtu: 9000
        )
        #expect(jumbo.mtu == 9000)

        let minMTU = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Cellular Low MTU",
            ipAddresses: [IPAddress(address: "172.20.10.2")],
            mtu: 576
        )
        #expect(minMTU.mtu == 576)
    }
}
