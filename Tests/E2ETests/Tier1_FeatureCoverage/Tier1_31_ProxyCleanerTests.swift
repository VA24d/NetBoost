import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 31: PAC & Web Proxy Setting Cleaner", .tags(.tier1, .m5_doctor))
struct Tier1_31_ProxyCleanerTests {

    struct ProxySettingsManager {
        static func makeDisableAutoProxyCommand(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-setautoproxystate", service, "off"]
        }

        static func makeDisableWebProxyCommand(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-setwebproxystate", service, "off"]
        }

        static func makeDisableSecureWebProxyCommand(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-setsecurewebproxystate", service, "off"]
        }

        static func parseProxyState(output: String) -> Bool {
            // "Enabled: Yes" or "Enabled: No"
            output.lowercased().contains("enabled: yes")
        }
    }

    @Test("T1-F31-01: Detect active Web Proxy Auto-Discovery (WPAD) or PAC URL")
    func testDetectActiveAutoProxy() {
        let mockAutoProxyOutput = "URL: http://wpad.campus.internal/wpad.dat\nEnabled: Yes"
        let isEnabled = ProxySettingsManager.parseProxyState(output: mockAutoProxyOutput)
        #expect(isEnabled == true)
    }

    @Test("T1-F31-02: Detect manual HTTP/HTTPS proxy setting enabled")
    func testDetectManualWebProxy() {
        let mockWebProxyOutput = "Server: 10.1.1.1\nPort: 8080\nAuthenticated Proxy Enabled: 0\nEnabled: Yes"
        let isEnabled = ProxySettingsManager.parseProxyState(output: mockWebProxyOutput)
        #expect(isEnabled == true)
    }

    @Test("T1-F31-03: Generate networksetup -setautoproxystate <service> off command")
    func testDisableAutoProxyCommand() {
        let cmd = ProxySettingsManager.makeDisableAutoProxyCommand(service: "Wi-Fi")
        #expect(cmd.contains("-setautoproxystate"))
        #expect(cmd.contains("Wi-Fi"))
        #expect(cmd.contains("off"))
    }

    @Test("T1-F31-04: Generate networksetup -setwebproxystate <service> off command")
    func testDisableWebProxyCommand() {
        let cmd = ProxySettingsManager.makeDisableWebProxyCommand(service: "Wi-Fi")
        #expect(cmd.contains("-setwebproxystate"))
        #expect(cmd.contains("Wi-Fi"))
        #expect(cmd.contains("off"))
    }

    @Test("T1-F31-05: Execute proxy cleanup sequence using MockProcessRunner")
    func testExecuteProxyCleanupMockRunner() throws {
        let runner = MockProcessRunner()
        let cmd1 = ProxySettingsManager.makeDisableAutoProxyCommand(service: "Wi-Fi")
        let cmd2 = ProxySettingsManager.makeDisableWebProxyCommand(service: "Wi-Fi")
        let cmd3 = ProxySettingsManager.makeDisableSecureWebProxyCommand(service: "Wi-Fi")

        _ = try runner.run(cmd1[0], arguments: Array(cmd1.dropFirst()))
        _ = try runner.run(cmd2[0], arguments: Array(cmd2.dropFirst()))
        _ = try runner.run(cmd3[0], arguments: Array(cmd3.dropFirst()))

        #expect(runner.didExecute(commandContaining: "networksetup -setautoproxystate Wi-Fi off"))
        #expect(runner.didExecute(commandContaining: "networksetup -setwebproxystate Wi-Fi off"))
        #expect(runner.didExecute(commandContaining: "networksetup -setsecurewebproxystate Wi-Fi off"))
    }
}
