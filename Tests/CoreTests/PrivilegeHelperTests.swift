import Foundation
import Testing
@testable import NetBoostCore

@Suite("PrivilegeHelper and Root Elevation Tests")
struct PrivilegeHelperTests {

    @Test("Verify isRoot status accurately reflects geteuid")
    func testIsRootStatus() {
        let expectedRoot = (geteuid() == 0)
        #expect(PrivilegeHelper.isRoot == expectedRoot)
    }

    @Test("Verify netboost-helper.sh location and executable permission")
    func testLocateHelperScript() {
        let helperPath = PrivilegeHelper.locateHelperScript()
        #expect(helperPath != nil)
        if let path = helperPath {
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(FileManager.default.isExecutableFile(atPath: path))
            #expect(path.hasSuffix("netboost-helper.sh"))
        }
    }

    @Test("Verify helper script rejects unprivileged direct execution cleanly")
    func testHelperScriptUnprivilegedRejection() async throws {
        guard !PrivilegeHelper.isRoot else { return }

        guard let helperPath = PrivilegeHelper.locateHelperScript() else {
            Issue.record("Helper script not found")
            return
        }

        // Running directly without sudo should exit with code 1 and error message
        let output = try await ShellCommand.run(helperPath, arguments: ["status"])
        #expect(output.exitCode != 0)
        #expect(output.stderr.contains("must be run with root privileges"))
    }

    @Test("Verify handleElevationResult throws elevationDenied on User canceled error")
    func testElevationResultUserCanceledThrowsElevationDenied() {
        let output = ShellOutput(
            stdout: "",
            stderr: "35:86: execution error: User canceled. (-128)",
            exitCode: 1
        )
        #expect(throws: PrivilegeError.elevationDenied) {
            try PrivilegeHelper.handleElevationResult(output)
        }
    }

    @Test("Verify handleElevationResult throws elevationDenied on exit code 1")
    func testElevationResultExitCode1ThrowsElevationDenied() {
        let output = ShellOutput(
            stdout: "",
            stderr: "Authentication dialog dismissed",
            exitCode: 1
        )
        #expect(throws: PrivilegeError.elevationDenied) {
            try PrivilegeHelper.handleElevationResult(output)
        }
    }

    @Test("Verify handleElevationResult throws executionFailed on non-1 error exit codes")
    func testElevationResultNonZeroExitCodeThrowsExecutionFailed() {
        let output = ShellOutput(
            stdout: "",
            stderr: "syntax error near unexpected token",
            exitCode: 2
        )
        #expect(throws: PrivilegeError.executionFailed("syntax error near unexpected token")) {
            try PrivilegeHelper.handleElevationResult(output)
        }
    }

    @Test("Verify handleElevationResult returns output when command succeeds with exit code 0")
    func testElevationResultSuccessReturnsOutput() throws {
        let output = ShellOutput(
            stdout: "Success output",
            stderr: "",
            exitCode: 0
        )
        let result = try PrivilegeHelper.handleElevationResult(output)
        #expect(result == output)
        #expect(result.stdout == "Success output")
    }

    @Test("Verify PrivilegeError localized error descriptions")
    func testPrivilegeErrorDescriptions() {
        let denied = PrivilegeError.elevationDenied
        #expect(denied.errorDescription?.contains("denied or cancelled") == true)

        let notFound = PrivilegeError.helperNotFound("/path/to/helper")
        #expect(notFound.errorDescription?.contains("/path/to/helper") == true)

        let failed = PrivilegeError.executionFailed("something broke")
        #expect(failed.errorDescription?.contains("something broke") == true)
    }
}
