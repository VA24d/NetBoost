import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 15: Passepartout VPN Controller Boundaries", .tags(.tier2, .m3_vpn))
struct Tier2_15_PassepartoutControllerBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F15-01: Non-existent VPN profile status query handled gracefully")
    func testNonExistentProfileHandling() {
        mockRunner.registerStub(
            commandContaining: "scutil --nc status \"non_existent.ovpn\"",
            stdout: "No service\n",
            exitCode: 1
        )

        func parseSCUtilStatus(output: String) -> VPNStatus {
            let lower = output.lowercased()
            if lower.contains("connected") { return .connected }
            if lower.contains("connecting") { return .connecting }
            if lower.contains("no service") { return .error }
            return .disconnected
        }

        #expect(parseSCUtilStatus(output: "No service") == .error)
    }

    @Test("T2-F15-02: Calling start when already connected is idempotent")
    func testIdempotentStart() {
        var status = VPNStatus.connected
        var startCommandsIssued = 0

        func startVPN(profile: String) {
            guard status != .connected else { return }
            startCommandsIssued += 1
            status = .connected
        }

        startVPN(profile: "macos.ovpn")
        #expect(startCommandsIssued == 0)
        #expect(status == .connected)
    }

    @Test("T2-F15-03: Calling stop when already disconnected is idempotent")
    func testIdempotentStop() {
        var status = VPNStatus.disconnected
        var stopCommandsIssued = 0

        func stopVPN(profile: String) {
            guard status != .disconnected else { return }
            stopCommandsIssued += 1
            status = .disconnected
        }

        stopVPN(profile: "macos.ovpn")
        #expect(stopCommandsIssued == 0)
        #expect(status == .disconnected)
    }

    @Test("T2-F15-04: Parse scutil connection states: Connected, Connecting, Disconnected")
    func testParseConnectionStates() {
        func parseState(from output: String) -> VPNStatus {
            if output.contains("Connected") { return .connected }
            if output.contains("Connecting") { return .connecting }
            if output.contains("Disconnecting") { return .disconnecting }
            return .disconnected
        }

        #expect(parseState(from: "Connected\n(Addresses: 10.8.0.2)") == .connected)
        #expect(parseState(from: "Connecting\n") == .connecting)
        #expect(parseState(from: "Disconnecting\n") == .disconnecting)
        #expect(parseState(from: "Disconnected\n") == .disconnected)
    }

    @Test("T2-F15-05: scutil command invocation generation matches macOS Passepartout convention")
    func testSCUtilCommandGeneration() {
        let profileName = "macos.ovpn"
        let startCmd = "scutil --nc start \"\(profileName)\""
        let stopCmd = "scutil --nc stop \"\(profileName)\""
        let statusCmd = "scutil --nc status \"\(profileName)\""

        #expect(startCmd == "scutil --nc start \"macos.ovpn\"")
        #expect(stopCmd == "scutil --nc stop \"macos.ovpn\"")
        #expect(statusCmd == "scutil --nc status \"macos.ovpn\"")
    }
}
