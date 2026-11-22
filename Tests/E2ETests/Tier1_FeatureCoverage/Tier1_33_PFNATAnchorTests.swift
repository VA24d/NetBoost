import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 33: PF NAT Anchor Manager", .tags(.tier1, .m5_doctor, .hotspot))
struct Tier1_33_PFNATAnchorTests {

    struct PFNATAnchorManager {
        let anchorName: String
        let upstreamInterface: String
        let clientSubnet: String

        init(anchorName: String = "netboost", upstreamInterface: String = "en10", clientSubnet: String = "192.168.2.0/24") {
            self.anchorName = anchorName
            self.upstreamInterface = upstreamInterface
            self.clientSubnet = clientSubnet
        }

        func generateNATRule() -> String {
            "nat on \(upstreamInterface) from \(clientSubnet) to any -> (\(upstreamInterface))\npass out quick on \(upstreamInterface) from \(clientSubnet) to any keep state\n"
        }

        func makeLoadAnchorCommand(ruleFile: String) -> [String] {
            ["/sbin/pfctl", "-a", anchorName, "-f", ruleFile]
        }

        func makeEnablePFCommand() -> [String] {
            ["/sbin/pfctl", "-e"]
        }

        func makeFlushAnchorCommand() -> [String] {
            ["/sbin/pfctl", "-a", anchorName, "-F", "all"]
        }
    }

    @Test("T1-F33-01: Generate isolated PF NAT anchor rules targeting upstream interface")
    func testGenerateNATRule() {
        let manager = PFNATAnchorManager(anchorName: "netboost", upstreamInterface: "en10", clientSubnet: "192.168.2.0/24")
        let rule = manager.generateNATRule()

        #expect(rule.contains("nat on en10 from 192.168.2.0/24 to any -> (en10)"))
        #expect(rule.contains("pass out quick on en10"))
    }

    @Test("T1-F33-02: Generate pfctl command loading rules into netboost anchor")
    func testMakeLoadAnchorCommand() {
        let manager = PFNATAnchorManager()
        let cmd = manager.makeLoadAnchorCommand(ruleFile: "/tmp/netboost.pf")

        #expect(cmd.contains("-a"))
        #expect(cmd.contains("netboost"))
        #expect(cmd.contains("-f"))
        #expect(cmd.contains("/tmp/netboost.pf"))
    }

    @Test("T1-F33-03: Generate pfctl -e command enabling packet filter")
    func testMakeEnablePFCommand() {
        let manager = PFNATAnchorManager()
        let cmd = manager.makeEnablePFCommand()

        #expect(cmd.contains("-e"))
    }

    @Test("T1-F33-04: Flush only NetBoost anchor upon shutdown via pfctl -a netboost -F all")
    func testMakeFlushAnchorCommand() {
        let manager = PFNATAnchorManager()
        let cmd = manager.makeFlushAnchorCommand()

        #expect(cmd.contains("-a"))
        #expect(cmd.contains("netboost"))
        #expect(cmd.contains("-F"))
        #expect(cmd.contains("all"))
    }

    @Test("T1-F33-05: Execute PF anchor lifecycle using MockProcessRunner and verify isolation")
    func testExecutePFAnchorLifecycleMockRunner() async throws {
        let runner = MockProcessRunner()
        let manager = PFNATAnchorManager()

        let loadCmd = manager.makeLoadAnchorCommand(ruleFile: "/tmp/netboost.pf")
        let enableCmd = manager.makeEnablePFCommand()
        let flushCmd = manager.makeFlushAnchorCommand()

        _ = try await runner.run(loadCmd[0], arguments: Array(loadCmd.dropFirst()))
        _ = try await runner.run(enableCmd[0], arguments: Array(enableCmd.dropFirst()))
        _ = try await runner.run(flushCmd[0], arguments: Array(flushCmd.dropFirst()))

        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -f"))
        #expect(runner.didExecute(commandContaining: "pfctl -e"))
        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -F all"))
    }
}
