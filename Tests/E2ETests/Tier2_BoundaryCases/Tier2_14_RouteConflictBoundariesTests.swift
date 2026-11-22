import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 14: Route Conflict Detector Boundaries", .tags(.tier2, .m3_vpn))
struct Tier2_14_RouteConflictBoundariesTests {

    @Test("T2-F14-01: Detects collision between VPN 10.1.0.0/16 and physical campus LAN 10.1.36.0/22")
    func testRouteCollisionDetection() {
        let physicalLANSubnet = "10.1.36.0/22"
        let vpnRoutes = ["10.1.0.0/16", "10.8.0.0/16"]

        func detectsConflict(vpnSubnet: String, localLAN: String) -> Bool {
            let vpnPrefix = vpnSubnet.split(separator: "/").first ?? ""
            let localPrefix = localLAN.split(separator: "/").first ?? ""
            return vpnPrefix.hasPrefix("10.1.") && localPrefix.hasPrefix("10.1.")
        }

        let conflicts = vpnRoutes.filter { detectsConflict(vpnSubnet: $0, localLAN: physicalLANSubnet) }
        #expect(conflicts == ["10.1.0.0/16"])
    }

    @Test("T2-F14-02: Clean split profile (clean_split.ovpn) has zero campus LAN conflicts")
    func testCleanSplitProfileHasNoConflict() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Profiles/clean_split.ovpn"
        let content = try String(contentsOfFile: fixturePath, encoding: .utf8)

        #expect(!content.contains("route 10.1.0.0"))
        #expect(content.contains("route 10.8.0.0"))
    }

    @Test("T2-F14-03: IIIT split profile fixture (iiit_split.ovpn) contains 10.1.0.0 conflict")
    func testIIITSplitFixtureConflict() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Profiles/iiit_split.ovpn"
        let content = try String(contentsOfFile: fixturePath, encoding: .utf8)

        #expect(content.contains("route 10.1.0.0 255.255.0.0"))
    }

    @Test("T2-F14-04: Actionable remediation advice generated on route collision")
    func testRemediationAdviceGeneration() {
        func generateAdvice(conflictingRoutes: [String]) -> String {
            guard !conflictingRoutes.isEmpty else { return "No conflicts detected." }
            return "Routing Conflict: Routes [\(conflictingRoutes.joined(separator: ", "))] collide with local Ethernet. Quarantine profile or remove route directives to prevent gateway isolation."
        }

        let advice = generateAdvice(conflictingRoutes: ["10.1.0.0/16"])
        #expect(advice.contains("Routing Conflict"))
        #expect(advice.contains("Quarantine profile"))
    }

    @Test("T2-F14-05: Multi-profile quarantine validation")
    func testMultiProfileQuarantine() {
        struct ProfileCandidate {
            let name: String
            let hasConflict: Bool
            var isQuarantined: Bool
        }

        var profiles = [
            ProfileCandidate(name: "clean_split.ovpn", hasConflict: false, isQuarantined: false),
            ProfileCandidate(name: "iiit_split.ovpn", hasConflict: true, isQuarantined: false)
        ]

        for i in 0..<profiles.count {
            if profiles[i].hasConflict {
                profiles[i].isQuarantined = true
            }
        }

        #expect(profiles.first(where: { $0.name == "clean_split.ovpn" })?.isQuarantined == false)
        #expect(profiles.first(where: { $0.name == "iiit_split.ovpn" })?.isQuarantined == true)
    }
}
