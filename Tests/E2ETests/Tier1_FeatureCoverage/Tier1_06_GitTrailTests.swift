import Testing
import Foundation

@Suite("Feature 06: Git & Trail Context Graph Setup", .tags(.tier1, .m1_foundation))
struct Tier1_06_GitTrailTests {

    @Test("T1-F06-01: Verify git repository is initialized (.git exists)")
    func testGitRepositoryInitialized() {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: ".git", isDirectory: &isDir)
        #expect(exists && isDir.boolValue)
    }

    @Test("T1-F06-02: Verify .gitignore excludes build and temporary artifacts")
    func testGitIgnoreRules() throws {
        let gitignorePath = ".gitignore"
        #expect(FileManager.default.fileExists(atPath: gitignorePath))

        let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        #expect(content.contains(".build"))
        #expect(content.contains(".DS_Store"))
    }

    @Test("T1-F06-03: Verify .trail directory structure exists")
    func testTrailStructurePresence() {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: ".trail", isDirectory: &isDir)
        #expect(exists && isDir.boolValue)
    }

    @Test("T1-F06-04: Verify .trail/cache is configured (and valid directory when populated)")
    func testTrailCachePresence() throws {
        let trailIgnoreExists = FileManager.default.fileExists(atPath: ".trail/.gitignore")
        let gitignoreContent = (try? String(contentsOfFile: ".gitignore", encoding: .utf8)) ?? ""
        #expect(trailIgnoreExists || gitignoreContent.contains(".trail/cache"))

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: ".trail/cache", isDirectory: &isDir) {
            #expect(isDir.boolValue)
        }
    }

    @Test("T1-F06-05: Verify indexed symbols and cards exist in trail cache")
    func testTrailIndexedCards() throws {
        let cachePath = ".trail/cache"
        if FileManager.default.fileExists(atPath: cachePath) {
            let files = try FileManager.default.contentsOfDirectory(atPath: cachePath)
            #expect(!files.isEmpty)
        }
    }
}
