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

    @Test("Execute command with >128KB output (>64KB pipe buffer) does not deadlock")
    func testLargeOutputExceedingPipeBufferDoesNotDeadlock() async throws {
        let output = try await ShellCommand.run(
            "python",
            arguments: ["-c", "print('A' * 131072)"],
            timeout: 5.0
        )
        #expect(output.succeeded == true)
        #expect(output.exitCode == 0)
        #expect(output.stdout.count >= 131072)
        #expect(output.duration < 4.0)
    }

    @Test("Execute host ps -ax command with large output does not deadlock")
    func testPsAxCommandDoesNotDeadlock() async throws {
        let output = try await ShellCommand.run(
            "/bin/ps",
            arguments: ["-ax", "-o", "stat,command"],
            timeout: 5.0
        )
        #expect(output.succeeded == true)
        #expect(output.exitCode == 0)
        #expect(output.stdout.count > 1000)
    }

    @Test("Execute command with >128KB stderr output does not deadlock")
    func testLargeStderrDoesNotDeadlock() async throws {
        let output = try await ShellCommand.run(
            "python",
            arguments: ["-c", "import sys; sys.stderr.write('E' * 131072)"],
            timeout: 5.0
        )
        #expect(output.succeeded == true)
        #expect(output.exitCode == 0)
        #expect(output.stderr.count >= 131072)
        #expect(output.duration < 4.0)
    }
}
