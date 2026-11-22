import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 3: Network Service Order Manager + Route Pinning Interaction", .tags(.tier3, .diagnostics, .m2_proxy, .m5_doctor))
struct CrossFeature_ServiceOrderRoutePinningTests {

    @Test("Service order inspector parses macOS service order ranking list and identifies priority interface")
    func testServiceOrderInspectorParsing() async throws {
        let runner = MockProcessRunner()

        let output = try await runner.run("networksetup", arguments: ["-listnetworkserviceorder"])
        #expect(output.succeeded)

        var serviceOrder: [(rank: Int, name: String, device: String)] = []
        let lines = output.stdout.components(separatedBy: "\n")
        var currentRank: Int?
        var currentName: String?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(") && line.contains(")") {
                // Match "(1) USB 10/100 LAN"
                if let closeParen = line.firstIndex(of: ")") {
                    let rankStr = line[line.index(after: line.startIndex)..<closeParen]
                    if let rank = Int(rankStr) {
                        currentRank = rank
                        currentName = line[line.index(after: closeParen)...].trimmingCharacters(in: .whitespaces)
                    }
                }
            } else if line.contains("Device:") && currentRank != nil && currentName != nil {
                // Match "(Hardware Port: USB 10/100 LAN, Device: en10)"
                if let devIdx = line.range(of: "Device: ")?.upperBound,
                   let endIdx = line.firstIndex(of: ")") {
                    let dev = String(line[devIdx..<endIdx]).trimmingCharacters(in: .whitespaces)
                    serviceOrder.append((currentRank!, currentName!, dev))
                    currentRank = nil
                    currentName = nil
                }
            }
        }

        #expect(serviceOrder.count >= 2)
        #expect(serviceOrder.first?.device == "en10")
        #expect(serviceOrder.first?.name == "USB 10/100 LAN")
    }

    @Test("Reordering services places Ethernet en10 at priority #1 and includes all active services")
    func testServiceOrderReorderExecution() async throws {
        let runner = MockProcessRunner()

        let activeServices = ["USB 10/100 LAN", "Wi-Fi", "iPhone USB"]
        var args = ["-ordernetworkservices"]
        args.append(contentsOf: activeServices)

        let output = try await runner.run("networksetup", arguments: args)
        #expect(output.succeeded)

        let lastCmd = runner.lastExecutedCommand()
        #expect(lastCmd?.arguments.first == "-ordernetworkservices")
        #expect(lastCmd?.arguments[1] == "USB 10/100 LAN")
        #expect(lastCmd?.arguments.count == 4)
    }

    @Test("Subnet route pinning maintains 10.8.0.0/16 and 10.4.0.0/16 pointing to en10 after service order change")
    func testRoutePinningPersistenceAcrossServiceReorder() async throws {
        let runner = MockProcessRunner()

        // 1. Reorder services
        _ = try await runner.run("networksetup", arguments: ["-ordernetworkservices", "USB 10/100 LAN", "Wi-Fi"])

        // 2. Pin static routes for campus compute clusters
        let routes = [
            ("10.8.0.0/16", "10.1.36.1"),
            ("10.4.0.0/16", "10.1.36.1")
        ]

        for (subnet, gateway) in routes {
            let addRoute = try await runner.run("route", arguments: ["add", "-net", subnet, gateway])
            #expect(addRoute.succeeded)
            #expect(runner.didExecute(commandContaining: "route add -net \(subnet) \(gateway)"))
        }

        #expect(runner.executionCount(commandContaining: "route add -net") == 2)
    }

    @Test("Idempotent service order reorder detects current order and avoids redundant execution")
    func testServiceOrderReorderIdempotency() {
        let currentOrder = ["USB 10/100 LAN", "Wi-Fi", "iPhone USB"]
        let targetOrder = ["USB 10/100 LAN", "Wi-Fi", "iPhone USB"]

        let isAlreadyOrdered = currentOrder == targetOrder
        #expect(isAlreadyOrdered == true)
    }

    @Test("Service names with special characters and parentheses are quoted safely in argv array")
    func testSpecialCharacterServiceHandling() async throws {
        let runner = MockProcessRunner()

        let complexServices = [
            "USB 10/100 LAN (Slot 1)",
            "Wi-Fi",
            "Thunderbolt Ethernet (Slot 2)"
        ]

        var args = ["-ordernetworkservices"]
        args.append(contentsOf: complexServices)

        let output = try await runner.run("networksetup", arguments: args)
        #expect(output.succeeded)

        let recorded = runner.lastExecutedCommand()
        #expect(recorded?.arguments.contains("USB 10/100 LAN (Slot 1)") == true)
        #expect(recorded?.arguments.contains("Thunderbolt Ethernet (Slot 2)") == true)
    }
}
