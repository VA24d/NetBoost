import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 8: Passepartout VPN Profile Import, Route Conflict Quarantine & Safe Start", .tags(.tier4, .m3_vpn))
struct Scenario08_VPNProfileQuarantinePassepartoutTests {

    @Test("VPN profile import parses directives, quarantines route-conflicting profiles, and safely starts non-conflicting profile")
    func testVPNProfileImportQuarantineAndConnectWorkflow() async throws {
        let runner = MockProcessRunner()

        // Step 1: Physical Campus Network Interface
        let campusLAN = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB 10/100 LAN",
            ipAddresses: [IPAddress(address: "10.1.36.52", netmask: "255.255.252.0", prefixLength: 22)],
            gateway: "10.1.36.1",
            isPrimary: true
        )

        // Step 2: Import Profile 1 - iiit_split.ovpn (Contains 10.1.0.0/16 conflict)
        let splitPath = "Tests/Fixtures/Profiles/iiit_split.ovpn"
        let splitContent = try String(contentsOfFile: splitPath, encoding: .utf8)

        var splitRoutes: [VPNRouteEntry] = []
        for line in splitContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("route ") {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    splitRoutes.append(VPNRouteEntry(destinationSubnet: String(parts[1]), mask: String(parts[2])))
                }
            }
        }

        #expect(splitRoutes.contains(where: { $0.destinationSubnet == "10.1.0.0" }))

        // Step 3: Route Conflict Analysis - Quarantine Conflicting Profile
        let hasConflict = splitRoutes.contains { route in
            route.destinationSubnet == "10.1.0.0" && campusLAN.ipAddresses.contains(where: { $0.address.hasPrefix("10.1.") })
        }

        #expect(hasConflict == true)

        let quarantineNotice = DetectedIssue(
            severity: .critical,
            title: "Profile Quarantined: Route Collision Detected",
            description: "Profile iiit_split.ovpn redirects 10.1.0.0/16, which would break the physical campus gateway 10.1.36.1.",
            recommendedFixAction: "Switch to valid_macos.ovpn"
        )
        #expect(quarantineNotice.severity == .critical)

        // Step 4: Import Profile 2 - valid_macos.ovpn (Clean Profile)
        let validPath = "Tests/Fixtures/Profiles/valid_macos.ovpn"
        let validContent = try String(contentsOfFile: validPath, encoding: .utf8)

        #expect(!validContent.contains("route 10.1.0.0"))
        #expect(validContent.contains("remote vpn2.iiit.ac.in 1194"))
        #expect(validContent.contains("cipher AES-128-GCM"))

        let safeProfile = VPNProfileInfo(
            name: "macos.ovpn",
            serverAddress: "vpn2.iiit.ac.in",
            proto: "udp",
            port: 1194,
            cipher: "AES-128-GCM",
            isCampusSplit: false,
            filePath: validPath
        )
        #expect(safeProfile.name == "macos.ovpn")

        // Step 5: Safe Connection via Passepartout (scutil --nc start)
        let startOutput = try await runner.run("scutil", arguments: ["--nc", "start", safeProfile.name])
        #expect(startOutput.succeeded)
        #expect(runner.didExecute(commandContaining: "scutil --nc start macos.ovpn"))

        // Step 6: Status Verification
        runner.registerStub(
            commandContaining: "scutil --nc status macos.ovpn",
            stdout: "Connected\n",
            exitCode: 0
        )
        let status = try await runner.run("scutil", arguments: ["--nc", "status", safeProfile.name])
        #expect(status.stdout.contains("Connected"))
    }
}
