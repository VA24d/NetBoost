import Testing
import Foundation

@Suite("Feature 05: Build & Test Tooling", .tags(.tier1, .m1_foundation))
struct Tier1_05_BuildToolingTests {

    @Test("T1-F05-01: Verify Scripts/build.sh exists and is executable")
    func testBuildScriptIntegrity() {
        let buildScriptPath = "Scripts/build.sh"
        #expect(FileManager.default.fileExists(atPath: buildScriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: buildScriptPath))
    }

    @Test("T1-F05-02: Verify Scripts/run_tests.sh exists and is executable")
    func testRunTestsScriptIntegrity() {
        let runTestsScriptPath = "Scripts/run_tests.sh"
        #expect(FileManager.default.fileExists(atPath: runTestsScriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: runTestsScriptPath))
    }

    @Test("T1-F05-03: Verify Makefile contains build and test targets")
    func testMakefileTargets() throws {
        let makefilePath = "Makefile"
        #expect(FileManager.default.fileExists(atPath: makefilePath))

        let content = try String(contentsOfFile: makefilePath, encoding: .utf8)
        #expect(content.contains("build:"))
        #expect(content.contains("test:"))
    }

    @Test("T1-F05-04: Verify vfs.yaml exists and defines CLT Swift overlays")
    func testVFSOverlayConfiguration() throws {
        let vfsPath = "vfs.yaml"
        #expect(FileManager.default.fileExists(atPath: vfsPath))

        let content = try String(contentsOfFile: vfsPath, encoding: .utf8)
        #expect(content.contains("\"version\": 0"))
        #expect(content.contains("Foundation.swiftoverlay"))
    }

    @Test("T1-F05-05: Verify Package.swift manifest defines macOS 14+ and targets")
    func testPackageManifestConfiguration() throws {
        let packagePath = "Package.swift"
        #expect(FileManager.default.fileExists(atPath: packagePath))

        let content = try String(contentsOfFile: packagePath, encoding: .utf8)
        #expect(content.contains(".macOS(.v14)"))
        #expect(content.contains("NetBoostCore"))
        #expect(content.contains("NetBoostApp"))
        #expect(content.contains("NetBoostTests"))
    }
}
