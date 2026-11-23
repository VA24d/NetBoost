import Foundation
import Testing
import SwiftUI
import NetBoostCore
@testable import NetBoostApp

@Suite("AppTests: Navigation & Theme Design System Tokens", .tags(.tier1, .m6_ui))
struct NavigationAndThemeTokenTests {

    @Test("AppNavigationTab defines 7 comprehensive tabs with valid SF Symbols")
    func testNavigationTabsAndIcons() {
        let tabs = AppNavigationTab.allCases
        #expect(tabs.count == 7)

        #expect(AppNavigationTab.dashboard.iconName == "square.grid.2x2")
        #expect(AppNavigationTab.hotspot.iconName == "personalhotspot")
        #expect(AppNavigationTab.dispatcher.iconName == "arrow.triangle.branch")
        #expect(AppNavigationTab.vpn.iconName == "lock.shield")
        #expect(AppNavigationTab.accelerator.iconName == "bolt.horizontal")
        #expect(AppNavigationTab.doctor.iconName == "cross.case")
        #expect(AppNavigationTab.aiDoctor.iconName == "cpu")
    }

    @Test("Tab switching updates active selected tab state")
    @MainActor
    func testTabSelection() {
        let appState = AppState(startBackgroundTimers: false)
        #expect(appState.selectedTab == .dashboard)

        appState.selectedTab = .hotspot
        #expect(appState.selectedTab == .hotspot)

        appState.selectedTab = .accelerator
        #expect(appState.selectedTab == .accelerator)

        appState.selectedTab = .aiDoctor
        #expect(appState.selectedTab == .aiDoctor)
    }

    @Test("GlassTheme neon color hex codes match specifications")
    func testGlassThemeColorHexes() {
        #expect(GlassTheme.cyanSapphireHex == "#00D2FF")
        #expect(GlassTheme.sapphireBlueHex == "#0051FF")
        #expect(GlassTheme.emeraldGreenHex == "#00E676")
        #expect(GlassTheme.amberWarningHex == "#FFD600")
        #expect(GlassTheme.violetAccentHex == "#D500F9")
        #expect(GlassTheme.backgroundDarkHex == "#0D1117")
        #expect(GlassTheme.redAlertHex == "#FF1744")
    }

    @Test("Window minimum dimensions enforce responsive constraints")
    func testWindowMinConstraints() {
        #expect(GlassTheme.minWindowWidth >= 800)
        #expect(GlassTheme.minWindowHeight >= 550)
        #expect(GlassTheme.recommendedMinWidth >= 900)
        #expect(GlassTheme.windowTitle == "NetBoost")
    }

    @Test("WCAG 2.2 AA Contrast ratio meets requirement (> 4.5:1)")
    func testWCAGContrastRatio() {
        let ratio = GlassTheme.contrastRatio(
            foreground: .white,
            background: GlassTheme.backgroundDark
        )
        #expect(ratio >= 4.5)
    }

    @Test("SpeedFormatter accurately formats zero, KB, MB, and GB boundaries")
    func testSpeedFormatterBoundaries() {
        #expect(SpeedFormatter.formatSpeed(0) == "0 B/s")
        #expect(SpeedFormatter.formatSpeed(-5) == "0 B/s")
        #expect(SpeedFormatter.formatSpeed(512) == "512 B/s")
        #expect(SpeedFormatter.formatSpeed(1_536) == "1.5 KB/s")
        #expect(SpeedFormatter.formatSpeed(5_242_880) == "5.0 MB/s")
        #expect(SpeedFormatter.formatSpeed(2_147_483_648) == "2.00 GB/s")
    }
}
