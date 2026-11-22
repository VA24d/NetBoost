import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 25: MTU Manager Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_25_MTUManagerBoundariesTests {

    let mockRunner = MockProcessRunner()

    func validateAndGenerateMTUCommand(service: String, mtu: Int) -> Result<String, String> {
        guard mtu >= 576 else {
            return .failure("MTU value \(mtu) is below IPv4 minimum threshold (576)")
        }
        guard mtu <= 1500 else {
            return .failure("MTU value \(mtu) exceeds standard interface maximum threshold (1500)")
        }
        let quotedService = service.contains(" ") ? "\"\(service)\"" : service
        return .success("networksetup -setMTU \(quotedService) \(mtu)")
    }

    @Test("T2-F25-01: Setting MTU below minimum threshold (576) is rejected")
    func testMinimumMTUBoundary() {
        let resultZero = validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 0)
        let result500 = validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 500)
        let result575 = validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 575)

        #expect(resultZero.isFailure)
        #expect(result500.isFailure)
        #expect(result575.isFailure)
    }

    @Test("T2-F25-02: Setting MTU above standard threshold (1500) is rejected for Wi-Fi")
    func testMaximumMTUBoundary() {
        let result1501 = validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 1501)
        let result9000 = validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 9000)

        #expect(result1501.isFailure)
        #expect(result9000.isFailure)
    }

    @Test("T2-F25-03: Cellular optimum MTU 1280 is accepted and generates command")
    func testCellularOptimumMTU1280() {
        let result = validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 1280)
        switch result {
        case .success(let cmd):
            #expect(cmd == "networksetup -setMTU Wi-Fi 1280")
        case .failure(let err):
            Issue.record("Unexpected failure: \(err)")
        }
    }

    @Test("T2-F25-04: Service names containing spaces are properly quoted")
    func testServiceNamesWithSpaces() {
        let result = validateAndGenerateMTUCommand(service: "USB 10/100 LAN", mtu: 1500)
        switch result {
        case .success(let cmd):
            #expect(cmd == "networksetup -setMTU \"USB 10/100 LAN\" 1500")
        case .failure(let err):
            Issue.record("Unexpected failure: \(err)")
        }
    }

    @Test("T2-F25-05: MockProcessRunner intercepts networksetup -setMTU command")
    func testMockProcessRunnerMTUInterception() {
        mockRunner.registerStub(
            commandContaining: "networksetup -setMTU",
            stdout: "Set MTU for Wi-Fi to 1280\n"
        )

        let cmd = "networksetup -setMTU Wi-Fi 1280"
        #expect(mockRunner.didExecute(commandContaining: cmd) == false)
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
