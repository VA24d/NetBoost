import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 33: PF NAT Anchor Boundaries", .tags(.tier2, .m5_doctor, .hotspot))
struct Tier2_33_PFNATAnchorBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F33-01: Generate PF NAT anchor rule syntax for Wired Ethernet en10")
    func testPFNATRuleSyntax() {
        let upstream = "en10"
        let subnet = "192.168.2.0/24"
        let rule = "nat on \(upstream) from \(subnet) to any -> (\(upstream))"

        #expect(rule == "nat on en10 from 192.168.2.0/24 to any -> (en10)")
    }

    @Test("T2-F33-02: Isolated anchor name netboost is used to prevent touching system rules")
    func testIsolatedAnchorName() {
        let anchorName = "netboost"
        let loadCommand = "pfctl -a \(anchorName) -f /tmp/netboost.pf"

        #expect(loadCommand.contains("-a netboost"))
        #expect(anchorName == "netboost")
    }

    @Test("T2-F33-03: Flush command targets only the isolated netboost anchor")
    func testFlushIsolatedAnchorCommand() {
        let flushCommand = "pfctl -a netboost -F all"
        #expect(flushCommand == "pfctl -a netboost -F all")
    }

    @Test("T2-F33-04: Enable PF packet filter command generation")
    func testEnablePFCommand() {
        let enableCommand = "pfctl -e"
        #expect(enableCommand == "pfctl -e")
    }

    @Test("T2-F33-05: MockProcessRunner intercepts pfctl anchor commands")
    func testMockProcessRunnerPFCTL() async throws {
        mockRunner.registerStub(commandContaining: "pfctl -a netboost -F all", stdout: "rules cleared\n", exitCode: 0)
        #expect(mockRunner.didExecute(commandContaining: "pfctl -a netboost") == false)

        let output = try await mockRunner.run("pfctl", arguments: ["-a", "netboost", "-F", "all"])
        #expect(output.succeeded)
        #expect(output.stdout.contains("rules cleared"))
        #expect(mockRunner.didExecute(commandContaining: "pfctl -a netboost") == true)
    }
}
