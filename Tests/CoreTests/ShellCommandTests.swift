import Foundation
import Testing
@testable import NetBoostCore

@Suite("ShellCommand Async Execution Tests")
struct ShellCommandTests {

    @Test("Execute simple command with stdout capture")
    func testSimpleCommandExecution() async throws {
        let output = try await ShellCommand.run("/bin/echo", arguments: ["Hello NetBoost"])
        #expect(output.succeeded == true)
        #expect(output.exitCode == 0)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello NetBoost")
        #expect(output.duration >= 0)
    }

    @Test("Execute command with custom environment variables")
    func testCommandWithEnvironment() async throws {
        let output = try await ShellCommand.runBash(
            "echo $NETBOOST_TEST_VAR",
            environment: ["NETBOOST_TEST_VAR": "ActiveValue"]
        )
        #expect(output.succeeded == true)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ActiveValue")
    }

    @Test("Execute command that fails with non-zero exit code")
    func testFailingCommandExitCode() async throws {
        let output = try await ShellCommand.runBash("ls /definitely_non_existent_netboost_path_xyz_987 2>&1 || exit 42")
        #expect(output.exitCode == 42)
        #expect(output.succeeded == false)
    }

    @Test("Command timeout terminates process and throws ShellError.timedOut")
    func testCommandTimeoutEnforcement() async throws {
        var didCatchTimeout = false
        do {
            _ = try await ShellCommand.run("/bin/sleep", arguments: ["3"], timeout: 0.3)
        } catch let error as ShellError {
            if case .timedOut(let timeout) = error {
                #expect(timeout == 0.3)
                didCatchTimeout = true
            }
        }
        #expect(didCatchTimeout == true)
    }
}
