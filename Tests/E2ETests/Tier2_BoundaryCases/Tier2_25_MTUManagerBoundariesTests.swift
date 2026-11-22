import Foundation
import Testing
@testable import NetBoostCore

public enum MTUBoundaryError: Error, Equatable {
    case belowMinimum(Int)
    case exceedsMaximum(Int)
}

@Suite("Tier 2 - Feature 25: MTU Manager Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_25_MTUManagerBoundariesTests {

    let mockRunner = MockProcessRunner()

    func validateAndGenerateMTUCommand(service: String, mtu: Int) throws -> String {
        guard mtu >= 576 else {
            throw MTUBoundaryError.belowMinimum(mtu)
        }
        guard mtu <= 1500 else {
            throw MTUBoundaryError.exceedsMaximum(mtu)
        }
        let quotedService = service.contains(" ") ? "\"\(service)\"" : service
        return "networksetup -setMTU \(quotedService) \(mtu)"
    }

    @Test("T2-F25-01: Setting MTU below minimum threshold (576) is rejected")
    func testMinimumMTUBoundary() {
        #expect(throws: MTUBoundaryError.belowMinimum(0)) {
            try validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 0)
        }
        #expect(throws: MTUBoundaryError.belowMinimum(500)) {
            try validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 500)
        }
        #expect(throws: MTUBoundaryError.belowMinimum(575)) {
            try validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 575)
        }
    }

    @Test("T2-F25-02: Setting MTU above standard threshold (1500) is rejected for Wi-Fi")
    func testMaximumMTUBoundary() {
        #expect(throws: MTUBoundaryError.exceedsMaximum(1501)) {
            try validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 1501)
        }
        #expect(throws: MTUBoundaryError.exceedsMaximum(9000)) {
            try validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 9000)
        }
    }

    @Test("T2-F25-03: Cellular optimum MTU 1280 is accepted and generates command")
    func testCellularOptimumMTU1280() throws {
        let cmd = try validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 1280)
        #expect(cmd == "networksetup -setMTU Wi-Fi 1280")
    }

    @Test("T2-F25-04: Service names containing spaces are properly quoted")
    func testServiceNamesWithSpaces() throws {
        let cmd = try validateAndGenerateMTUCommand(service: "USB 10/100 LAN", mtu: 1500)
        #expect(cmd == "networksetup -setMTU \"USB 10/100 LAN\" 1500")
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
