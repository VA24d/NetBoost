import Testing
import Foundation
@testable import NetBoostCore

@Suite("Campus Diagnostics: ServiceOrderManager Unit & Integration Tests")
struct ServiceOrderManagerTests {

    @Test("Parse networksetup -listnetworkserviceorder output format accurately")
    func testParseServiceOrder() {
        let mockOutput = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100 LAN
        (Hardware Port: USB 10/100 LAN, Device: en10)
        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (3) iPhone USB
        (Hardware Port: iPhone USB, Device: en9)
        """

        let entries = ServiceOrderManager.parseServiceOrder(output: mockOutput)
        #expect(entries.count == 3)
        #expect(entries[0].order == 1)
        #expect(entries[0].name == "USB 10/100 LAN")
        #expect(entries[0].device == "en10")

        #expect(entries[1].order == 2)
        #expect(entries[1].name == "Wi-Fi")
        #expect(entries[1].device == "en0")

        #expect(entries[2].order == 3)
        #expect(entries[2].name == "iPhone USB")
        #expect(entries[2].device == "en9")
    }

    @Test("Generate networksetup -ordernetworkservices command with ordered parameters")
    func testMakeOrderCommand() {
        let services = ["USB 10/100 LAN", "Wi-Fi", "iPhone USB"]
        let cmd = ServiceOrderManager.makeOrderNetworkServicesCommand(orderedServices: services)

        #expect(cmd.count == 5)
        #expect(cmd[0] == "/usr/sbin/networksetup")
        #expect(cmd[1] == "-ordernetworkservices")
        #expect(cmd[2] == "USB 10/100 LAN")
        #expect(cmd[3] == "Wi-Fi")
        #expect(cmd[4] == "iPhone USB")
    }

    @Test("Prioritize Ethernet over Wi-Fi reorders services correctly")
    func testPrioritizeEthernet() {
        let manager = ServiceOrderManager()
        let initial = ["Wi-Fi", "iPhone USB", "USB 10/100 LAN", "Thunderbolt Bridge"]
        let prioritized = manager.prioritizeEthernet(services: initial)

        #expect(prioritized.first == "USB 10/100 LAN")
        #expect(prioritized[1] == "Wi-Fi")
    }

    @Test("Handles empty input without crashing")
    func testEmptyServiceOrder() {
        let entries = ServiceOrderManager.parseServiceOrder(output: "")
        #expect(entries.isEmpty)
    }

    @Test("Shell script safely quotes service names with spaces and metacharacters")
    func testOrderServicesShellQuoting() {
        let script = ServiceOrderManager.makeOrderNetworkServicesShellScript(orderedServices: [
            "USB 10/100 LAN",
            "Wi-Fi",
            "Test; $(whoami)"
        ])
        #expect(script == "'/usr/sbin/networksetup' '-ordernetworkservices' 'USB 10/100 LAN' 'Wi-Fi' 'Test; $(whoami)'")
    }

    @Test("reorderServices re-throws elevationDenied without calling helper and propagates helper failures")
    func testReorderServicesErrorPropagation() async {
        final class MockExecutor: PrivilegeCommandExecuting, @unchecked Sendable {
            var isRoot: Bool = false
            var helperPath: String? = "/usr/local/bin/netboost-helper.sh"
            var elevatedError: Error? = nil
            var helperError: Error? = nil
            var helperCalls: Int = 0

            func locateHelperScript() -> String? { helperPath }
            func runCommand(_ executable: String, arguments: [String]) async throws -> ShellOutput { ShellOutput(stdout: "", stderr: "", exitCode: 0) }
            func runBash(_ script: String) async throws -> ShellOutput { ShellOutput(stdout: "", stderr: "", exitCode: 0) }
            func runElevated(script: String) async throws -> ShellOutput {
                if let err = elevatedError { throw err }
                return ShellOutput(stdout: "", stderr: "", exitCode: 0)
            }
            func runHelper(action: String, arguments: [String]) async throws -> ShellOutput {
                helperCalls += 1
                if let err = helperError { throw err }
                return ShellOutput(stdout: "", stderr: "", exitCode: 0)
            }
        }

        let deniedExec = MockExecutor()
        deniedExec.elevatedError = PrivilegeError.elevationDenied
        let deniedManager = ServiceOrderManager(executor: deniedExec)

        await #expect(throws: PrivilegeError.elevationDenied) {
            try await deniedManager.reorderServices(orderedServices: ["USB 10/100 LAN", "Wi-Fi"])
        }
        #expect(deniedExec.helperCalls == 0)

        let helperFailExec = MockExecutor()
        helperFailExec.elevatedError = PrivilegeError.executionFailed("elevated fail")
        helperFailExec.helperError = PrivilegeError.executionFailed("helper fail")
        let helperFailManager = ServiceOrderManager(executor: helperFailExec)

        await #expect(throws: PrivilegeError.executionFailed("helper fail")) {
            try await helperFailManager.reorderServices(orderedServices: ["USB 10/100 LAN", "Wi-Fi"])
        }
        #expect(helperFailExec.helperCalls == 1)
    }
}
