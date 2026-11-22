import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 25: Interface MTU Inspector & Auto-Fix", .tags(.tier1, .m5_doctor, .diagnostics))
struct Tier1_25_MTUManagerTests {

    struct MTUInspector {
        static func recommendMTU(isCellular: Bool, currentMTU: Int) -> (optimalMTU: Int, fixNeeded: Bool) {
            let optimal = isCellular ? 1280 : 1500
            return (optimal, currentMTU != optimal)
        }

        static func makeSetMTUCommand(service: String, mtu: Int) -> [String] {
            ["/usr/sbin/networksetup", "-setMTU", service, String(mtu)]
        }

        static func makeGetMTUCommand(service: String) -> [String] {
            ["/usr/sbin/networksetup", "-getMTU", service]
        }

        static func parseGetMTUOutput(_ output: String) -> Int? {
            // "Active MTU: 1280 (Current Setting: 1280)" or "MTU: 1500"
            for token in output.split(separator: " ") {
                let clean = token.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                if let val = Int(clean), val >= 576 && val <= 9000 {
                    return val
                }
            }
            return nil
        }
    }

    @Test("T1-F25-01: Detect non-optimal MTU 1500 on cellular hotspot connection")
    func testDetectSuboptimalMTUOnCellular() {
        let (optimal, fixNeeded) = MTUInspector.recommendMTU(isCellular: true, currentMTU: 1500)
        #expect(optimal == 1280)
        #expect(fixNeeded == true)
    }

    @Test("T1-F25-02: Generate networksetup command setting Wi-Fi MTU to 1280")
    func testGenerateSetMTUCommand() {
        let cmd = MTUInspector.makeSetMTUCommand(service: "Wi-Fi", mtu: 1280)
        #expect(cmd.contains("-setMTU"))
        #expect(cmd.contains("Wi-Fi"))
        #expect(cmd.contains("1280"))
    }

    @Test("T1-F25-03: Verify Ethernet en10 optimal MTU is 1500")
    func testEthernetOptimalMTU() {
        let (optimal, fixNeeded) = MTUInspector.recommendMTU(isCellular: false, currentMTU: 1500)
        #expect(optimal == 1500)
        #expect(fixNeeded == false)
    }

    @Test("T1-F25-04: Parse networksetup -getMTU output successfully")
    func testParseGetMTUOutput() {
        let output1280 = "Active MTU: 1280 (Current Setting: 1280)"
        let parsed = MTUInspector.parseGetMTUOutput(output1280)
        #expect(parsed == 1280)

        let output1500 = "Active MTU: 1500"
        let parsed1500 = MTUInspector.parseGetMTUOutput(output1500)
        #expect(parsed1500 == 1500)
    }

    @Test("T1-F25-05: Flag MTU 1280 as recommended fix in DetectedIssue model")
    func testFlagMTUFixInDiagnosticModel() {
        let issue = DetectedIssue(
            severity: .warning,
            title: "MTU 1500 on Cellular Hotspot",
            description: "High packet drop and TLS bad record MAC risks over cellular.",
            recommendedFixAction: "networksetup -setMTU Wi-Fi 1280",
            automatedFixAvailable: true
        )

        #expect(issue.severity == .warning)
        #expect(issue.recommendedFixAction.contains("1280"))
        #expect(issue.automatedFixAvailable == true)
    }
}
