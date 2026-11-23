import Testing
import Foundation
@testable import NetBoostCore

@Suite("VPN Subsystem: Route Conflict Detector Unit Tests", .tags(.tier1, .m3_vpn))
struct RouteConflictDetectorTests {

    @Test("IPv4 and UInt32 bitwise conversion and round-trip fidelity")
    func testIPv4MathConversions() {
        let testCases = [
            ("0.0.0.0", UInt32(0)),
            ("10.1.36.1", UInt32((10 << 24) | (1 << 16) | (36 << 8) | 1)),
            ("172.20.10.2", UInt32((172 << 24) | (20 << 16) | (10 << 8) | 2)),
            ("255.255.255.255", UInt32(0xFFFFFFFF))
        ]

        for (ipStr, expectedUInt) in testCases {
            let parsed = RouteConflictDetector.ipv4ToUInt32(ipStr)
            #expect(parsed == expectedUInt)
            let formatted = RouteConflictDetector.uInt32ToIPv4(expectedUInt)
            #expect(formatted == ipStr)
        }

        #expect(RouteConflictDetector.ipv4ToUInt32("invalid.ip") == nil)
        #expect(RouteConflictDetector.ipv4ToUInt32("256.0.0.1") == nil)
        #expect(RouteConflictDetector.ipv4ToUInt32("10.1.0") == nil)
    }

    @Test("Convert netmask string to prefix length and reject non-contiguous masks")
    func testNetmaskToPrefixLength() {
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.0.0.0") == 8)
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.255.0.0") == 16)
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.255.240.0") == 20)
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.255.252.0") == 22)
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.255.255.0") == 24)
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.255.255.255") == 32)
        #expect(RouteConflictDetector.netmaskToPrefixLength("0.0.0.0") == 0)

        // Non-contiguous masks
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.0.255.0") == nil)
        #expect(RouteConflictDetector.netmaskToPrefixLength("255.255.128.1") == nil)
    }

    @Test("Convert prefix length to dotted-decimal netmask string")
    func testPrefixLengthToNetmask() {
        #expect(RouteConflictDetector.prefixLengthToNetmask(8) == "255.0.0.0")
        #expect(RouteConflictDetector.prefixLengthToNetmask(16) == "255.255.0.0")
        #expect(RouteConflictDetector.prefixLengthToNetmask(20) == "255.255.240.0")
        #expect(RouteConflictDetector.prefixLengthToNetmask(22) == "255.255.252.0")
        #expect(RouteConflictDetector.prefixLengthToNetmask(24) == "255.255.255.0")
        #expect(RouteConflictDetector.prefixLengthToNetmask(32) == "255.255.255.255")
        #expect(RouteConflictDetector.prefixLengthToNetmask(33) == nil)
        #expect(RouteConflictDetector.prefixLengthToNetmask(-1) == nil)
    }

    @Test("IP address containment check in IPv4 subnets")
    func testSubnetContainment() {
        // Physical campus gateway 10.1.36.1 is contained in both 10.1.0.0/16 and 10.1.36.0/22
        #expect(RouteConflictDetector.subnetContainsIP(subnet: "10.1.0.0", netmask: "255.255.0.0", ip: "10.1.36.1") == true)
        #expect(RouteConflictDetector.subnetContainsIP(subnet: "10.1.36.0", netmask: "255.255.252.0", ip: "10.1.36.1") == true)

        // Physical campus gateway is NOT in 10.8.0.0/16 or cellular hotspot 172.20.10.0/28
        #expect(RouteConflictDetector.subnetContainsIP(subnet: "10.8.0.0", netmask: "255.255.0.0", ip: "10.1.36.1") == false)
        #expect(RouteConflictDetector.subnetContainsIP(subnet: "172.20.10.0", netmask: "255.255.255.240", ip: "10.1.36.1") == false)
    }

    @Test("Subnet overlap detection between CIDR blocks")
    func testSubnetOverlapDetection() {
        // Overlap: 10.1.0.0/16 and campus LAN 10.1.36.0/22
        let overlap = RouteConflictDetector.doSubnetsOverlap(
            net1: "10.1.0.0", mask1: "255.255.0.0",
            net2: "10.1.36.0", mask2: "255.255.252.0"
        )
        #expect(overlap == true)

        // Disjoint: 10.8.0.0/16 and campus LAN 10.1.36.0/22
        let disjoint = RouteConflictDetector.doSubnetsOverlap(
            net1: "10.8.0.0", mask1: "255.255.0.0",
            net2: "10.1.36.0", mask2: "255.255.252.0"
        )
        #expect(disjoint == false)
    }

    @Test("Detect full-tunnel conflict redirecting campus traffic")
    func testFullTunnelConflictDetection() {
        let profile = VPNProfileInfo(
            name: "full_tunnel.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            isCampusSplit: false
        )
        let conflicts = RouteConflictDetector.detectConflicts(profile: profile)
        #expect(!conflicts.isEmpty)
        #expect(conflicts.contains { $0.contains("Full tunnel redirects all gateway traffic") })
    }

    @Test("Detect subnet collision between iiit_split.ovpn route 10.1.0.0/16 and campus LAN")
    func testIIITSplitConflictDetection() {
        let profile = VPNProfileInfo(
            name: "iiit_split.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [
                VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0"),
                VPNRouteEntry(destinationSubnet: "10.8.0.0", mask: "255.255.240.0")
            ],
            isCampusSplit: true
        )
        let conflicts = RouteConflictDetector.detectConflicts(profile: profile)
        #expect(conflicts.contains { $0.contains("10.1.0.0/255.255.0.0 overlaps") })
    }

    @Test("Clean split profile clean_split.ovpn produces zero conflicts against campus LAN")
    func testCleanSplitNoConflict() {
        let profile = VPNProfileInfo(
            name: "clean_split.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [
                VPNRouteEntry(destinationSubnet: "10.4.0.0", mask: "255.255.0.0"),
                VPNRouteEntry(destinationSubnet: "10.8.0.0", mask: "255.255.240.0")
            ],
            isCampusSplit: true
        )
        let conflicts = RouteConflictDetector.detectConflicts(profile: profile)
        #expect(conflicts.isEmpty)
    }

    @Test("Generate remediation advice for detected conflicts")
    func testRemediationAdviceGeneration() {
        let adviceWithConflicts = RouteConflictDetector.generateRemediationAdvice(conflicts: ["Conflict 1"])
        #expect(adviceWithConflicts == "Recommendation: Switch from full tunnel or remove 10.1.0.0/16 route directive from .ovpn profile.")

        let adviceClean = RouteConflictDetector.generateRemediationAdvice(conflicts: [])
        #expect(adviceClean == nil)
    }

    @Test("Generate detailed advice formatting for multiple conflicting routes")
    func testDetailedAdviceFormatting() {
        let advice = RouteConflictDetector.generateDetailedAdvice(conflictingRoutes: ["10.1.0.0/16"])
        #expect(advice.contains("10.1.0.0/16"))
        #expect(advice.contains("Quarantine profile"))

        let emptyAdvice = RouteConflictDetector.generateDetailedAdvice(conflictingRoutes: [])
        #expect(emptyAdvice == "No conflicts detected.")
    }

    @Test("Structured conflict report against active network interfaces and issue conversion")
    func testStructuredConflictReport() {
        let campusLAN = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "Ethernet",
            ipAddresses: [IPAddress(address: "10.1.36.52", netmask: "255.255.252.0", prefixLength: 22)],
            gateway: "10.1.36.1",
            isPrimary: true,
            isUp: true
        )

        let profile = VPNProfileInfo(
            name: "iiit_split.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [
                VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0")
            ],
            isCampusSplit: true
        )

        let report = RouteConflictDetector.detectConflicts(profile: profile, interfaces: [campusLAN])
        #expect(report.hasConflicts == true)
        #expect(!report.warnings.isEmpty)

        let criticalWarning = report.warnings.first { $0.severity == .critical }
        #expect(criticalWarning != nil)
        #expect(criticalWarning?.affectedInterface == "en10")
        #expect(criticalWarning?.affectedGateway == "10.1.36.1")

        let issue = criticalWarning?.asDetectedIssue()
        #expect(issue?.severity == .critical)
        #expect(issue?.automatedFixAvailable == true)
    }
}
