import Testing
import Foundation
@testable import NetBoostCore

@Suite("Campus Diagnostics: ServiceOrderManager Unit & Integration Tests")
struct ServiceOrderManagerTests {

    @Test("Parse networksetup -listnetworkserviceorder output format accurately")
    func testParseServiceOrder() {
        let mockOutput = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100 LAN
        (Hardware Port: USB 10/100 LAN, Device: en10)
        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (3) iPhone USB
        (Hardware Port: iPhone USB, Device: en9)
        """

        let entries = ServiceOrderManager.parseServiceOrder(output: mockOutput)
        #expect(entries.count == 3)
        #expect(entries[0].order == 1)
        #expect(entries[0].name == "USB 10/100 LAN")
        #expect(entries[0].device == "en10")

        #expect(entries[1].order == 2)
        #expect(entries[1].name == "Wi-Fi")
        #expect(entries[1].device == "en0")

        #expect(entries[2].order == 3)
        #expect(entries[2].name == "iPhone USB")
        #expect(entries[2].device == "en9")
    }

    @Test("Generate networksetup -ordernetworkservices command with ordered parameters")
    func testMakeOrderCommand() {
        let services = ["USB 10/100 LAN", "Wi-Fi", "iPhone USB"]
        let cmd = ServiceOrderManager.makeOrderNetworkServicesCommand(orderedServices: services)

        #expect(cmd.count == 5)
        #expect(cmd[0] == "/usr/sbin/networksetup")
        #expect(cmd[1] == "-ordernetworkservices")
        #expect(cmd[2] == "USB 10/100 LAN")
        #expect(cmd[3] == "Wi-Fi")
        #expect(cmd[4] == "iPhone USB")
    }

    @Test("Prioritize Ethernet over Wi-Fi reorders services correctly")
    func testPrioritizeEthernet() {
        let manager = ServiceOrderManager()
        let initial = ["Wi-Fi", "iPhone USB", "USB 10/100 LAN", "Thunderbolt Bridge"]
        let prioritized = manager.prioritizeEthernet(services: initial)

        #expect(prioritized.first == "USB 10/100 LAN")
        #expect(prioritized[1] == "Wi-Fi")
    }

    @Test("Handles empty input without crashing")
    func testEmptyServiceOrder() {
        let entries = ServiceOrderManager.parseServiceOrder(output: "")
        #expect(entries.isEmpty)
    }
}
