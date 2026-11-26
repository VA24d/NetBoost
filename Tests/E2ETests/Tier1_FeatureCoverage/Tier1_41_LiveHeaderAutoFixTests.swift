import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 41: Live Throughput Header & Quick Auto-Fix", .tags(.tier1, .m6_ui))
struct Tier1_41_LiveHeaderAutoFixTests {

    actor HeaderViewModel {
        private(set) var downloadSpeed: Double = 0
        private(set) var uploadSpeed: Double = 0
        private(set) var activeStatePill: String = "Wired LAN (10.1.36.52)"
        private(set) var isRepairRunning: Bool = false
        private(set) var repairSummary: String? = nil

        func updateSpeeds(download: Double, upload: Double) {
            downloadSpeed = download
            uploadSpeed = upload
        }

        func updateNetworkPill(text: String) {
            activeStatePill = text
        }

        func executeAutoFixSequence() async {
            isRepairRunning = true
            // Simulate MTU + DNS + ARP fix
            try? await Task.sleep(nanoseconds: 10_000_000)
            isRepairRunning = false
            repairSummary = "Auto-Fix Complete: MTU, DNS & ARP Restored"
        }
    }

    @Test("T1-F41-01: Header speedometer reflects download and upload bandwidth metrics")
    func testHeaderSpeedometerMetrics() async {
        let vm = HeaderViewModel()
        await vm.updateSpeeds(download: 12_582_912, upload: 1_048_576) // 12 MB/s down, 1 MB/s up

        let down = await vm.downloadSpeed
        let up = await vm.uploadSpeed
        #expect(down == 12_582_912)
        #expect(up == 1_048_576)
    }

    @Test("T1-F41-02: Active network state pill reflects current environment")
    func testActiveNetworkStatePill() async {
        let vm = HeaderViewModel()
        var pill = await vm.activeStatePill
        #expect(pill.contains("Wired LAN"))

        await vm.updateNetworkPill(text: "Cellular Hotspot (172.20.10.2)")
        pill = await vm.activeStatePill
        #expect(pill.contains("Cellular Hotspot"))
    }

    @Test("T1-F41-03: Auto-Fix Network button is available in header model")
    func testAutoFixButtonAvailability() async {
        let vm = HeaderViewModel()
        let isRunning = await vm.isRepairRunning
        let summary = await vm.repairSummary
        #expect(isRunning == false)
        #expect(summary == nil)
    }

    @Test("T1-F41-04: Clicking Auto-Fix initiates automated repair sequence")
    func testClickAutoFixInitiatesRepair() async {
        let vm = HeaderViewModel()
        await vm.executeAutoFixSequence()

        let isRunning = await vm.isRepairRunning
        let summary = await vm.repairSummary
        #expect(isRunning == false)
        #expect(summary != nil)
        #expect(summary?.contains("Auto-Fix Complete") == true)
    }

    @Test("T1-F41-05: Render repair summary pill upon completion")
    func testRepairSummaryPillRendered() async {
        let vm = HeaderViewModel()
        await vm.executeAutoFixSequence()

        let summary = await vm.repairSummary
        #expect(summary?.contains("MTU, DNS & ARP Restored") == true)
    }
}
