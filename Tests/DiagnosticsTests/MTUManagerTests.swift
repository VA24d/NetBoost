import Testing
import Foundation
@testable import NetBoostCore

@Suite("Campus Diagnostics: MTUManager Unit & Integration Tests")
struct MTUManagerTests {

    @Test("Recommend MTU 1280 for cellular connection and 1500 for ethernet")
    func testRecommendMTU() {
        let manager = MTUManager()

        let (cellOptimal, cellFixNeeded) = manager.recommendMTU(isCellular: true, currentMTU: 1500)
        #expect(cellOptimal == 1280)
        #expect(cellFixNeeded == true)

        let (ethOptimal, ethFixNeeded) = manager.recommendMTU(isCellular: false, currentMTU: 1500)
        #expect(ethOptimal == 1500)
        #expect(ethFixNeeded == false)
    }

    @Test("Validate MTU bounds enforces minimum 576 and maximum 1500")
    func testValidateMTUBounds() {
        // Below minimum
        #expect(throws: NetBoostCore.MTUBoundaryError.belowMinimum(500)) {
            try MTUManager.validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 500)
        }
        #expect(throws: NetBoostCore.MTUBoundaryError.belowMinimum(0)) {
            try MTUManager.validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 0)
        }

        // Above maximum
        #expect(throws: NetBoostCore.MTUBoundaryError.exceedsMaximum(1501)) {
            try MTUManager.validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 1501)
        }
        #expect(throws: NetBoostCore.MTUBoundaryError.exceedsMaximum(9000)) {
            try MTUManager.validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 9000)
        }

        // Valid
        #expect(throws: Never.self) {
            let cmd1280 = try MTUManager.validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 1280)
            #expect(cmd1280 == "networksetup -setMTU Wi-Fi 1280")

            let cmd1500 = try MTUManager.validateAndGenerateMTUCommand(service: "Wi-Fi", mtu: 1500)
            #expect(cmd1500 == "networksetup -setMTU Wi-Fi 1500")
        }
    }

    @Test("Properly quotes service names containing whitespace")
    func testQuotesServiceNamesWithWhitespace() throws {
        let cmd = try MTUManager.validateAndGenerateMTUCommand(service: "USB 10/100 LAN", mtu: 1500)
        #expect(cmd == "networksetup -setMTU \"USB 10/100 LAN\" 1500")
    }

    @Test("Parse various networksetup -getMTU output formats")
    func testParseGetMTUOutput() {
        #expect(MTUInspector.parseGetMTUOutput("Active MTU: 1280 (Current Setting: 1280)") == 1280)
        #expect(MTUInspector.parseGetMTUOutput("Active MTU: 1500") == 1500)
        #expect(MTUInspector.parseGetMTUOutput("MTU: 1492") == 1492)
        #expect(MTUInspector.parseGetMTUOutput("Invalid text output") == nil)
    }

    @Test("Detect suboptimal MTU on cellular interface generates warning issue")
    func testDetectSuboptimalMTUOnCellular() {
        let manager = MTUManager()
        let wifiCellular = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2")],
            mtu: 1500
        )

        let issue = manager.detectSuboptimalMTU(interface: wifiCellular, isCellular: true)
        #expect(issue != nil)
        #expect(issue?.severity == .warning)
        #expect(issue?.recommendedFixAction.contains("1280") == true)
        #expect(issue?.automatedFixAvailable == true)

        // Wi-Fi already at 1280
        let wifiFixed = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2")],
            mtu: 1280
        )
        #expect(manager.detectSuboptimalMTU(interface: wifiFixed, isCellular: true) == nil)
    }
}
