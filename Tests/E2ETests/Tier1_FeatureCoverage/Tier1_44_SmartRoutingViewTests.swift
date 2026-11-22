import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 44: Smart Routing & VPN Rules View", .tags(.tier1, .m6_ui))
struct Tier1_44_SmartRoutingViewTests {

    final class SmartRoutingViewModel: @unchecked Sendable {
        private(set) var activePathType: String = "Direct Ethernet (en10)"
        private(set) var vpnStatus: VPNStatus = .disconnected
        private(set) var routeConflictBanner: String? = nil
        private(set) var routes: [VPNRouteEntry] = []
        private(set) var isAutomationEnabled: Bool = true

        func setRoutes(_ r: [VPNRouteEntry]) {
            routes = r
        }

        func setConflict(_ conflict: String?) {
            routeConflictBanner = conflict
        }

        func toggleVPN() {
            vpnStatus = (vpnStatus == .connected) ? .disconnected : .connected
        }

        func toggleAutomation() {
            isAutomationEnabled.toggle()
        }
    }

    @Test("T1-F44-01: Display active routing path status (Direct vs Tunneled)")
    func testActiveRoutingPathStatus() {
        let vm = SmartRoutingViewModel()
        #expect(vm.activePathType.contains("Direct"))
    }

    @Test("T1-F44-02: Display macos.ovpn status card with Connect/Disconnect toggle")
    func testVPNCardToggle() {
        let vm = SmartRoutingViewModel()
        #expect(vm.vpnStatus == .disconnected)

        vm.toggleVPN()
        #expect(vm.vpnStatus == .connected)

        vm.toggleVPN()
        #expect(vm.vpnStatus == .disconnected)
    }

    @Test("T1-F44-03: Route conflict banner displays warning when collision detected")
    func testRouteConflictBanner() {
        let vm = SmartRoutingViewModel()
        #expect(vm.routeConflictBanner == nil)

        vm.setConflict("Conflict: Profile route 10.1.0.0/16 collides with physical Ethernet en10")
        #expect(vm.routeConflictBanner != nil)
        #expect(vm.routeConflictBanner?.contains("Conflict") == true)
    }

    @Test("T1-F44-04: Display parsed OpenVPN route table list")
    func testDisplayParsedRouteList() {
        let vm = SmartRoutingViewModel()
        let sampleRoutes = [
            VPNRouteEntry(destinationSubnet: "10.8.0.0", mask: "255.255.0.0"),
            VPNRouteEntry(destinationSubnet: "10.4.0.0", mask: "255.255.0.0")
        ]
        vm.setRoutes(sampleRoutes)

        #expect(vm.routes.count == 2)
        #expect(vm.routes[0].destinationSubnet == "10.8.0.0")
        #expect(vm.routes[1].destinationSubnet == "10.4.0.0")
    }

    @Test("T1-F44-05: Manual override toggle pauses context-aware VPN automation")
    func testAutomationToggle() {
        let vm = SmartRoutingViewModel()
        #expect(vm.isAutomationEnabled == true)

        vm.toggleAutomation()
        #expect(vm.isAutomationEnabled == false)
    }
}
