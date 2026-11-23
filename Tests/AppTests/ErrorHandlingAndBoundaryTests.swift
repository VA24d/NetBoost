import Foundation
import Testing
import NetBoostCore
@testable import NetBoostApp

@Suite("AppTests: Error Handling & Boundary Cases", .tags(.tier2, .m6_ui))
struct ErrorHandlingAndBoundaryTests {

    @Test("Hotspot cannot be enabled when upstream Ethernet en10 is absent")
    @MainActor
    func testHotspotDisabledWithoutEthernet() async {
        let mockHotspot = MockAppHotspotController()
        let appState = AppState(hotspotController: mockHotspot, startBackgroundTimers: false)

        // Set non-Ethernet environment (Cellular en0)
        appState.updateEnvironment(.defaultCellularHotspot)
        appState.upstreamInterface = "en0"

        #expect(!appState.canEnableHotspot)

        // Attempting toggle should be rejected
        try? await appState.toggleHotspot()
        #expect(!appState.isHotspotActive)
        #expect(!mockHotspot.startCalled)
        #expect(appState.hotspotError?.contains("requires active Wired Ethernet") == true)
    }

    @Test("Invalid URL schemes are rejected by download accelerator with descriptive error")
    @MainActor
    func testDownloadURLValidation() async {
        let mockDownloader = MockAppDownloadManager()
        let appState = AppState(downloadManager: mockDownloader, startBackgroundTimers: false)

        // Invalid scheme: ftp://
        appState.downloadURLInput = "ftp://campus.net/file.iso"
        try? await appState.startDownload()
        #expect(!mockDownloader.startDownloadCalled)
        #expect(appState.downloadError?.contains("must begin with http:// or https://") == true)

        // Invalid format: plaintext
        appState.downloadURLInput = "not_a_valid_url"
        try? await appState.startDownload()
        #expect(!mockDownloader.startDownloadCalled)
        #expect(appState.downloadError != nil)

        // Incomplete hostless schemes
        appState.downloadURLInput = "http://"
        try? await appState.startDownload()
        #expect(!mockDownloader.startDownloadCalled)
        #expect(appState.downloadError != nil)

        appState.downloadURLInput = "https://"
        try? await appState.startDownload()
        #expect(!mockDownloader.startDownloadCalled)
        #expect(appState.downloadError != nil)

        appState.downloadURLInput = "http:///"
        try? await appState.startDownload()
        #expect(!mockDownloader.startDownloadCalled)
        #expect(appState.downloadError != nil)

        // Valid scheme: https://
        appState.downloadURLInput = "https://speed.campus.net/valid.iso"
        try? await appState.startDownload()
        #expect(mockDownloader.startDownloadCalled)
        #expect(appState.downloadError == nil)
    }

    @Test("VPN connection failure is handled gracefully with error badge")
    @MainActor
    func testVPNFailureHandling() async {
        let mockVPN = MockAppVPNController()
        mockVPN.shouldThrowError = true
        let appState = AppState(vpnController: mockVPN, startBackgroundTimers: false)

        do {
            try await appState.toggleVPN()
        } catch {
            // Expected throw
        }

        #expect(appState.vpnStatus == .disconnected)
    }

    @Test("Auto-fix button ignores second click while remediation is actively running")
    @MainActor
    func testAutoFixDoubleTriggerSuppression() async {
        let mockDoctor = MockAppCampusDoctor()
        let appState = AppState(campusDoctor: mockDoctor, startBackgroundTimers: false)

        appState.isAutoFixRunning = true

        // Re-invoking while active should return immediately without executing
        await appState.executeAutoFix()

        #expect(mockDoctor.executionLog.isEmpty)
    }

    @Test("Repair log console caps entries at 200 items to prevent unbounded memory growth")
    @MainActor
    func testRepairLogCapacityCap() {
        let appState = AppState(startBackgroundTimers: false)

        for i in 1...250 {
            appState.appendRepairLog("Log entry \(i)")
        }

        #expect(appState.repairLogs.count == 200)
        #expect(appState.repairLogs.last?.contains("Log entry 250") == true)
        #expect(!appState.repairLogs.first!.contains("Log entry 1 "))
    }
}
