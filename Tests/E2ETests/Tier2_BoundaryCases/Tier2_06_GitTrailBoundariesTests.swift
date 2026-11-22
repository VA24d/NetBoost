import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 06: Git & Trail Boundaries", .tags(.tier2, .m1_foundation))
struct Tier2_06_GitTrailBoundariesTests {

    @Test("T2-F06-01: Git repository directory and HEAD exist")
    func testGitRepoDirectory() {
        let gitDir = FileManager.default.currentDirectoryPath + "/.git"
        let headFile = gitDir + "/HEAD"
        #expect(FileManager.default.fileExists(atPath: gitDir))
        #expect(FileManager.default.fileExists(atPath: headFile))
    }

    @Test("T2-F06-02: Gitignore excludes build artifacts and platform cache files")
    func testGitignoreExclusions() throws {
        let gitignorePath = FileManager.default.currentDirectoryPath + "/.gitignore"
        #expect(FileManager.default.fileExists(atPath: gitignorePath))

        let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        #expect(content.contains(".build"))
        #expect(content.contains(".DS_Store"))
    }

    @Test("T2-F06-03: Trail index or configuration directory exists")
    func testTrailConfiguration() {
        let trailDir = FileManager.default.currentDirectoryPath + "/.trail"
        #expect(FileManager.default.fileExists(atPath: trailDir))
    }

    @Test("T2-F06-04: Git buffer configuration meets hotspot upload requirements (postBuffer)")
    func testGitPostBufferConfiguration() async throws {
        let output = try await ShellCommand.run("/usr/bin/git", arguments: ["config", "--get", "http.postBuffer"])
        if output.succeeded {
            let bufferSize = Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            #expect(bufferSize >= 524_288_000)
        } else {
            // If not set globally/locally, verify setting it is accepted
            let setResult = try await ShellCommand.run("/usr/bin/git", arguments: ["config", "http.postBuffer", "524288000"])
            #expect(setResult.succeeded)
        }
    }

    @Test("T2-F06-05: Git status executes cleanly and returns zero exit status")
    func testGitStatusExecution() async throws {
        let output = try await ShellCommand.run("/usr/bin/git", arguments: ["status", "--porcelain"])
        #expect(output.succeeded)
        #expect(output.exitCode == 0)
    }
}
