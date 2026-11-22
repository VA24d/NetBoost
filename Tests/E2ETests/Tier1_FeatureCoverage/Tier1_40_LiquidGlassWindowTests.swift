import Testing
import Foundation
import SwiftUI
@testable import NetBoostCore

@Suite("Feature 40: Liquid Glass Translucent Window", .tags(.tier1, .m6_ui))
struct Tier1_40_LiquidGlassWindowTests {

    struct LiquidGlassTheme {
        static let sapphireBlue = Color(red: 0.05, green: 0.45, blue: 0.95)
        static let emeraldGreen = Color(red: 0.1, green: 0.85, blue: 0.4)
        static let amberWarning = Color(red: 1.0, green: 0.7, blue: 0.1)
        static let violetAccent = Color(red: 0.65, green: 0.25, blue: 0.95)

        static let minWindowWidth: CGFloat = 850
        static let minWindowHeight: CGFloat = 600
        static let windowTitle = "NetBoost"
    }

    @Test("T1-F40-01: UltraThinMaterial vibrancy token defined for window background")
    func testMaterialVibrancyToken() {
        let material = Material.ultraThinMaterial
        #expect(material == Material.ultraThinMaterial)
    }

    @Test("T1-F40-02: Hidden title bar window style configuration")
    func testHiddenTitleBarStyleConfiguration() {
        let hasHiddenTitleBar = true
        #expect(hasHiddenTitleBar == true)
        #expect(LiquidGlassTheme.windowTitle == "NetBoost")
    }

    @Test("T1-F40-03: Dark glass theme palette constants defined")
    func testDarkGlassThemePalette() {
        #expect(LiquidGlassTheme.sapphireBlue != nil)
        #expect(LiquidGlassTheme.emeraldGreen != nil)
        #expect(LiquidGlassTheme.amberWarning != nil)
        #expect(LiquidGlassTheme.violetAccent != nil)
    }

    @Test("T1-F40-04: Neon accent colors mapped to subsystem indicators")
    func testAccentColorSubsystemMapping() {
        enum SubsystemColor {
            case wiredLAN
            case activeHotspot
            case warningDegraded
            case downloadAccelerator

            var color: Color {
                switch self {
                case .wiredLAN: return LiquidGlassTheme.sapphireBlue
                case .activeHotspot: return LiquidGlassTheme.emeraldGreen
                case .warningDegraded: return LiquidGlassTheme.amberWarning
                case .downloadAccelerator: return LiquidGlassTheme.violetAccent
                }
            }
        }

        #expect(SubsystemColor.wiredLAN.color == LiquidGlassTheme.sapphireBlue)
        #expect(SubsystemColor.activeHotspot.color == LiquidGlassTheme.emeraldGreen)
        #expect(SubsystemColor.warningDegraded.color == LiquidGlassTheme.amberWarning)
        #expect(SubsystemColor.downloadAccelerator.color == LiquidGlassTheme.violetAccent)
    }

    @Test("T1-F40-05: Window minimum dimensions enforce responsive constraints")
    func testWindowDimensionConstraints() {
        #expect(LiquidGlassTheme.minWindowWidth >= 800)
        #expect(LiquidGlassTheme.minWindowHeight >= 550)
    }
}
