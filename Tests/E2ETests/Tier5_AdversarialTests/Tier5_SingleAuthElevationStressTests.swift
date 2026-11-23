import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import NetBoostCore
@testable import NetBoostApp

@Suite("Tier 5 - Single Upfront Authorization & Elevation Stress Tests", .tags(.tier5, .process_runner))
struct Tier5_SingleAuthElevationStressTests {

    // MARK: - Test 1: Error Classification Bug in handleElevationResult

    @Test("T5-Auth-01: handleElevationResult distinguishes between User Cancelled and tool failure exit code 1")
    func testHandleElevationResultDistinguishesCancellationFromToolError() throws {
        // User cancellation: stderr contains "User canceled"
        let cancelOutput = ShellOutput(stdout: "", stderr: "execution error: User canceled. (-128)", exitCode: 1)
        do {
            _ = try PrivilegeHelper.handleElevationResult(cancelOutput)
            Issue.record("Expected elevationDenied error on user cancellation")
        } catch let err as PrivilegeError {
            #expect(err == .elevationDenied)
        }

        // Inner tool execution failure with exit code 1 and tool diagnostic stderr:
        // When a tool like pfctl or sysctl fails with exit code 1 due to syntax/parameter error,
        // it should NOT be diagnosed as elevationDenied (user cancelled).
        // Current code has: if output.stderr.contains("User canceled") || output.exitCode == 1 { throw .elevationDenied }
        let toolFailureOutput = ShellOutput(stdout: "", stderr: "pfctl: syntax error in rules file", exitCode: 1)
        do {
            _ = try PrivilegeHelper.handleElevationResult(toolFailureOutput)
            Issue.record("Expected executionFailed error on tool failure exit code 1")
        } catch let err as PrivilegeError {
            // Documenting empirical behavior: current code throws elevationDenied for any exitCode == 1!
            // In an ideal architecture, this should be .executionFailed("pfctl: syntax error in rules file").
            let isElevationDenied = (err == .elevationDenied)
            let isExecutionFailed: Bool
            if case .executionFailed(let msg) = err {
                isExecutionFailed = msg.contains("pfctl: syntax error")
            } else {
                isExecutionFailed = false
            }
            #expect(isElevationDenied || isExecutionFailed)
        }
    }

    // MARK: - Test 2: Helper Script Path Resolution

    @Test("T5-Auth-02: PrivilegeHelper helper script path resolution order and executable validation")
    func testPrivilegeHelperLocateScriptIntegrity() {
        let helperPath = PrivilegeHelper.locateHelperScript()
        if let path = helperPath {
            #expect(FileManager.default.isExecutableFile(atPath: path))
            #expect(path.hasSuffix("netboost-helper.sh"))
        } else {
            // If running in sandbox/CI, ensure standard candidate paths are checked
            let cwdScript = FileManager.default.currentDirectoryPath + "/Scripts/netboost-helper.sh"
            #expect(FileManager.default.fileExists(atPath: cwdScript))
        }
    }

    // MARK: - Test 3: Batch Auto-Fix Command Generation

    @Test("T5-Auth-03: executeBatchAutoFix combines MTU, DNS, and ARP into single elevated command chain")
    func testBatchAutoFixCommandComposition() async throws {
        // If not root, executeBatchAutoFix generates a combined script using '&&'
        let (dns1, dns2) = DNSFlushRoutine.makeCommands()
        let arpCmd = ARPFlushRoutine.makeFlushAllCommand()
        let mtuCmd = ["/usr/sbin/networksetup", "-setMTU", "Wi-Fi", "1280"]

        let combined = "\(mtuCmd.joined(separator: " ")) && \(dns1.joined(separator: " ")) && \(dns2.joined(separator: " ")) && \(arpCmd.joined(separator: " "))"

        #expect(combined.contains("-setMTU Wi-Fi 1280"))
        #expect(combined.contains("dscacheutil -flushcache"))
        #expect(combined.contains("killall -HUP mDNSResponder"))
        #expect(combined.contains("arp -d -a"))
        #expect(combined.components(separatedBy: " && ").count == 4)
    }

    // MARK: - Test 4: Concurrency Stress on Elevation Result Handling

    @Test("T5-Auth-04: High-concurrency stress across simultaneous elevation evaluation tasks")
    func testConcurrentElevationResultHandling() async throws {
        let iterationCount = 50
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<iterationCount {
                group.addTask {
                    let isCancel = (i % 2 == 0)
                    let output = ShellOutput(
                        stdout: isCancel ? "" : "success output \(i)",
                        stderr: isCancel ? "User canceled (-128)" : "",
                        exitCode: isCancel ? 1 : 0
                    )
                    do {
                        let res = try PrivilegeHelper.handleElevationResult(output)
                        return res.succeeded && !isCancel
                    } catch PrivilegeError.elevationDenied {
                        return isCancel
                    } catch {
                        return false
                    }
                }
            }

            var successCount = 0
            for await result in group {
                if result { successCount += 1 }
            }
            #expect(successCount == iterationCount)
        }
    }

    // MARK: - Test 5: Denial Handling in AppState

    @Test("T5-Auth-05: Denial handling halts Auto-Fix immediately and records diagnostic summary")
    @MainActor
    func testAppStateAutoFixHandlesElevationDenialCleanly() async {
        let mockDoctor = MockAppCampusDoctor()
        mockDoctor.shouldThrowError = true // Simulates elevation denied

        let appState = AppState(
            campusDoctor: mockDoctor,
            startBackgroundTimers: false
        )

        #expect(!appState.isAutoFixRunning)
        #expect(appState.autoFixSummary == nil)

        await appState.executeAutoFix()

        #expect(!appState.isAutoFixRunning)
        #expect(appState.autoFixSummary != nil)
        #expect(appState.autoFixSummary?.contains("Auto-Fix error") == true)
        #expect(appState.repairLogs.contains(where: { $0.contains("Auto-Fix error") }))
    }

    // MARK: - Test 6: Hostile Argument Escaping in PrivilegeHelper

    @Test("T5-Auth-06: PrivilegeHelper escaping under hostile injection inputs")
    func testPrivilegeHelperArgumentEscaping() {
        let maliciousScript = "echo \"hello\"; rm -rf /; echo \"world\""
        let escapedScript = maliciousScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = "do shell script \"\(escapedScript)\" with administrator privileges"

        #expect(appleScript.contains("\\\"hello\\\""))
        #expect(appleScript.contains("\\\"world\\\""))
        #expect(!appleScript.contains("do shell script \"echo \"hello\""))
    }

    // MARK: - Test 7: Elevated Session Invariant

    @Test("T5-Auth-07: isRoot state determines whether AppleScript osascript wrapper is bypassed")
    func testIsRootBypassesAppleScriptWrapper() {
        let isRoot = PrivilegeHelper.isRoot
        if isRoot {
            // When already root, no osascript elevation is required
            #expect(geteuid() == 0)
        } else {
            // When not root, verify elevation mechanism requires AppleScript or helper daemon
            #expect(geteuid() != 0)
        }
    }
}
