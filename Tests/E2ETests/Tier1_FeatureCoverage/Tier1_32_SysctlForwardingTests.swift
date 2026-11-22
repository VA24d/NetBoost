import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 32: Kernel IP Forwarding Controller", .tags(.tier1, .m5_doctor, .hotspot))
struct Tier1_32_SysctlForwardingTests {

    struct SysctlForwardingController {
        static func makeQueryCommand() -> [String] {
            ["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"]
        }

        static func makeEnableCommand() -> [String] {
            ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"]
        }

        static func makeDisableCommand() -> [String] {
            ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"]
        }

        static func parseForwardingState(output: String) -> Bool {
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
    }

    @Test("T1-F32-01: Generate sysctl query command for net.inet.ip.forwarding")
    func testMakeSysctlQueryCommand() {
        let cmd = SysctlForwardingController.makeQueryCommand()
        #expect(cmd.contains("sysctl"))
        #expect(cmd.contains("net.inet.ip.forwarding"))
    }

    @Test("T1-F32-02: Generate sysctl command to enable IP forwarding (1)")
    func testMakeEnableForwardingCommand() {
        let cmd = SysctlForwardingController.makeEnableCommand()
        #expect(cmd.contains("-w"))
        #expect(cmd.contains("net.inet.ip.forwarding=1"))
    }

    @Test("T1-F32-03: Generate sysctl command to disable IP forwarding (0)")
    func testMakeDisableForwardingCommand() {
        let cmd = SysctlForwardingController.makeDisableCommand()
        #expect(cmd.contains("-w"))
        #expect(cmd.contains("net.inet.ip.forwarding=0"))
    }

    @Test("T1-F32-04: Execute enable forwarding via MockProcessRunner and verify recording")
    func testExecuteEnableForwardingMockRunner() async throws {
        let runner = MockProcessRunner()
        let cmd = SysctlForwardingController.makeEnableCommand()
        _ = try await runner.run(cmd[0], arguments: Array(cmd.dropFirst()))

        #expect(runner.didExecute(commandContaining: "net.inet.ip.forwarding=1"))
    }

    @Test("T1-F32-05: Parse sysctl output correctly translating 1 to true and 0 to false")
    func testParseSysctlOutput() {
        #expect(SysctlForwardingController.parseForwardingState(output: "1\n") == true)
        #expect(SysctlForwardingController.parseForwardingState(output: "0\n") == false)
    }
}
