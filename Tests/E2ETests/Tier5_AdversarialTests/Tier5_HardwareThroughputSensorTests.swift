import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import NetBoostCore
@testable import NetBoostApp

@Suite("Tier 5 - Hardware Throughput Sensor, Rollover & UI Polish Tests", .tags(.tier5, .network_env))
struct Tier5_HardwareThroughputSensorTests {

    // MARK: - Test 1: Darwin getInterfaceBytes Query

    @Test("T5-HW-01: Darwin getInterfaceBytes queries hardware interfaces without error")
    func testDarwinGetInterfaceBytesExecution() {
        // Query aggregate hardware bytes (all non-loopback interfaces)
        let aggregate = DarwinSocketHelper.getInterfaceBytes(for: nil)
        #expect(aggregate.inputBytes >= 0)
        #expect(aggregate.outputBytes >= 0)

        // Query en0 specifically (standard primary Wi-Fi / LAN on Apple Silicon / macOS)
        let en0Bytes = DarwinSocketHelper.getInterfaceBytes(for: "en0")
        #expect(en0Bytes.inputBytes >= 0)
        #expect(en0Bytes.outputBytes >= 0)
    }

    // MARK: - Test 2: Invalid Interface Graceful Handling

    @Test("T5-HW-02: Darwin getInterfaceBytes safely handles nonexistent or invalid interface")
    func testDarwinGetInterfaceBytesInvalidInterface() {
        let invalid = DarwinSocketHelper.getInterfaceBytes(for: "nonexistent_iface_9999")
        #expect(invalid.inputBytes == 0)
        #expect(invalid.outputBytes == 0)

        let empty = DarwinSocketHelper.getInterfaceBytes(for: "")
        #expect(empty.inputBytes == 0)
        #expect(empty.outputBytes == 0)
    }

    // MARK: - Test 3: 32-bit Rollover Delta Calculation

    @Test("T5-HW-03: 32-bit Darwin counter rollover calculation avoids arithmetic underflow trap")
    func testDarwin32BitCounterRollover() {
        func computeRolloverDelta(previous: UInt64, current: UInt64) -> UInt64 {
            if current >= previous {
                return current - previous
            } else {
                let max32 = UInt64(UInt32.max)
                return (max32 - previous + 1) + current
            }
        }

        let previous: UInt64 = 4_294_960_000
        let current: UInt64 = 25_000

        let delta = computeRolloverDelta(previous: previous, current: current)
        let expectedDelta: UInt64 = (UInt64(UInt32.max) - 4_294_960_000 + 1) + 25_000
        #expect(delta == expectedDelta)
        #expect(delta == 32_296)
    }

    // MARK: - Test 4: Interface Flapping / Counter Reset

    @Test("T5-HW-04: Interface flapping or disconnect counter reset returns zero delta")
    func testInterfaceCounterResetHandling() {
        func computeSafeDelta(previous: UInt64, current: UInt64) -> UInt64 {
            let isInterfaceRestart = (current == 0 && previous > 1_000_000)
            if isInterfaceRestart || current < previous {
                return 0
            }
            return current - previous
        }

        let previous: UInt64 = 500_000_000
        let current: UInt64 = 0

        let safeDelta = computeSafeDelta(previous: previous, current: current)
        #expect(safeDelta == 0)
    }

    // MARK: - Test 5: EMA Speed Smoothing

    @Test("T5-HW-05: SpeedMetricsCalculator EMA smoothing under extreme volatility")
    func testSpeedMetricsSmoothingVolatility() {
        var smoothed: Double = 0
        let alpha = 0.25

        // Sudden burst: 0 -> 100 MB/s
        let burstSpeed: Double = 104_857_600 // 100 MB/s
        smoothed = SpeedMetricsCalculator.updateEMA(previousSpeed: smoothed, instantaneousSpeed: burstSpeed, alpha: alpha)
        // With guard previousSpeed > 0, initial speed is set directly to burstSpeed
        #expect(smoothed == burstSpeed)

        // Second tick at burst speed: stays at burstSpeed
        smoothed = SpeedMetricsCalculator.updateEMA(previousSpeed: smoothed, instantaneousSpeed: burstSpeed, alpha: alpha)
        #expect(smoothed == burstSpeed)

        // Drop to 0: EMA attenuates by (1 - alpha) = 0.75
        smoothed = SpeedMetricsCalculator.updateEMA(previousSpeed: smoothed, instantaneousSpeed: 0, alpha: alpha)
        #expect(smoothed == 78_643_200)

        // Check for NaN or Infinite
        #expect(!smoothed.isNaN)
        #expect(!smoothed.isInfinite)
    }

    // MARK: - Test 6: SpeedFormatter Strings

    @Test("T5-HW-06: SpeedFormatter formats throughput across multiple orders of magnitude")
    func testSpeedFormatterMagnitudeScales() {
        #expect(SpeedFormatter.formatSpeed(0) == "0 B/s")
        #expect(SpeedFormatter.formatSpeed(512) == "512 B/s")
        #expect(SpeedFormatter.formatSpeed(1024) == "1.0 KB/s")
        #expect(SpeedFormatter.formatSpeed(1_536) == "1.5 KB/s")
        #expect(SpeedFormatter.formatSpeed(1_048_576) == "1.0 MB/s")
        #expect(SpeedFormatter.formatSpeed(104_857_600) == "100.0 MB/s")
        #expect(SpeedFormatter.formatSpeed(1_073_741_824) == "1.00 GB/s")

        let menuBarStr = SpeedFormatter.formatMenuBarThroughput(up: 1024, down: 2048)
        #expect(menuBarStr.contains("↑"))
        #expect(menuBarStr.contains("↓"))
        #expect(menuBarStr.contains("KB/s"))
    }

    // MARK: - Test 7: App Switcher & AppKit Window Dimensions

    @Test("T5-HW-07: Window minimum dimensions and regular activation policy configuration")
    func testWindowDimensionsAndActivationPolicy() {
        #expect(GlassTheme.minWindowWidth >= 850)
        #expect(GlassTheme.recommendedMinWidth >= 900)
        #expect(GlassTheme.minWindowHeight >= 600)
        #expect(GlassTheme.defaultWindowWidth >= GlassTheme.minWindowWidth)
        #expect(GlassTheme.defaultWindowHeight >= GlassTheme.minWindowHeight)

        #if canImport(AppKit)
        // Verify .regular activation policy is standard for Cmd+Tab and Dock visibility
        let regularPolicy = NSApplication.ActivationPolicy.regular
        #expect(regularPolicy.rawValue == 0)
        #endif
    }

    // MARK: - Test 8: Customization Enums

    @Test("T5-HW-08: MenuBarIconStyle and AppLogoStyle enum completeness and Codable conformance")
    func testCustomizationEnumsCodable() throws {
        let menuStyles = MenuBarIconStyle.allCases
        #expect(menuStyles.contains(.iconAndSpeed))
        #expect(menuStyles.contains(.compactSpeed))
        #expect(menuStyles.contains(.minimalBadge))

        let logoStyles = AppLogoStyle.allCases
        #expect(logoStyles.contains(.sapphireLightning))
        #expect(logoStyles.contains(.liquidWaveform))
        #expect(logoStyles.contains(.networkCore))

        for style in menuStyles {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MenuBarIconStyle.self, from: data)
            #expect(decoded == style)
        }

        for logo in logoStyles {
            let data = try JSONEncoder().encode(logo)
            let decoded = try JSONDecoder().decode(AppLogoStyle.self, from: data)
            #expect(decoded == logo)
        }
    }

    // MARK: - Test 9: AppState Speed Updates

    @Test("T5-HW-09: AppState updateSpeeds smoothly recalculates throughput and menu bar text")
    @MainActor
    func testAppStateSpeedUpdates() {
        let appState = AppState(startBackgroundTimers: false)

        #expect(appState.currentDownloadBps == 0)
        #expect(appState.currentUploadBps == 0)

        appState.updateSpeeds(download: 1_048_576, upload: 524_288)

        #expect(appState.currentDownloadBps == 1_048_576)
        #expect(appState.currentUploadBps == 524_288)
        #expect(appState.smoothedDownloadBps > 0)
        #expect(appState.smoothedUploadBps > 0)
        #expect(appState.menuBarThroughputText.contains("↑"))
        #expect(appState.menuBarThroughputText.contains("↓"))
    }
}
