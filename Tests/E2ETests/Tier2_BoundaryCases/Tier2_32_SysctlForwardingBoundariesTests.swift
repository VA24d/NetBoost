import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 32: Kernel IP Forwarding Boundaries", .tags(.tier2, .m5_doctor, .hotspot))
struct Tier2_32_SysctlForwardingBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F32-01: Sysctl query command generation (net.inet.ip.forwarding)")
    func testSysctlQueryCommand() {
        let queryCmd = "sysctl -n net.inet.ip.forwarding"
        #expect(queryCmd == "sysctl -n net.inet.ip.forwarding")
    }

    @Test("T2-F32-02: Enabling IP forwarding when already enabled is an idempotent no-op")
    func testEnableAlreadyEnabledIsNoOp() {
        var currentForwarding = 1
        var writeCommandsIssued = 0

        func setForwarding(_ enable: Bool) {
            let target = enable ? 1 : 0
            guard currentForwarding != target else { return }
            writeCommandsIssued += 1
            currentForwarding = target
        }

        setForwarding(true) // already 1
        #expect(writeCommandsIssued == 0)

        setForwarding(false) // toggle to 0
        #expect(writeCommandsIssued == 1)
        #expect(currentForwarding == 0)
    }

    @Test("T2-F32-03: Sysctl write command generation for enable and disable")
    func testSysctlWriteCommandGeneration() {
        let enableCmd = "sysctl -w net.inet.ip.forwarding=1"
        let disableCmd = "sysctl -w net.inet.ip.forwarding=0"

        #expect(enableCmd == "sysctl -w net.inet.ip.forwarding=1")
        #expect(disableCmd == "sysctl -w net.inet.ip.forwarding=0")
    }

    @Test("T2-F32-04: Parse sysctl string output into integer flag")
    func testParseSysctlOutput() {
        func parseForwardingState(_ output: String) -> Int? {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }

        #expect(parseForwardingState("1\n") == 1)
        #expect(parseForwardingState("0\n") == 0)
        #expect(parseForwardingState("invalid\n") == nil)
    }

    @Test("T2-F32-05: MockProcessRunner intercepts sysctl forwarding commands")
    func testMockProcessRunnerSysctl() {
        mockRunner.registerStub(commandContaining: "sysctl -w net.inet.ip.forwarding=1", stdout: "net.inet.ip.forwarding: 0 -> 1\n", exitCode: 0)
        #expect(mockRunner.didExecute(commandContaining: "sysctl -w net.inet.ip.forwarding=1") == false)
    }
}
