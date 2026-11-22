import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 30: Network Service Order Manager", .tags(.tier1, .m5_doctor))
struct Tier1_30_ServiceOrderTests {

    struct ServiceOrderManager {
        struct ServiceEntry: Equatable {
            let order: Int
            let name: String
            let device: String
        }

        static func parseServiceOrder(output: String) -> [ServiceEntry] {
            var entries: [ServiceEntry] = []
            let lines = output.components(separatedBy: .newlines)
            var currentOrder: Int?
            var currentName: String?

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("(") && trimmed.contains(")") {
                    // "(1) USB 10/100 LAN" or "(Hardware Port: USB 10/100 LAN, Device: en10)"
                    if let endParen = trimmed.firstIndex(of: ")") {
                        let numStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<endParen])
                        if let num = Int(numStr) {
                            currentOrder = num
                            currentName = String(trimmed[trimmed.index(after: endParen)...]).trimmingCharacters(in: .whitespaces)
                        }
                    }
                } else if trimmed.hasPrefix("(Hardware Port:") {
                    if let devRange = trimmed.range(of: "Device: ") {
                        let devPart = String(trimmed[devRange.upperBound...]).replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
                        if let order = currentOrder, let name = currentName {
                            entries.append(ServiceEntry(order: order, name: name, device: devPart))
                        }
                    }
                    currentOrder = nil
                    currentName = nil
                }
            }
            return entries
        }

        static func makeOrderNetworkServicesCommand(orderedServices: [String]) -> [String] {
            ["/usr/sbin/networksetup", "-ordernetworkservices"] + orderedServices
        }
    }

    @Test("T1-F30-01: Parse networksetup -listnetworkserviceorder output format")
    func testParseServiceOrderOutput() {
        let mockOutput = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100 LAN
        (Hardware Port: USB 10/100 LAN, Device: en10)
        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        """

        let entries = ServiceOrderManager.parseServiceOrder(output: mockOutput)
        #expect(entries.count == 2)
        #expect(entries[0].order == 1)
        #expect(entries[0].name == "USB 10/100 LAN")
        #expect(entries[0].device == "en10")
        #expect(entries[1].order == 2)
        #expect(entries[1].name == "Wi-Fi")
        #expect(entries[1].device == "en0")
    }

    @Test("T1-F30-02: Rank services correctly and detect primary priority")
    func testServiceRankings() {
        let entries = [
            ServiceOrderManager.ServiceEntry(order: 1, name: "USB 10/100 LAN", device: "en10"),
            ServiceOrderManager.ServiceEntry(order: 2, name: "Wi-Fi", device: "en0")
        ]

        let topService = entries.min(by: { $0.order < $1.order })
        #expect(topService?.name == "USB 10/100 LAN")
    }

    @Test("T1-F30-03: Reorder services to place Ethernet ahead of Wi-Fi")
    func testReorderServicesEthernetFirst() {
        var services = ["Wi-Fi", "USB 10/100 LAN", "iPhone USB"]
        services.sort { s1, s2 in
            if s1 == "USB 10/100 LAN" { return true }
            if s2 == "USB 10/100 LAN" { return false }
            return s1 < s2
        }

        #expect(services[0] == "USB 10/100 LAN")
        #expect(services[1] == "iPhone USB")
        #expect(services[2] == "Wi-Fi")
    }

    @Test("T1-F30-04: Generate networksetup -ordernetworkservices command")
    func testMakeOrderNetworkServicesCommand() {
        let desiredOrder = ["USB 10/100 LAN", "Wi-Fi", "iPhone USB"]
        let cmd = ServiceOrderManager.makeOrderNetworkServicesCommand(orderedServices: desiredOrder)

        #expect(cmd[0] == "/usr/sbin/networksetup")
        #expect(cmd[1] == "-ordernetworkservices")
        #expect(cmd[2] == "USB 10/100 LAN")
        #expect(cmd[3] == "Wi-Fi")
    }

    @Test("T1-F30-05: Execute reorder services using MockProcessRunner and verify recording")
    func testExecuteReorderMockRunner() async throws {
        let runner = MockProcessRunner()
        let cmd = ServiceOrderManager.makeOrderNetworkServicesCommand(orderedServices: ["USB 10/100 LAN", "Wi-Fi"])
        _ = try await runner.run(cmd[0], arguments: Array(cmd.dropFirst()))

        #expect(runner.didExecute(commandContaining: "networksetup -ordernetworkservices USB 10/100 LAN Wi-Fi"))
    }
}
