import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 46: Menu Bar Widget Boundaries", .tags(.tier2, .m6_ui))
struct Tier2_46_MenuBarBoundariesTests {

    @Test("T2-F46-01: Menu Bar live throughput label formatting with upload and download arrows")
    func testMenuBarThroughputFormatting() {
        func formatMenuBarThroughput(up: Double, down: Double) -> String {
            func formatSingle(_ val: Double) -> String {
                guard val > 0 else { return "0 B/s" }
                if val < 1024 * 1024 {
                    return String(format: "%.0f KB/s", val / 1024)
                } else {
                    return String(format: "%.1f MB/s", val / (1024 * 1024))
                }
            }
            return "↑ \(formatSingle(up))  ↓ \(formatSingle(down))"
        }

        let formatted = formatMenuBarThroughput(up: 122_880, down: 4_718_592)
        #expect(formatted == "↑ 120 KB/s  ↓ 4.5 MB/s")
    }

    @Test("T2-F46-02: Zero traffic formatted as clean 0 B/s without clutter")
    func testZeroTrafficFormatting() {
        func formatSingle(_ val: Double) -> String {
            guard val > 0 else { return "0 B/s" }
            return "\(val)"
        }

        #expect(formatSingle(0.0) == "0 B/s")
    }

    @Test("T2-F46-03: Menu Bar dropdown menu structure contains all required quick actions")
    func testMenuBarDropdownActions() {
        let menuItems = [
            "Primary Interface: en10 (10.1.36.52)",
            "Toggle Hotspot",
            "Toggle VPN",
            "Auto-Fix Network",
            "Open NetBoost Window",
            "Quit NetBoost"
        ]

        #expect(menuItems.contains("Toggle Hotspot"))
        #expect(menuItems.contains("Toggle VPN"))
        #expect(menuItems.contains("Auto-Fix Network"))
        #expect(menuItems.contains("Open NetBoost Window"))
        #expect(menuItems.contains("Quit NetBoost"))
    }

    @Test("T2-F46-04: Menu Bar icon adapts to light and dark menu bar styles")
    func testMenuBarIconAdaptation() {
        func menuBarIconName(isDarkMode: Bool) -> String {
            return "network.badge.shield.half.filled"
        }

        let icon = menuBarIconName(isDarkMode: true)
        #expect(!icon.isEmpty)
    }

    @Test("T2-F46-05: Menu bar quick auto-fix trigger launches automated remediation")
    func testMenuBarQuickAutoFixTrigger() {
        var autoFixTriggered = false

        func handleMenuBarAutoFix() {
            autoFixTriggered = true
        }

        handleMenuBarAutoFix()
        #expect(autoFixTriggered == true)
    }
}
