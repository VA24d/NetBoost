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

        if let helperPath = PrivilegeHelper.locateHelperScript() {
            // Running directly without sudo should exit with code 1 and error message
            let output = try await ShellCommand.run(helperPath, arguments: ["status"])
            #expect(output.exitCode != 0)
            #expect(output.stderr.contains("must be run with root privileges"))
        }
    }
}
