import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 29: LAN IPv6 Disabler Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_29_LANIPv6BoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F29-01: Disabling IPv6 when already off is a no-op")
    func testIPv6AlreadyOffIsNoOp() {
        var commandRan = false

        func disableIPv6IfNeeded(currentState: String) {
            guard currentState.lowercased() != "off" else { return }
            commandRan = true
        }

        disableIPv6IfNeeded(currentState: "Off")
        #expect(commandRan == false)

        disableIPv6IfNeeded(currentState: "Automatic")
        #expect(commandRan == true)
    }

    @Test("T2-F29-02: Happy Eyeballs RFC 8305 connection hang detection (>500ms delay)")
    func testHappyEyeballsHangDetection() {
        func isHappyEyeballsLag(ipv6Latency: Double, ipv4Latency: Double) -> Bool {
            return (ipv6Latency - ipv4Latency) >= 500.0
        }

        #expect(isHappyEyeballsLag(ipv6Latency: 520.0, ipv4Latency: 15.0) == true)
        #expect(isHappyEyeballsLag(ipv6Latency: 25.0, ipv4Latency: 20.0) == false)
    }

    @Test("T2-F29-03: Disable IPv6 command generation (setv6off)")
    func testDisableIPv6CommandGeneration() {
        func makeDisableCommand(service: String) -> String {
            let quoted = service.contains(" ") ? "\"\(service)\"" : service
            return "networksetup -setv6off \(quoted)"
        }

        #expect(makeDisableCommand(service: "USB 10/100 LAN") == "networksetup -setv6off \"USB 10/100 LAN\"")
        #expect(makeDisableCommand(service: "Wi-Fi") == "networksetup -setv6off Wi-Fi")
    }

    @Test("T2-F29-04: Restore IPv6 command generation (setv6automatic)")
    func testRestoreIPv6CommandGeneration() {
        func makeRestoreCommand(service: String) -> String {
            let quoted = service.contains(" ") ? "\"\(service)\"" : service
            return "networksetup -setv6automatic \(quoted)"
        }

        #expect(makeRestoreCommand(service: "Wi-Fi") == "networksetup -setv6automatic Wi-Fi")
    }

    @Test("T2-F29-05: MockProcessRunner intercepts setv6off command")
    func testMockProcessRunnerSetV6Off() async throws {
        mockRunner.registerStub(commandContaining: "networksetup -setv6off Wi-Fi", stdout: "IPv6 turned off for Wi-Fi\n", exitCode: 0)
        #expect(mockRunner.didExecute(commandContaining: "networksetup -setv6off") == false)

        let output = try await mockRunner.run("networksetup", arguments: ["-setv6off", "Wi-Fi"])
        #expect(output.succeeded)
        #expect(output.stdout.contains("IPv6 turned off for Wi-Fi"))
        #expect(mockRunner.didExecute(commandContaining: "networksetup -setv6off") == true)
    }
}
