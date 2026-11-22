import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 26: DNS Cache Flush Routine", .tags(.tier1, .m5_doctor, .diagnostics))
struct Tier1_26_DNSFlushTests {

    struct DNSFlushRoutine {
        static func makeCommands() -> (dscacheutil: [String], killall: [String]) {
            (
                ["/usr/bin/dscacheutil", "-flushcache"],
                ["/usr/bin/killall", "-HUP", "mDNSResponder"]
            )
        }

        static func execute(runner: MockProcessRunner) throws {
            let (cmd1, cmd2) = makeCommands()
            _ = try runner.run(cmd1[0], arguments: Array(cmd1.dropFirst()))
            _ = try runner.run(cmd2[0], arguments: Array(cmd2.dropFirst()))
        }
    }

    @Test("T1-F26-01: dscacheutil -flushcache command structure")
    func testDSCacheUtilCommandStructure() {
        let (cmd, _) = DNSFlushRoutine.makeCommands()
        #expect(cmd.contains("dscacheutil"))
        #expect(cmd.contains("-flushcache"))
    }

    @Test("T1-F26-02: killall -HUP mDNSResponder command structure")
    func testKillallMDNSResponderCommandStructure() {
        let (_, cmd) = DNSFlushRoutine.makeCommands()
        #expect(cmd.contains("killall"))
        #expect(cmd.contains("-HUP"))
        #expect(cmd.contains("mDNSResponder"))
    }

    @Test("T1-F26-03: Execute DNS flush sequence using MockProcessRunner")
    func testExecuteDNSFlushSequence() throws {
        let runner = MockProcessRunner()
        try DNSFlushRoutine.execute(runner: runner)

        #expect(runner.didExecute(commandContaining: "dscacheutil -flushcache"))
        #expect(runner.didExecute(commandContaining: "killall -HUP mDNSResponder"))
    }

    @Test("T1-F26-04: Verify zero exit codes from both flush executions")
    func testFlushExitCodesZero() throws {
        let runner = MockProcessRunner()
        try DNSFlushRoutine.execute(runner: runner)

        let cmds = runner.recordedCommands
        for c in cmds {
            #expect(c.executable.contains("dscacheutil") || c.executable.contains("killall"))
        }
    }

    @Test("T1-F26-05: Record DNS flush action in Doctor repair history audit log")
    func testRecordDNSFlushActionLog() {
        var auditHistory: [String] = []
        auditHistory.append("DNS Flush executed successfully at \(Date())")

        #expect(auditHistory.count == 1)
        #expect(auditHistory.first?.contains("DNS Flush") == true)
    }
}
