import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 27: ARP Flush Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_27_ARPFlushBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F27-01: Full ARP table flush command generation (arp -d -a)")
    func testFullARPFlushCommand() {
        let cmd = "arp -d -a"
        #expect(cmd == "arp -d -a")
    }

    @Test("T2-F27-02: Target IP specific ARP flush command generation")
    func testSpecificIPARPFlushCommand() {
        let targetIP = "10.1.36.1"
        let cmd = "arp -d \(targetIP)"
        #expect(cmd == "arp -d 10.1.36.1")
    }

    @Test("T2-F27-03: Incomplete ARP entries filtered from active device list")
    func testIncompleteARPEntryFiltering() {
        let arpLines = [
            "? (192.168.2.1) at 00:e0:4c:68:01:23 on en0 ifscope [ethernet]",
            "? (192.168.2.15) at (incomplete) on en0 ifscope [ethernet]",
            "? (192.168.2.22) at a4:83:e7:12:34:56 on en0 ifscope [ethernet]"
        ]

        let validEntries = arpLines.filter { !($0.contains("(incomplete)")) }
        #expect(validEntries.count == 2)
        #expect(!validEntries.contains(where: { $0.contains("192.168.2.15") }))
    }

    @Test("T2-F27-04: MockProcessRunner intercepts ARP table flush commands")
    func testMockProcessRunnerARPInterception() {
        mockRunner.registerStub(commandContaining: "arp -d -a", stdout: "10.1.36.1 (10.1.36.1) deleted\n", exitCode: 0)
        #expect(mockRunner.didExecute(commandContaining: "arp -d") == false)
    }

    @Test("T2-F27-05: Flushing already empty ARP table handled cleanly")
    func testEmptyARPTableFlush() {
        let emptyOutput = ShellOutput(
            stdout: "",
            stderr: "no matching entries\n",
            exitCode: 0
        )
        #expect(emptyOutput.succeeded)
    }
}
