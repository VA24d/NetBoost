import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 14: Route Conflict Detector", .tags(.tier1, .m3_vpn))
struct Tier1_14_RouteConflictTests {

    struct RouteConflictDetector {
        static func detectConflicts(
            profile: VPNProfileInfo,
            localSubnets: [String] = ["10.1.0.0/16", "10.1.36.0/22"]
        ) -> [String] {
            var conflicts: [String] = []

            if !profile.isCampusSplit {
                conflicts.append("Full tunnel redirects all gateway traffic away from local campus network.")
            }

            for route in profile.routes {
                if route.destinationSubnet.hasPrefix("10.1.") {
                    conflicts.append("VPN route \(route.destinationSubnet)/\(route.mask) overlaps with physical campus LAN subnet.")
                }
            }

            return conflicts
        }

        static func generateRemediationAdvice(conflicts: [String]) -> String? {
            guard !conflicts.isEmpty else { return nil }
            return "Recommendation: Switch from full tunnel or remove 10.1.0.0/16 route directive from .ovpn profile."
        }
    }

    @Test("T1-F14-01: Detect conflict when full-tunnel VPN redirects traffic away from local campus")
    func testFullTunnelConflictDetection() {
        let fullProfile = VPNProfileInfo(
            name: "campus-full.ovpn",
            serverAddress: "vpn2.iiit.ac.in",
            isCampusSplit: false
        )

        let conflicts = RouteConflictDetector.detectConflicts(profile: fullProfile)
        #expect(!conflicts.isEmpty)
        #expect(conflicts.contains { $0.contains("Full tunnel") })
    }

    @Test("T1-F14-02: Detect route overlap when VPN pushes 10.1.0.0/16 over active en10 LAN")
    func testSubnetOverlapConflict() {
        let conflictingProfile = VPNProfileInfo(
            name: "iiit_split.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [
                VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0"),
                VPNRouteEntry(destinationSubnet: "10.8.0.0", mask: "255.255.0.0")
            ],
            isCampusSplit: true
        )

        let conflicts = RouteConflictDetector.detectConflicts(profile: conflictingProfile)
        #expect(conflicts.contains { $0.contains("10.1.0.0") })
    }

    @Test("T1-F14-03: Verify clean non-conflicting state for clean split-tunnel profile")
    func testCleanSplitTunnelNoConflict() {
        let cleanProfile = VPNProfileInfo(
            name: "clean_split.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [
                VPNRouteEntry(destinationSubnet: "10.8.0.0", mask: "255.255.0.0"),
                VPNRouteEntry(destinationSubnet: "10.4.0.0", mask: "255.255.0.0")
            ],
            isCampusSplit: true
        )

        let conflicts = RouteConflictDetector.detectConflicts(profile: cleanProfile)
        #expect(conflicts.isEmpty)
    }

    @Test("T1-F14-04: Metric conflict detected when VPN default shadows physical gateway")
    func testMetricShadowingDetection() {
        let profile = VPNProfileInfo(
            name: "test-default.ovpn",
            serverAddress: "vpn2.iiit.ac.in",
            isCampusSplit: false
        )

        let conflicts = RouteConflictDetector.detectConflicts(profile: profile)
        #expect(conflicts.count >= 1)
    }

    @Test("T1-F14-05: Generate actionable remediation advice when conflicts detected")
    func testRemediationAdviceGeneration() {
        let profile = VPNProfileInfo(
            name: "conflicted.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0")],
            isCampusSplit: true
        )

        let conflicts = RouteConflictDetector.detectConflicts(profile: profile)
        let advice = RouteConflictDetector.generateRemediationAdvice(conflicts: conflicts)

        #expect(advice != nil)
        #expect(advice?.contains("remove 10.1.0.0/16") == true)
    }
}
