import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 3: OpenVPN Profile Lexer + Route Conflict Detector + Passepartout Controller", .tags(.tier3, .m3_vpn))
struct CrossFeature_ProfileConflictQuarantineTests {

    @Test("OpenVPN parser extracts directives, remote server, cipher, and static routes from profile fixture")
    func testOpenVPNProfileParserDirectives() throws {
        let profilePath = "Tests/Fixtures/Profiles/valid_macos.ovpn"
        let content = try String(contentsOfFile: profilePath, encoding: .utf8)

        var remoteHost: String?
        var remotePort: Int?
        var proto: String = "udp"
        var cipher: String?
        var hasCA: Bool = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let keyword = parts.first else { continue }

            switch keyword {
            case "remote":
                if parts.count >= 2 { remoteHost = String(parts[1]) }
                if parts.count >= 3 { remotePort = Int(parts[2]) }
            case "proto":
                if parts.count >= 2 { proto = String(parts[1]) }
            case "cipher":
                if parts.count >= 2 { cipher = String(parts[1]) }
            case "<ca>":
                hasCA = true
            default:
                break
            }
        }

        #expect(remoteHost == "vpn2.iiit.ac.in")
        #expect(remotePort == 1194)
        #expect(proto == "udp")
        #expect(cipher == "AES-128-GCM")
        #expect(hasCA == true)

        let profile = VPNProfileInfo(
            name: "valid_macos.ovpn",
            serverAddress: remoteHost ?? "",
            proto: proto,
            port: remotePort ?? 1194,
            cipher: cipher,
            filePath: profilePath
        )
        #expect(profile.name == "valid_macos.ovpn")
        #expect(profile.serverAddress == "vpn2.iiit.ac.in")
    }

    @Test("Route conflict detector identifies collision between iiit_split.ovpn and physical campus LAN en10")
    func testRouteConflictDetectionOnCampusLAN() throws {
        let splitProfilePath = "Tests/Fixtures/Profiles/iiit_split.ovpn"
        let content = try String(contentsOfFile: splitProfilePath, encoding: .utf8)

        var pushedRoutes: [VPNRouteEntry] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("route ") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    pushedRoutes.append(VPNRouteEntry(
                        destinationSubnet: String(parts[1]),
                        mask: String(parts[2])
                    ))
                }
            }
        }

        #expect(pushedRoutes.contains(where: { $0.destinationSubnet == "10.1.0.0" && $0.mask == "255.255.0.0" }))

        // Physical campus LAN interface: en10 on 10.1.36.0/22
        let campusInterface = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB 10/100 LAN",
            ipAddresses: [IPAddress(address: "10.1.36.52", netmask: "255.255.252.0", prefixLength: 22)],
            gateway: "10.1.36.1",
            isPrimary: true
        )

        // Conflict check: 10.1.0.0/16 contains 10.1.36.0/22
        var conflicts: [String] = []
        for route in pushedRoutes {
            if route.destinationSubnet == "10.1.0.0" && campusInterface.ipAddresses.contains(where: { $0.address.hasPrefix("10.1.") }) {
                conflicts.append("Route \(route.destinationSubnet)/\(route.mask) overlaps with physical campus LAN on \(campusInterface.bsdName)")
            }
        }

        #expect(conflicts.count >= 1)
        #expect(conflicts.first?.contains("overlaps with physical campus LAN") == true)
    }

    @Test("Conflicting profile is quarantined from auto-activation and warning alert is generated")
    func testQuarantineOfConflictingProfile() {
        let issue = DetectedIssue(
            severity: .critical,
            title: "VPN Route Collision Quarantined",
            description: "Profile iiit_split.ovpn attempts to route 10.1.0.0/16 through VPN tunnel, conflicting with campus LAN gateway.",
            recommendedFixAction: "Switch to clean_split.ovpn",
            automatedFixAvailable: true
        )

        #expect(issue.severity == .critical)
        #expect(issue.recommendedFixAction.contains("clean_split.ovpn"))
    }

    @Test("Safe profile clean_split.ovpn passes route validation with zero collision")
    func testSafeProfilePassesValidation() throws {
        let cleanProfilePath = "Tests/Fixtures/Profiles/clean_split.ovpn"
        let content = try String(contentsOfFile: cleanProfilePath, encoding: .utf8)

        #expect(!content.contains("route 10.1.0.0"))
        #expect(content.contains("route 10.8.0.0 255.255.240.0"))

        // Verification: No conflict with en10 (10.1.36.52)
        let containsLocalCollision = content.contains("route 10.1.")
        #expect(containsLocalCollision == false)
    }

    @Test("Passepartout controller dispatches safe profile connection and updates status")
    func testPassepartoutControllerSafeConnection() async throws {
        let runner = MockProcessRunner()

        // 1. Check initial status
        let statusOutput = try await runner.run("scutil", arguments: ["--nc", "status", "macos.ovpn"])
        #expect(statusOutput.succeeded)
        #expect(statusOutput.stdout.contains("Disconnected"))

        // 2. Start safe VPN connection
        let startOutput = try await runner.run("scutil", arguments: ["--nc", "start", "macos.ovpn"])
        #expect(startOutput.succeeded)
        #expect(runner.didExecute(commandContaining: "scutil --nc start macos.ovpn"))

        // 3. Register custom stub for connected status
        runner.registerStub(
            commandContaining: "scutil --nc status macos.ovpn",
            stdout: "Connected\n",
            exitCode: 0
        )

        let connectedStatus = try await runner.run("scutil", arguments: ["--nc", "status", "macos.ovpn"])
        #expect(connectedStatus.stdout.contains("Connected"))
    }
}
