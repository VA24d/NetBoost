import Foundation
import Testing
import NetBoostCore
@testable import NetBoostApp

@Suite("AppTests: AppState Polling & Smoothing", .tags(.tier1, .m6_ui))
struct AppStateTimerAndPollingTests {

    @Test("Speedometer applies Exponential Moving Average smoothing formula")
    @MainActor
    func testThroughputEMASmoothing() {
        let appState = AppState(startBackgroundTimers: false)

        // Initial speed update: previousSpeed is 0, so EMA initializes directly to instantaneous sample
        appState.updateSpeeds(download: 10_485_760, upload: 1_048_576)

        #expect(appState.currentDownloadBps == 10_485_760)
        #expect(appState.currentUploadBps == 1_048_576)
        #expect(appState.smoothedDownloadBps == 10_485_760) // Initialized to first sample
        #expect(appState.smoothedUploadBps == 1_048_576)

        // Second update: instantaneous doubles to 20 MB/s (20_971_520)
        // With alpha = 0.25: smoothed = 0.25 * 20_971_520 + 0.75 * 10_485_760 = 5_242_880 + 7_864_320 = 13_107_200 (12.5 MB/s)
        appState.updateSpeeds(download: 20_971_520, upload: 2_097_152)
        #expect(appState.smoothedDownloadBps == 13_107_200)
        #expect(appState.smoothedUploadBps == 1_310_720)
    }

    @Test("Menu bar throughput formatting formats speeds across B/s, KB/s, and MB/s")
    @MainActor
    func testMenuBarFormatting() {
        let appState = AppState(startBackgroundTimers: false)

        // 0 speeds
        appState.updateSpeeds(download: 0, upload: 0)
        #expect(appState.menuBarThroughputText == "↑ 0 B/s  ↓ 0 B/s")

        // KB/s range
        let upBytes = 512.0 * 1024.0   // 512 KB/s
        let downBytes = 2.0 * 1024.0 * 1024.0 // 2 MB/s

        // Set smoothed speeds directly to verify format
        appState.smoothedUploadBps = upBytes
        appState.smoothedDownloadBps = downBytes
        appState.menuBarThroughputText = SpeedFormatter.formatMenuBarThroughput(
            up: appState.smoothedUploadBps,
            down: appState.smoothedDownloadBps
        )

        #expect(appState.menuBarThroughputText.contains("512 KB/s"))
        #expect(appState.menuBarThroughputText.contains("2.0 MB/s"))
    }

    @Test("Campus Doctor RTT probe dictionary populates across all 5 endpoints")
    @MainActor
    func testRTTProbeDictionaryPopulation() async {
        let mockDoctor = MockAppCampusDoctor()
        mockDoctor.mockProbeResults = [
            "10.1.36.1": ProbeResult(targetHost: "10.1.36.1", isReachable: true, latencyMs: 1.2),
            "10.8.0.80": ProbeResult(targetHost: "10.8.0.80", isReachable: true, latencyMs: 3.5),
            "turing.iiit.ac.in": ProbeResult(targetHost: "turing.iiit.ac.in", isReachable: true, latencyMs: 8.4),
            "google.com": ProbeResult(targetHost: "google.com", isReachable: true, latencyMs: 24.1),
            "claude.com": ProbeResult(targetHost: "claude.com", isReachable: true, latencyMs: 45.6)
        ]

        let appState = AppState(campusDoctor: mockDoctor, startBackgroundTimers: false)
        await appState.runDiagnostics()

        #expect(appState.endpointRTTs.count == 5)
        #expect(appState.endpointRTTs["10.1.36.1"]?.latencyMs == 1.2)
        #expect(appState.endpointRTTs["turing.iiit.ac.in"]?.latencyMs == 8.4)
        #expect(appState.endpointRTTs["claude.com"]?.latencyMs == 45.6)
    }

    @Test("Clipboard stream emits detected URLs and updates AppState")
    @MainActor
    func testClipboardStreamDetection() async {
        let mockClipboard = MockAppClipboardWatcher()
        let appState = AppState(pasteboardWatcher: mockClipboard, startBackgroundTimers: true)

        let targetURL = URL(string: "https://releases.ubuntu.com/24.04/ubuntu.iso")!
        mockClipboard.emitURL(targetURL)

        // Allow task to receive stream item
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(appState.detectedClipboardURL == targetURL)
        #expect(appState.repairLogs.contains(where: { $0.contains("ubuntu.iso") }))

        appState.stopBackgroundTasks()
    }
}
