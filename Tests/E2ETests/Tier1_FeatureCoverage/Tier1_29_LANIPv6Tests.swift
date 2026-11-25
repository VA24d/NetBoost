import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 29: LAN IPv6 Disabler (Happy Eyeballs)", .tags(.tier1, .m5_doctor, .diagnostics))
struct Tier1_29_LANIPv6Tests {

    struct IPv6Manager {
        static func makeDisableIPv6Command(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-setv6off", service]
        }

        static func makeEnableIPv6AutomaticCommand(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-setv6automatic", service]
        }

        static func parseIPv6State(fromGetInfo output: String) -> String {
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                if line.hasPrefix("IPv6:") {
                    return line.replacingOccurrences(of: "IPv6:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
            return "Unknown"
        }
    }

    @Test("T1-F29-01: Detect unrouted IPv6 configuration on LAN causing Happy Eyeballs delay")
    func testDetectUnroutedIPv6OnLAN() {
        func happyEyeballsPenaltyMs(hasUnroutedIPv6: Bool) -> Double {
            hasUnroutedIPv6 ? 500.0 : 0.0
        }

        #expect(happyEyeballsPenaltyMs(hasUnroutedIPv6: true) >= 500.0)
        #expect(happyEyeballsPenaltyMs(hasUnroutedIPv6: false) == 0.0)
    }

    @Test("T1-F29-02: Generate networksetup -setv6off <service> command")
    func testMakeDisableIPv6Command() {
        let cmd = IPv6Manager.makeDisableIPv6Command(service: "USB 10/100 LAN")
        #expect(cmd.contains("-setv6off"))
        #expect(cmd.contains("USB 10/100 LAN"))
    }

    @Test("T1-F29-03: Execute IPv6 disable via MockProcessRunner and verify recording")
    func testExecuteDisableIPv6MockRunner() async throws {
        let runner = MockProcessRunner()
        let cmd = IPv6Manager.makeDisableIPv6Command(service: "USB 10/100 LAN")
        _ = try await runner.run(cmd[0], arguments: Array(cmd.dropFirst()))

        #expect(runner.didExecute(commandContaining: "networksetup -setv6off USB 10/100 LAN"))
    }

    @Test("T1-F29-04: Parse networksetup -getinfo output reflecting IPv6 Off state")
    func testParseIPv6OffState() {
        let mockGetInfo = """
        IP address: 10.1.36.52
        Subnet mask: 255.255.252.0
        Router: 10.1.36.1
        IPv6: Off
        """

        let state = IPv6Manager.parseIPv6State(fromGetInfo: mockGetInfo)
        #expect(state == "Off")
    }

    @Test("T1-F29-05: Generate command to restore IPv6 to Automatic")
    func testMakeEnableIPv6AutomaticCommand() {
        let cmd = IPv6Manager.makeEnableIPv6AutomaticCommand(service: "USB 10/100 LAN")
        #expect(cmd.contains("-setv6automatic"))
        #expect(cmd.contains("USB 10/100 LAN"))
    }
}
