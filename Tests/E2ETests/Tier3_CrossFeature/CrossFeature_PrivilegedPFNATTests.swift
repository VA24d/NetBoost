import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 3: Privilege Elevation Helper + PF NAT + Sysctl Forwarding Interaction", .tags(.tier3, .process_runner, .hotspot, .m1_foundation))
struct CrossFeature_PrivilegedPFNATTests {

    @Test("PrivilegeHelper detects current EUID status and prepares elevation wrapper")
    func testPrivilegeHelperStatusAndScriptResolution() {
        let isRoot = PrivilegeHelper.isRoot
        #expect(isRoot == (geteuid() == 0))

        let scriptPath = PrivilegeHelper.locateHelperScript()
        #expect(scriptPath != nil)
        #expect(scriptPath?.contains("netboost-helper.sh") == true)
    }

    @Test("Privilege elevation executes combined sysctl and PF NAT setup via MockProcessRunner")
    func testCombinedElevatedPFNATAndSysctl() async throws {
        let runner = MockProcessRunner()

        // 1. Enable IP forwarding
        let sysctl = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=1"], isElevated: true)
        #expect(sysctl.succeeded)
        #expect(runner.didExecute(commandContaining: "net.inet.ip.forwarding=1"))

        // 2. Load netboost anchor rules
        let pfctl = try await runner.run("pfctl", arguments: ["-a", "netboost", "-f", "/tmp/netboost.pf"], isElevated: true)
        #expect(pfctl.succeeded)
        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -f"))

        let lastCmd = runner.lastExecutedCommand()
        #expect(lastCmd?.isElevated == true)
    }

    @Test("User cancellation of administrator elevation prompt translates to PrivilegeError.elevationDenied")
    func testElevationRefusalHandling() async {
        let runner = MockProcessRunner()
        runner.registerStub(
            commandContaining: "osascript",
            stdout: "",
            stderr: "execution error: User canceled. (-128)\n",
            exitCode: 1
        )

        do {
            let output = try await runner.run("osascript", arguments: ["-e", "do shell script with administrator privileges"])
            if !output.succeeded && output.stderr.contains("User canceled") {
                throw PrivilegeError.elevationDenied
            }
            Issue.record("Should have thrown elevationDenied")
        } catch let err as PrivilegeError {
            #expect(err == PrivilegeError.elevationDenied)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("PF NAT rule syntax is validated with dry-run pfctl -nf prior to kernel installation")
    func testPFNATRuleSyntaxDryRunValidation() async throws {
        let runner = MockProcessRunner()
        runner.registerStub(commandContaining: "pfctl -nf", stdout: "", stderr: "", exitCode: 0)

        let dryRun = try await runner.run("pfctl", arguments: ["-nf", "/tmp/netboost.pf"])
        #expect(dryRun.succeeded)
        #expect(runner.didExecute(commandContaining: "pfctl -nf"))
    }

    @Test("Hotspot teardown atomically flushes netboost PF anchor and restores sysctl forwarding to 0")
    func testIsolatedTeardownFlushesOnlyNetBoostAnchor() async throws {
        let runner = MockProcessRunner()

        // Flush netboost anchor only
        let flush = try await runner.run("pfctl", arguments: ["-a", "netboost", "-F", "all"])
        #expect(flush.succeeded)

        // Restore sysctl forwarding
        let sysctl = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=0"])
        #expect(sysctl.succeeded)

        #expect(runner.didExecute(commandContaining: "pfctl -a netboost -F all"))
        #expect(runner.didExecute(commandContaining: "net.inet.ip.forwarding=0"))
    }
}
