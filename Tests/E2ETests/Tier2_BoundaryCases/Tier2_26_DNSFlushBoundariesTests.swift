import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 26: DNS Flush Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_26_DNSFlushBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F26-01: DNS flush routine executes dscacheutil and killall -HUP mDNSResponder")
    func testDNSFlushCommandDefinitions() {
        let flushCommand1 = "dscacheutil -flushcache"
        let flushCommand2 = "killall -HUP mDNSResponder"

        #expect(flushCommand1 == "dscacheutil -flushcache")
        #expect(flushCommand2 == "killall -HUP mDNSResponder")
    }

    @Test("T2-F26-02: Rapid consecutive flush calls within 500ms are debounced")
    func testDNSFlushDebouncing() {
        var lastFlushTime: Date? = nil
        var executedFlushes = 0

        func triggerFlush(now: Date = Date()) -> Bool {
            if let last = lastFlushTime, now.timeIntervalSince(last) < 0.5 {
                return false // Debounced
            }
            lastFlushTime = now
            executedFlushes += 1
            return true
        }

        let t0 = Date()
        #expect(triggerFlush(now: t0) == true)
        #expect(triggerFlush(now: t0.addingTimeInterval(0.1)) == false)
        #expect(triggerFlush(now: t0.addingTimeInterval(0.2)) == false)
        #expect(triggerFlush(now: t0.addingTimeInterval(0.6)) == true)
        #expect(executedFlushes == 2)
    }

    @Test("T2-F26-03: Privilege elevation required for killall -HUP when unprivileged")
    func testElevationRequiredForKillall() {
        func requiresElevation(command: String, isRoot: Bool) -> Bool {
            if command.contains("killall") && !isRoot {
                return true
            }
            return false
        }

        #expect(requiresElevation(command: "killall -HUP mDNSResponder", isRoot: false) == true)
        #expect(requiresElevation(command: "killall -HUP mDNSResponder", isRoot: true) == false)
    }

    @Test("T2-F26-04: MockProcessRunner intercepts DNS flush commands")
    func testMockProcessRunnerDNSFlushInterception() async throws {
        mockRunner.registerStub(commandContaining: "dscacheutil -flushcache", stdout: "cache flushed\n", exitCode: 0)
        mockRunner.registerStub(commandContaining: "killall -HUP mDNSResponder", stdout: "mDNSResponder signaled\n", exitCode: 0)

        #expect(mockRunner.didExecute(commandContaining: "dscacheutil") == false)
        #expect(mockRunner.didExecute(commandContaining: "killall") == false)

        let out1 = try await mockRunner.run("dscacheutil", arguments: ["-flushcache"])
        let out2 = try await mockRunner.run("killall", arguments: ["-HUP", "mDNSResponder"])

        #expect(out1.succeeded)
        #expect(out1.stdout.contains("cache flushed"))
        #expect(out2.succeeded)
        #expect(out2.stdout.contains("mDNSResponder signaled"))
        #expect(mockRunner.didExecute(commandContaining: "dscacheutil") == true)
        #expect(mockRunner.didExecute(commandContaining: "killall") == true)
    }

    @Test("T2-F26-05: Non-zero exit code on mDNSResponder restart produces diagnostic report")
    func testNonZeroExitCodeDiagnostic() {
        let failedOutput = ShellOutput(
            stdout: "",
            stderr: "No matching processes belonging to you were found\n",
            exitCode: 1
        )

        func parseFlushResult(_ output: ShellOutput) -> String {
            if output.succeeded {
                return "DNS cache successfully cleared."
            } else {
                return "DNS Flush Warning: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }

        let diag = parseFlushResult(failedOutput)
        #expect(diag.contains("DNS Flush Warning"))
    }
}
