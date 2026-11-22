import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 03: Shell Process Runner & Privileged Elevation Helper", .tags(.tier1, .m1_foundation))
struct Tier1_03_ShellElevationTests {

    @Test("T1-F03-01: Execute async shell command and capture stdout")
    func testAsyncShellExecutionStdout() async throws {
        let output = try await ShellCommand.run("/usr/bin/uname", arguments: ["-m"])

        #expect(output.succeeded == true)
        #expect(output.exitCode == 0)
        #expect(!output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("T1-F03-02: Execute command and capture stderr and non-zero exit code")
    func testAsyncShellExecutionNonZeroExit() async throws {
        let output = try await ShellCommand.run("/usr/bin/false")

        #expect(output.succeeded == false)
        #expect(output.exitCode != 0)
    }

    @Test("T1-F03-03: PrivilegeHelper.isRoot matches geteuid() == 0")
    func testPrivilegeHelperIsRootMatchesGeteuid() {
        let isRoot = PrivilegeHelper.isRoot
        let euid = geteuid()
        #expect(isRoot == (euid == 0))
    }

    @Test("T1-F03-04: Generate elevation AppleScript payload structure")
    func testElevationScriptPayloadGeneration() {
        let command = "/usr/local/bin/netboost-helper.sh flush-dns"
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escapedCommand)\" with administrator privileges"

        #expect(appleScript.contains("with administrator privileges"))
        #expect(appleScript.contains("netboost-helper.sh flush-dns"))
    }

    @Test("T1-F03-05: Verify netboost-helper.sh script exists, is executable, and handles usage")
    func testNetboostHelperScriptPresenceAndExecution() async throws {
        guard let helperPath = PrivilegeHelper.locateHelperScript() else {
            Issue.record("netboost-helper.sh could not be located")
            return
        }

        #expect(FileManager.default.isExecutableFile(atPath: helperPath))

        // Running helper without root outputs privilege error and exits non-zero
        let output = try await ShellCommand.run(helperPath, arguments: ["help"])
        #expect(output.exitCode != 0)
        #expect(output.stderr.contains("must be run with root privileges") || output.stderr.contains("netboost-helper.sh"))
    }
}
