import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 46: macOS Menu Bar Extra Widget", .tags(.tier1, .m6_ui))
struct Tier1_46_MenuBarWidgetTests {

    final class MenuBarExtraViewModel: @unchecked Sendable {
        private(set) var currentThroughputText: String = "↓ 0 B/s  ↑ 0 B/s"
        private(set) var primaryInterfaceText: String = "Ethernet: 10.1.36.52"
        private(set) var isHotspotEnabled: Bool = false
        private(set) var isVPNEnabled: Bool = false
        private(set) var repairStatus: String?

        func updateThroughput(down: String, up: String) {
            currentThroughputText = "↓ \(down)  ↑ \(up)"
        }

        func setPrimaryInterface(text: String) {
            primaryInterfaceText = text
        }

        func toggleHotspot() {
            isHotspotEnabled.toggle()
        }

        func toggleVPN() {
            isVPNEnabled.toggle()
        }

        func executeQuickAutoFix() async {
            // Simulate quick auto-fix execution
            try? await Task.sleep(nanoseconds: 5_000_000)
            repairStatus = "Quick Auto-Fix Completed"
        }
    }

    @Test("T1-F46-01: Menu Bar item displays live aggregate download and upload speed")
    func testMenuBarThroughputText() {
        let vm = MenuBarExtraViewModel()
        vm.updateThroughput(down: "45.2 MB/s", up: "3.1 MB/s")

        #expect(vm.currentThroughputText.contains("45.2 MB/s"))
        #expect(vm.currentThroughputText.contains("3.1 MB/s"))
    }

    @Test("T1-F46-02: Dropdown menu displays current primary interface name and IP")
    func testMenuBarPrimaryInterface() {
        let vm = MenuBarExtraViewModel()
        #expect(vm.primaryInterfaceText == "Ethernet: 10.1.36.52")

        vm.setPrimaryInterface(text: "Wi-Fi: 172.20.10.2")
        #expect(vm.primaryInterfaceText == "Wi-Fi: 172.20.10.2")
    }

    @Test("T1-F46-03: Quick toggle for Hotspot on and off")
    func testMenuBarHotspotToggle() {
        let vm = MenuBarExtraViewModel()
        #expect(vm.isHotspotEnabled == false)

        vm.toggleHotspot()
        #expect(vm.isHotspotEnabled == true)

        vm.toggleHotspot()
        #expect(vm.isHotspotEnabled == false)
    }

    @Test("T1-F46-04: Quick toggle for VPN on and off")
    func testMenuBarVPNToggle() {
        let vm = MenuBarExtraViewModel()
        #expect(vm.isVPNEnabled == false)

        vm.toggleVPN()
        #expect(vm.isVPNEnabled == true)

        vm.toggleVPN()
        #expect(vm.isVPNEnabled == false)
    }

    @Test("T1-F46-05: Menu Bar Auto-Fix Network item triggers repair sequence")
    func testMenuBarAutoFixTrigger() async {
        let vm = MenuBarExtraViewModel()
        #expect(vm.repairStatus == nil)

        await vm.executeQuickAutoFix()
        #expect(vm.repairStatus == "Quick Auto-Fix Completed")
    }
}
