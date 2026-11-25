import Foundation
import Testing

@Suite("Tier 2 - Feature 05: Build Tooling Boundaries", .tags(.tier2, .m1_foundation))
struct Tier2_05_BuildToolingBoundariesTests {

    @Test("T2-F05-01: Package manifest contains required library, app, and test targets")
    func testPackageManifestTargets() throws {
        let packagePath = FileManager.default.currentDirectoryPath + "/Package.swift"
        #expect(FileManager.default.fileExists(atPath: packagePath))

        let packageContent = try String(contentsOfFile: packagePath, encoding: .utf8)
        #expect(packageContent.contains("NetBoostCore"))
        #expect(packageContent.contains("NetBoostApp"))
        #expect(packageContent.contains("NetBoostTests"))
        #expect(packageContent.contains(".macOS(.v14)"))
    }

    @Test("T2-F05-02: VFS overlay exists and masks Foundation.swiftoverlay to prevent CLT defects")
    func testVFSOverlayStructure() throws {
        let vfsPath = FileManager.default.currentDirectoryPath + "/vfs.yaml"
        #expect(FileManager.default.fileExists(atPath: vfsPath))

        let vfsContent = try String(contentsOfFile: vfsPath, encoding: .utf8)
        #expect(vfsContent.contains("Foundation.swiftoverlay"))
        #expect(vfsContent.contains("\"version\""))
    }

    @Test("T2-F05-03: Shell build and test scripts exist and have executable permissions")
    func testScriptsExecutablePermissions() {
        let runTestsPath = FileManager.default.currentDirectoryPath + "/Scripts/run_tests.sh"
        let buildPath = FileManager.default.currentDirectoryPath + "/Scripts/build.sh"

        #expect(FileManager.default.isExecutableFile(atPath: runTestsPath))
        #expect(FileManager.default.isExecutableFile(atPath: buildPath))
    }

    @Test("T2-F05-04: Makefile provides operational build and test targets")
    func testMakefileTargets() throws {
        let makefilePath = FileManager.default.currentDirectoryPath + "/Makefile"
        #expect(FileManager.default.fileExists(atPath: makefilePath))

        let content = try String(contentsOfFile: makefilePath, encoding: .utf8)
        #expect(content.contains("build:"))
        #expect(content.contains("test:"))
    }

    @Test("T2-F05-05: Swift Testing developer frameworks path is valid on host system")
    func testCLTFrameworksPath() {
        let fm = FileManager.default
        let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
        let xcodeFrameworks = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
        let hasXcodeFrameworks = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .contains { $0.hasPrefix("Xcode") && fm.fileExists(atPath: "/Applications/\($0)/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks") }
        #expect(fm.fileExists(atPath: cltFrameworks) || fm.fileExists(atPath: xcodeFrameworks) || hasXcodeFrameworks)
    }
}
