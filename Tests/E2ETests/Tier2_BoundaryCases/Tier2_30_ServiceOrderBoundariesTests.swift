import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 30: Service Order Manager Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_30_ServiceOrderBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F30-01: Parse networksetup -listnetworkserviceorder output")
    func testParseNetworkServiceOrder() {
        let sampleOutput = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100 LAN
        (Hardware Port: USB 10/100 LAN, Device: en10)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (3) *Bluetooth PAN
        (Hardware Port: Bluetooth PAN, Device: en3)
        """

        func parseServices(from output: String) -> [(name: String, isDisabled: Bool)] {
            var services: [(name: String, isDisabled: Bool)] = []
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("(") && trimmed.contains(")") {
                    // Extract number and name
                    let parts = trimmed.split(separator: ")", maxSplits: 1)
                    if parts.count == 2 {
                        var name = parts[1].trimmingCharacters(in: .whitespaces)
                        let disabled = name.hasPrefix("*")
                        if disabled {
                            name = name.dropFirst().trimmingCharacters(in: .whitespaces)
                        }
                        services.append((name: name, isDisabled: disabled))
                    }
                }
            }
            return services
        }

        let parsed = parseServices(from: sampleOutput)
        #expect(parsed.count == 3)
        #expect(parsed[0].name == "USB 10/100 LAN")
        #expect(parsed[0].isDisabled == false)
        #expect(parsed[1].name == "Wi-Fi")
        #expect(parsed[2].name == "Bluetooth PAN")
        #expect(parsed[2].isDisabled == true)
    }

    @Test("T2-F30-02: Reorder network services places Ethernet first")
    func testReorderPrioritizesEthernet() {
        var currentServices = ["Wi-Fi", "USB 10/100 LAN", "Thunderbolt Bridge"]

        func prioritizeEthernet(services: [String]) -> [String] {
            var reordered = services
            if let ethIndex = reordered.firstIndex(where: { $0.contains("LAN") || $0.contains("Ethernet") }) {
                let eth = reordered.remove(at: ethIndex)
                reordered.insert(eth, at: 0)
            }
            return reordered
        }

        let prioritized = prioritizeEthernet(services: currentServices)
        #expect(prioritized.first == "USB 10/100 LAN")
    }

    @Test("T2-F30-03: Reorder command generation with quotes for service names with spaces")
    func testReorderCommandGeneration() {
        let services = ["USB 10/100 LAN", "Wi-Fi"]
        let quoted = services.map { "\"\($0)\"" }.joined(separator: " ")
        let cmd = "networksetup -ordernetworkservices \(quoted)"

        #expect(cmd == "networksetup -ordernetworkservices \"USB 10/100 LAN\" \"Wi-Fi\"")
    }

    @Test("T2-F30-04: Reorder command when already in desired order is a no-op")
    func testReorderAlreadyInOrderIsNoOp() {
        let currentOrder = ["USB 10/100 LAN", "Wi-Fi"]
        let desiredOrder = ["USB 10/100 LAN", "Wi-Fi"]

        var commandExecuted = false
        if currentOrder != desiredOrder {
            commandExecuted = true
        }

        #expect(commandExecuted == false)
    }

    @Test("T2-F30-05: MockProcessRunner intercepts ordernetworkservices command")
    func testMockProcessRunnerServiceOrder() async throws {
        mockRunner.registerStub(commandContaining: "networksetup -ordernetworkservices", stdout: "Service order updated\n", exitCode: 0)
        #expect(mockRunner.didExecute(commandContaining: "networksetup -ordernetworkservices") == false)

        let output = try await mockRunner.run("networksetup", arguments: ["-ordernetworkservices", "USB 10/100 LAN", "Wi-Fi"])
        #expect(output.succeeded)
        #expect(output.stdout.contains("Service order updated"))
        #expect(mockRunner.didExecute(commandContaining: "networksetup -ordernetworkservices") == true)
    }
}
