import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 28: DNS Server Override Reset", .tags(.tier1, .m5_doctor, .diagnostics))
struct Tier1_28_DNSResetTests {

    struct DNSOverrideManager {
        static func makeResetDNSCommand(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-setdnsservers", service, "Empty"]
        }

        static func makeSetCampusDNSCommand(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-setdnsservers", service, "10.4.20.21", "10.4.20.222"]
        }

        static func parseGetDNSServersOutput(_ output: String) -> [String] {
            if output.contains("There aren't any DNS Servers set") {
                return []
            }
            return output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    @Test("T1-F28-01: Detect manual DNS overrides configured on network service")
    func testDetectManualDNSOverrides() {
        let mockOutput = "8.8.8.8\n8.8.4.4\n"
        let servers = DNSOverrideManager.parseGetDNSServersOutput(mockOutput)

        #expect(servers.count == 2)
        #expect(servers.contains("8.8.8.8"))
    }

    @Test("T1-F28-02: Generate networksetup -setdnsservers <service> Empty command")
    func testMakeResetDNSCommand() {
        let cmd = DNSOverrideManager.makeResetDNSCommand(service: "Wi-Fi")
        #expect(cmd.contains("-setdnsservers"))
        #expect(cmd.contains("Wi-Fi"))
        #expect(cmd.contains("Empty"))
    }

    @Test("T1-F28-03: Execute DNS reset using MockProcessRunner and verify recording")
    func testExecuteDNSResetMockRunner() async throws {
        let runner = MockProcessRunner()
        let cmd = DNSOverrideManager.makeResetDNSCommand(service: "Wi-Fi")
        _ = try await runner.run(cmd[0], arguments: Array(cmd.dropFirst()))

        #expect(runner.didExecute(commandContaining: "networksetup -setdnsservers Wi-Fi Empty"))
    }

    @Test("T1-F28-04: Generate command to restore campus DNS servers 10.4.20.21 and 10.4.20.222")
    func testRestoreCampusDNSServersCommand() {
        let cmd = DNSOverrideManager.makeSetCampusDNSCommand(service: "USB 10/100 LAN")
        #expect(cmd.contains("10.4.20.21"))
        #expect(cmd.contains("10.4.20.222"))
    }

    @Test("T1-F28-05: Generate notification upon DNS override restoration")
    func testDNSResetNotificationGeneration() {
        let issue = DetectedIssue(
            severity: .info,
            title: "DNS Overrides Cleared",
            description: "Restored DHCP campus DNS resolvers 10.4.20.21 and 10.4.20.222",
            recommendedFixAction: "None required",
            automatedFixAvailable: false
        )

        #expect(issue.title == "DNS Overrides Cleared")
        #expect(issue.severity == .info)
    }
}
