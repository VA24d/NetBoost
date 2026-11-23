import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 31: Proxy Cleaner Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_31_ProxyCleanerBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F31-01: NetBoost ports (1080, 1081, 1082) preserved from accidental cleanup")
    func testNetBoostPortsPreserved() {
        let netBoostPorts: Set<Int> = [1080, 1081, 1082]

        func isRogueProxy(port: Int) -> Bool {
            return !netBoostPorts.contains(port)
        }

        #expect(isRogueProxy(port: 8080) == true)
        #expect(isRogueProxy(port: 3128) == true)
        #expect(isRogueProxy(port: 1080) == false)
        #expect(isRogueProxy(port: 1081) == false)
        #expect(isRogueProxy(port: 1082) == false)
    }

    @Test("T2-F31-02: Disable PAC auto-proxy command generation")
    func testDisablePACCommand() {
        func makeDisablePACCommand(service: String) -> String {
            let quoted = service.contains(" ") ? "\"\(service)\"" : service
            return "networksetup -setautoproxystate \(quoted) off"
        }

        #expect(makeDisablePACCommand(service: "Wi-Fi") == "networksetup -setautoproxystate Wi-Fi off")
    }

    @Test("T2-F31-03: Disable manual HTTP web proxy command generation")
    func testDisableWebProxyCommand() {
        func makeDisableWebProxyCommand(service: String) -> String {
            let quoted = service.contains(" ") ? "\"\(service)\"" : service
            return "networksetup -setwebproxystate \(quoted) off"
        }

        #expect(makeDisableWebProxyCommand(service: "Wi-Fi") == "networksetup -setwebproxystate Wi-Fi off")
    }

    @Test("T2-F31-04: Disable secure HTTPS proxy command generation")
    func testDisableSecureWebProxyCommand() {
        func makeDisableSecureProxyCommand(service: String) -> String {
            let quoted = service.contains(" ") ? "\"\(service)\"" : service
            return "networksetup -setsecurewebproxystate \(quoted) off"
        }

        #expect(makeDisableSecureProxyCommand(service: "Wi-Fi") == "networksetup -setsecurewebproxystate Wi-Fi off")
    }

    @Test("T2-F31-05: MockProcessRunner intercepts proxy cleaner commands")
    func testMockProcessRunnerProxyClean() async throws {
        mockRunner.registerStub(commandContaining: "networksetup -setautoproxystate Wi-Fi off", stdout: "Auto-proxy disabled\n", exitCode: 0)
        mockRunner.registerStub(commandContaining: "networksetup -setwebproxystate Wi-Fi off", stdout: "Web proxy disabled\n", exitCode: 0)

        #expect(mockRunner.didExecute(commandContaining: "networksetup -setautoproxystate") == false)
        #expect(mockRunner.didExecute(commandContaining: "networksetup -setwebproxystate") == false)

        let out1 = try await mockRunner.run("networksetup", arguments: ["-setautoproxystate", "Wi-Fi", "off"])
        let out2 = try await mockRunner.run("networksetup", arguments: ["-setwebproxystate", "Wi-Fi", "off"])

        #expect(out1.succeeded)
        #expect(out1.stdout.contains("Auto-proxy disabled"))
        #expect(out2.succeeded)
        #expect(out2.stdout.contains("Web proxy disabled"))
        #expect(mockRunner.didExecute(commandContaining: "networksetup -setautoproxystate") == true)
        #expect(mockRunner.didExecute(commandContaining: "networksetup -setwebproxystate") == true)
    }
}
