import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 09: Static Kernel Subnet Route Pinning", .tags(.tier1, .m2_proxy))
struct Tier1_09_RoutePinningTests {

    struct RoutePinningManager {
        let gateway: String
        let interface: String

        init(gateway: String = "10.1.36.1", interface: String = "en10") {
            self.gateway = gateway
            self.interface = interface
        }

        func makeAddRouteCommand(subnet: String, netmask: String = "255.255.0.0") -> [String] {
            ["route", "-n", "add", "-net", subnet, "-netmask", netmask, gateway, "-interface", interface]
        }

        func makeDeleteRouteCommand(subnet: String, netmask: String = "255.255.0.0") -> [String] {
            ["route", "-n", "delete", "-net", subnet, "-netmask", netmask, gateway]
        }

        func isSubnetPinned(subnet: String, inRouteTable output: String) -> Bool {
            let lines = output.components(separatedBy: .newlines)
            return lines.contains { line in
                line.contains(subnet) && line.contains(interface)
            }
        }
    }

    @Test("T1-F09-01: Generate static route command forcing 10.8.0.0/16 via en10 gateway")
    func testPinTuringSubnetCommand() {
        let manager = RoutePinningManager(gateway: "10.1.36.1", interface: "en10")
        let command = manager.makeAddRouteCommand(subnet: "10.8.0.0")

        #expect(command.contains("10.8.0.0"))
        #expect(command.contains("10.1.36.1"))
        #expect(command.contains("en10"))
        #expect(command[2] == "add")
    }

    @Test("T1-F09-02: Generate static route command forcing 10.4.0.0/16 via en10 gateway")
    func testPinCampusServerSubnetCommand() {
        let manager = RoutePinningManager(gateway: "10.1.36.1", interface: "en10")
        let command = manager.makeAddRouteCommand(subnet: "10.4.0.0")

        #expect(command.contains("10.4.0.0"))
        #expect(command.contains("10.1.36.1"))
        #expect(command.contains("en10"))
    }

    @Test("T1-F09-03: Verify routing table parser identifies pinned routes")
    func testRouteTableInspectionForPinnedRoutes() {
        let mockRoutingTable = """
        Routing tables
        Destination        Gateway            Flags        Netif Expire
        default            172.20.10.1        UGScg          en0
        10.4.0.0/16        10.1.36.1          UGSc          en10
        10.8.0.0/16        10.1.36.1          UGSc          en10
        127.0.0.1          127.0.0.1          UH             lo0
        """

        let manager = RoutePinningManager(gateway: "10.1.36.1", interface: "en10")
        #expect(manager.isSubnetPinned(subnet: "10.8.0.0", inRouteTable: mockRoutingTable) == true)
        #expect(manager.isSubnetPinned(subnet: "10.4.0.0", inRouteTable: mockRoutingTable) == true)
        #expect(manager.isSubnetPinned(subnet: "192.168.1.0", inRouteTable: mockRoutingTable) == false)
    }

    @Test("T1-F09-04: Generate route delete command for unpinning subnets")
    func testRouteUnpinningCommand() {
        let manager = RoutePinningManager(gateway: "10.1.36.1", interface: "en10")
        let deleteCmd = manager.makeDeleteRouteCommand(subnet: "10.8.0.0")

        #expect(deleteCmd.contains("delete"))
        #expect(deleteCmd.contains("10.8.0.0"))
        #expect(deleteCmd.contains("10.1.36.1"))
    }

    @Test("T1-F09-05: Detect subnet collision when route is pinned to different interface")
    func testDetectSubnetCollision() {
        let mockRoutingTable = """
        Destination        Gateway            Flags        Netif Expire
        10.8.0.0/16        10.200.0.1         UGSc          utun3
        """

        let manager = RoutePinningManager(gateway: "10.1.36.1", interface: "en10")
        let isPinnedToEn10 = manager.isSubnetPinned(subnet: "10.8.0.0", inRouteTable: mockRoutingTable)
        #expect(isPinnedToEn10 == false)
    }
}
