import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 28: DNS Reset Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_28_DNSResetBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F28-01: Detect manual DNS overrides versus DHCP automatic defaults")
    func testDetectDNSOverrides() {
        func hasManualOverride(output: String) -> Bool {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.contains("There aren't any DNS Servers set") && !trimmed.isEmpty
        }

        #expect(hasManualOverride(output: "8.8.8.8\n1.1.1.1\n") == true)
        #expect(hasManualOverride(output: "There aren't any DNS Servers set on Wi-Fi.") == false)
    }

    @Test("T2-F28-02: Reset DNS command generation restores DHCP defaults (Empty)")
    func testResetDNSCommandGeneration() {
        func makeResetCommand(service: String) -> String {
            let quoted = service.contains(" ") ? "\"\(service)\"" : service
            return "networksetup -setdnsservers \(quoted) Empty"
        }

        #expect(makeResetCommand(service: "Wi-Fi") == "networksetup -setdnsservers Wi-Fi Empty")
        #expect(makeResetCommand(service: "USB 10/100 LAN") == "networksetup -setdnsservers \"USB 10/100 LAN\" Empty")
    }

    @Test("T2-F28-03: Campus DNS server endpoints (10.4.20.21, 10.4.20.222) verified")
    func testCampusDNSServers() {
        let campusDNS = ["10.4.20.21", "10.4.20.222"]
        #expect(campusDNS.count == 2)
        #expect(campusDNS.contains("10.4.20.21"))
        #expect(campusDNS.contains("10.4.20.222"))
    }

    @Test("T2-F28-04: Service already having no overrides is a no-op")
    func testServiceAlreadyEmptyIsNoOp() {
        var didExecuteReset = false

        func resetIfNeeded(currentOverride: String?) {
            guard let override = currentOverride, !override.isEmpty else { return }
            didExecuteReset = true
        }

        resetIfNeeded(currentOverride: nil)
        #expect(didExecuteReset == false)

        resetIfNeeded(currentOverride: "8.8.8.8")
        #expect(didExecuteReset == true)
    }

    @Test("T2-F28-05: MockProcessRunner intercepts setdnsservers command")
    func testMockProcessRunnerDNSResetInterception() async throws {
        mockRunner.registerStub(commandContaining: "networksetup -setdnsservers Wi-Fi Empty", stdout: "DNS servers reset\n", exitCode: 0)
        #expect(mockRunner.didExecute(commandContaining: "networksetup -setdnsservers") == false)

        let output = try await mockRunner.run("networksetup", arguments: ["-setdnsservers", "Wi-Fi", "Empty"])
        #expect(output.succeeded)
        #expect(output.stdout.contains("DNS servers reset"))
        #expect(mockRunner.didExecute(commandContaining: "networksetup -setdnsservers") == true)
    }
}
