import Foundation
import Testing
@testable import NetBoostCore

@Suite("Route Pinning Unit & Integration Tests")
struct RoutePinningTests {

    @Test("CIDR subnet notation validation")
    func testCIDRValidation() {
        #expect(RoutePinningEngine.validateCIDR("10.8.0.0/16") == true)
        #expect(RoutePinningEngine.validateCIDR("10.4.0.0/16") == true)
        #expect(RoutePinningEngine.validateCIDR("192.168.1.0/24") == true)
        #expect(RoutePinningEngine.validateCIDR("10.0.0.0/8") == true)
        #expect(RoutePinningEngine.validateCIDR("0.0.0.0/0") == true)

        // Invalid CIDR formats
        #expect(RoutePinningEngine.validateCIDR("10.8.0.0/35") == false) // prefix > 32
        #expect(RoutePinningEngine.validateCIDR("10.8.0/16") == false)    // only 3 octets
        #expect(RoutePinningEngine.validateCIDR("999.0.0.0/16") == false) // octet > 255
        #expect(RoutePinningEngine.validateCIDR("-1.0.0.0/16") == false)
        #expect(RoutePinningEngine.validateCIDR("random_text") == false)
        #expect(RoutePinningEngine.validateCIDR("10.8.0.0") == false)      // missing prefix
    }

    @Test("CIDR prefix to dotted-decimal netmask conversion")
    func testCIDRToNetmask() {
        #expect(RoutePinningEngine.cidrToNetmask(prefix: 16) == "255.255.0.0")
        #expect(RoutePinningEngine.cidrToNetmask(prefix: 24) == "255.255.255.0")
        #expect(RoutePinningEngine.cidrToNetmask(prefix: 8) == "255.0.0.0")
        #expect(RoutePinningEngine.cidrToNetmask(prefix: 32) == "255.255.255.255")
        #expect(RoutePinningEngine.cidrToNetmask(prefix: 0) == "0.0.0.0")
    }

    @Test("Add route command generation matches system route CLI syntax")
    func testAddRouteCommandGeneration() {
        let engine = RoutePinningEngine(gateway: "10.1.36.1", interface: "en10")
        let cmd = engine.makeAddRouteCommand(subnet: "10.8.0.0", netmask: "255.255.0.0")

        #expect(cmd == ["route", "-n", "add", "-net", "10.8.0.0", "-netmask", "255.255.0.0", "10.1.36.1", "-interface", "en10"])
    }

    @Test("Delete route command generation")
    func testDeleteRouteCommandGeneration() {
        let engine = RoutePinningEngine(gateway: "10.1.36.1", interface: "en10")
        let cmd = engine.makeDeleteRouteCommand(subnet: "10.8.0.0", netmask: "255.255.0.0")

        #expect(cmd == ["route", "-n", "delete", "-net", "10.8.0.0", "-netmask", "255.255.0.0", "10.1.36.1"])
    }

    @Test("Manual unprivileged command fallback formatting")
    func testManualCommandFormatting() {
        let engine = RoutePinningEngine(gateway: "10.1.36.1", interface: "en10")
        let addManual = engine.manualAddCommand(subnet: "10.8.0.0/16")
        #expect(addManual == "sudo /sbin/route -n add -net 10.8.0.0/16 10.1.36.1 -ifp en10")

        let delManual = engine.manualDeleteCommand(subnet: "10.8.0.0/16")
        #expect(delManual == "sudo /sbin/route -n delete -net 10.8.0.0/16 10.1.36.1")
    }

    @Test("Routing table output parser extracts active pinned routes")
    func testParseRoutingTable() {
        let engine = RoutePinningEngine()
        let sampleOutput = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            10.1.36.1          UGScg                en10       
        10.1.36/22         link#32            UCS                  en10      !
        10.4.0.0/16        10.1.36.1          UGSc                 en10       
        10.8.0.0/16        10.1.36.1          UGSc                 en10       
        127.0.0.1          127.0.0.1          UH                    lo0       
        """

        let routes = engine.parseRoutingTable(output: sampleOutput)
        let turingRoute = routes.first { $0.subnet == "10.8.0.0/16" }
        let campusRoute = routes.first { $0.subnet == "10.4.0.0/16" }

        #expect(turingRoute != nil)
        #expect(turingRoute?.gateway == "10.1.36.1")
        #expect(turingRoute?.interface == "en10")
        #expect(turingRoute?.netmask == "255.255.0.0")
        #expect(turingRoute?.isActive == true)

        #expect(campusRoute != nil)
        #expect(campusRoute?.gateway == "10.1.36.1")
        #expect(campusRoute?.interface == "en10")
    }

    @Test("Route table subnet presence check helper")
    func testIsSubnetPinnedHelper() {
        let engine = RoutePinningEngine(gateway: "10.1.36.1", interface: "en10")
        let sampleOutput = "10.8.0.0/16 10.1.36.1 UGSc en10\n"
        #expect(engine.isSubnetPinned(subnet: "10.8.0.0", inRouteTable: sampleOutput) == true)
        #expect(engine.isSubnetPinned(subnet: "10.99.0.0", inRouteTable: sampleOutput) == false)
    }

    @Test("Live kernel routing table query succeeds without error")
    func testLiveRoutingTableQuery() async throws {
        let engine = RoutePinningEngine()
        let routes = try await engine.currentPinnedRoutes()
        // Every macOS machine has active routing entries (at least default or loopback)
        #expect(!routes.isEmpty)
    }
}
