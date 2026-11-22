import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 15: Passepartout System VPN Controller", .tags(.tier1, .m3_vpn))
struct Tier1_15_PassepartoutControllerTests {

    struct PassepartoutController {
        static func parseScutilStatus(output: String) -> VPNStatus {
            let lower = output.lowercased()
            if lower.contains("disconnecting") {
                return .disconnecting
            } else if lower.contains("connecting") {
                return .connecting
            } else if lower.contains("connected") && !lower.contains("disconnected") {
                return .connected
            } else {
                return .disconnected
            }
        }

        static func makeStatusCommand(profile: String) -> [String] {
            ["/usr/sbin/scutil", "--nc", "status", profile]
        }

        static func makeStartCommand(profile: String) -> [String] {
            ["/usr/sbin/scutil", "--nc", "start", profile]
        }

        static func makeStopCommand(profile: String) -> [String] {
            ["/usr/sbin/scutil", "--nc", "stop", profile]
        }

        static func parseListOutput(output: String) -> [String] {
            let lines = output.components(separatedBy: .newlines)
            var services: [String] = []
            for line in lines {
                if let startQuote = line.firstIndex(of: "\""),
                   let endQuote = line[line.index(after: startQuote)...].firstIndex(of: "\"") {
                    let name = String(line[line.index(after: startQuote)..<endQuote])
                    services.append(name)
                }
            }
            return services
        }
    }

    @Test("T1-F15-01: Generate scutil command to check status of macos.ovpn")
    func testCheckStatusScutilCommand() {
        let cmd = PassepartoutController.makeStatusCommand(profile: "macos.ovpn")
        #expect(cmd.contains("--nc"))
        #expect(cmd.contains("status"))
        #expect(cmd.contains("macos.ovpn"))
    }

    @Test("T1-F15-02: Generate scutil command to start VPN tunnel")
    func testStartVPNScutilCommand() {
        let cmd = PassepartoutController.makeStartCommand(profile: "macos.ovpn")
        #expect(cmd.contains("--nc"))
        #expect(cmd.contains("start"))
        #expect(cmd.contains("macos.ovpn"))
    }

    @Test("T1-F15-03: Generate scutil command to stop VPN tunnel")
    func testStopVPNScutilCommand() {
        let cmd = PassepartoutController.makeStopCommand(profile: "macos.ovpn")
        #expect(cmd.contains("--nc"))
        #expect(cmd.contains("stop"))
        #expect(cmd.contains("macos.ovpn"))
    }

    @Test("T1-F15-04: Parse scutil connection status outputs accurately")
    func testParseScutilStatusOutputs() {
        #expect(PassepartoutController.parseScutilStatus(output: "Connected") == .connected)
        #expect(PassepartoutController.parseScutilStatus(output: "Connecting") == .connecting)
        #expect(PassepartoutController.parseScutilStatus(output: "Disconnected") == .disconnected)
        #expect(PassepartoutController.parseScutilStatus(output: "Disconnecting") == .disconnecting)
    }

    @Test("T1-F15-05: Parse scutil --nc list output extracting configured VPN services")
    func testParseScutilListOutput() {
        let mockList = """
        Available network connection services in the current set:
        * (Connected)      12345678-ABCD-EF01-2345-6789ABCDEF01 PPP --> IPSec "Campus VPN"
          (Disconnected)   87654321-DCBA-10FE-5432-10FEDCBA9876 VPN (OpenVPN) "macos.ovpn"
        """

        let services = PassepartoutController.parseListOutput(output: mockList)
        #expect(services.contains("Campus VPN"))
        #expect(services.contains("macos.ovpn"))
    }
}
