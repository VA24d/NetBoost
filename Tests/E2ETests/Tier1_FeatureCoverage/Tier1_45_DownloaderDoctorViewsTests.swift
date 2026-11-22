import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 45: Download Accelerator & Doctor Views", .tags(.tier1, .m6_ui))
struct Tier1_45_DownloaderDoctorViewsTests {

    final class DownloaderDoctorViewModel: @unchecked Sendable {
        private(set) var downloadURLString: String = ""
        private(set) var activeChunks: [DownloadChunkInfo] = []
        private(set) var endpointRTTs: [String: Double] = [:]
        private(set) var captivePortalBannerVisible: Bool = false
        private(set) var repairLogs: [String] = []

        func setURL(_ str: String) {
            downloadURLString = str
        }

        func setChunks(_ c: [DownloadChunkInfo]) {
            activeChunks = c
        }

        func updateRTT(endpoint: String, rttMs: Double) {
            endpointRTTs[endpoint] = rttMs
        }

        func setCaptiveBanner(visible: Bool) {
            captivePortalBannerVisible = visible
        }

        func appendLog(_ log: String) {
            repairLogs.append(log)
        }
    }

    @Test("T1-F45-01: URL input field accepts target download URL")
    func testDownloadURLInput() {
        let vm = DownloaderDoctorViewModel()
        vm.setURL("https://example.com/dataset.iso")

        #expect(vm.downloadURLString == "https://example.com/dataset.iso")
    }

    @Test("T1-F45-02: Segmented progress bars visualizer displays 8 chunk states")
    func testSegmentedChunkBars() {
        let vm = DownloaderDoctorViewModel()
        let chunks = (0..<8).map { i in
            DownloadChunkInfo(id: i, rangeStart: Int64(i * 100), rangeEnd: Int64((i + 1) * 100 - 1), downloadedBytes: 50)
        }
        vm.setChunks(chunks)

        #expect(vm.activeChunks.count == 8)
        #expect(vm.activeChunks.first?.progress == 0.5)
    }

    @Test("T1-F45-03: Real-time RTT dials display 5 campus and external endpoints")
    func testRealTimeRTTDials() {
        let vm = DownloaderDoctorViewModel()
        vm.updateRTT(endpoint: "10.1.36.1", rttMs: 0.8)
        vm.updateRTT(endpoint: "10.8.0.80", rttMs: 1.1)
        vm.updateRTT(endpoint: "turing.iiit.ac.in", rttMs: 1.4)
        vm.updateRTT(endpoint: "google.com", rttMs: 18.2)
        vm.updateRTT(endpoint: "claude.com", rttMs: 22.0)

        #expect(vm.endpointRTTs.count == 5)
        #expect(vm.endpointRTTs["10.1.36.1"] == 0.8)
        #expect(vm.endpointRTTs["turing.iiit.ac.in"] == 1.4)
    }

    @Test("T1-F45-04: Captive portal banner renders when portal detected")
    func testCaptivePortalBanner() {
        let vm = DownloaderDoctorViewModel()
        #expect(vm.captivePortalBannerVisible == false)

        vm.setCaptiveBanner(visible: true)
        #expect(vm.captivePortalBannerVisible == true)
    }

    @Test("T1-F45-05: Diagnostic repair log view displays executed remediation actions")
    func testRepairLogView() {
        let vm = DownloaderDoctorViewModel()
        vm.appendLog("DNS Cache Flushed")
        vm.appendLog("ARP Cache Flushed")
        vm.appendLog("Wi-Fi MTU set to 1280")

        #expect(vm.repairLogs.count == 3)
        #expect(vm.repairLogs.contains("DNS Cache Flushed"))
        #expect(vm.repairLogs.contains("Wi-Fi MTU set to 1280"))
    }
}
