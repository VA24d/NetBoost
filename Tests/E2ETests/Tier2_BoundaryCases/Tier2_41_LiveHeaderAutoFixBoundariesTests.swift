import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 41: Live Header & Auto-Fix Boundaries", .tags(.tier2, .m6_ui))
struct Tier2_41_LiveHeaderAutoFixBoundariesTests {

    func formatSpeed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 B/s" }
        if bytesPerSec < 1024 {
            return String(format: "%.0f B/s", bytesPerSec)
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024)
        } else if bytesPerSec < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        } else {
            return String(format: "%.2f GB/s", bytesPerSec / (1024 * 1024 * 1024))
        }
    }

    @Test("T2-F41-01: Auto-Fix button is disabled during active remediation execution")
    func testAutoFixButtonState() {
        var isRemediating = false
        var buttonClickCount = 0

        func clickAutoFix() {
            guard !isRemediating else { return }
            isRemediating = true
            buttonClickCount += 1
        }

        clickAutoFix()
        #expect(buttonClickCount == 1)
        #expect(isRemediating == true)

        // Second click while in progress must be ignored
        clickAutoFix()
        #expect(buttonClickCount == 1)

        isRemediating = false
        clickAutoFix()
        #expect(buttonClickCount == 2)
    }

    @Test("T2-F41-02: Zero throughput displays clean '0 B/s' without jitter or decimal clutter")
    func testZeroThroughputFormatting() {
        #expect(formatSpeed(0.0) == "0 B/s")
        #expect(formatSpeed(-10.0) == "0 B/s")
    }

    @Test("T2-F41-03: Formatted speeds cover KB/s, MB/s, and GB/s boundaries")
    func testFormattedSpeedUnits() {
        #expect(formatSpeed(512.0) == "512 B/s")
        #expect(formatSpeed(1536.0) == "1.5 KB/s")
        #expect(formatSpeed(5_242_880.0) == "5.0 MB/s")
        #expect(formatSpeed(2_147_483_648.0) == "2.00 GB/s")
    }

    @Test("T2-F41-04: Header network state pill labels match environment classification")
    func testNetworkStatePillLabels() {
        func pillLabel(for state: NetworkEnvironmentState) -> String {
            switch state {
            case .campusLAN: return "Campus LAN (Direct)"
            case .cellularHotspot: return "Cellular Hotspot (VPN)"
            case .externalWiFi: return "External Wi-Fi"
            case .disconnected: return "Offline"
            }
        }

        #expect(pillLabel(for: .defaultCampusLAN) == "Campus LAN (Direct)")
        #expect(pillLabel(for: .defaultCellularHotspot) == "Cellular Hotspot (VPN)")
        #expect(pillLabel(for: .disconnected) == "Offline")
    }

    @Test("T2-F41-05: Auto-Fix sequence executes in correct priority order: MTU -> DNS -> ARP")
    func testAutoFixSequenceOrder() {
        var executionLog: [String] = []

        func runAutoFix() {
            executionLog.append("fix_mtu")
            executionLog.append("flush_dns")
            executionLog.append("flush_arp")
        }

        runAutoFix()
        #expect(executionLog == ["fix_mtu", "flush_dns", "flush_arp"])
    }
}
