import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 03: Shell Elevation Boundaries", .tags(.tier2, .m1_foundation))
struct Tier2_03_ShellElevationBoundariesTests {

    @Test("T2-F03-01: Command exceeding short timeout throws timedOut error")
    func testCommandTimeout() async throws {
        // Run sleep command with shorter timeout
        await #expect(throws: ShellError.self) {
            try await ShellCommand.run("/bin/sleep", arguments: ["2.0"], timeout: 0.1)
        }
    }

    @Test("T2-F03-02: Non-existent executable path throws processError")
    func testNonExistentExecutable() async {
        await #expect(throws: ShellError.self) {
            try await ShellCommand.run("/usr/bin/non_existent_binary_xyz_12345", arguments: [])
        }
    }

    @Test("T2-F03-03: Command producing massive stdout executes without deadlock")
    func testLargeStdoutBufferHandling() async throws {
        // Output 50,000 lines of deterministic characters
        let output = try await ShellCommand.runBash("for i in {1..5000}; do echo 'NETBOOST_BUFFER_STRESS_LINE'; done", timeout: 10.0)
        #expect(output.succeeded)
        #expect(output.stdout.count > 100_000)
    }

    @Test("T2-F03-04: User cancels elevation simulated maps to elevationDenied error")
    func testSimulatedUserCancelElevation() {
        let deniedError = PrivilegeError.elevationDenied
        #expect(deniedError.errorDescription?.contains("denied or cancelled") == true)

        let helperNotFoundError = PrivilegeError.helperNotFound("/invalid/path/helper.sh")
        #expect(helperNotFoundError.errorDescription?.contains("not found") == true)
    }

    @Test("T2-F03-05: Metacharacters in argv array are passed verbatim without shell injection")
    func testMetacharacterArgumentSafety() async throws {
        let metacharacters = "; rm -rf /tmp/nonexistent_test && echo 'injected' | cat"
        let output = try await ShellCommand.run("/bin/echo", arguments: [metacharacters])

        #expect(output.succeeded)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == metacharacters)
    }
}
