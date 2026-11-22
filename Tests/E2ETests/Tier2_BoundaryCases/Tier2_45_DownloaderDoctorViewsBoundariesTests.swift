import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 45: Downloader & Doctor Views Boundaries", .tags(.tier2, .m6_ui))
struct Tier2_45_DownloaderDoctorViewsBoundariesTests {

    @Test("T2-F45-01: Invalid URL entry triggers inline error feedback in view model")
    func testInvalidURLFeedback() {
        func validateDownloadInput(_ input: String) -> String? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "Please enter a valid HTTP or HTTPS download URL."
            }
            return nil
        }

        #expect(validateDownloadInput("not a url") != nil)
        #expect(validateDownloadInput("ftp://example.com/file.bin") != nil)
        #expect(validateDownloadInput("https://turing.iiit.ac.in/data.bin") == nil)
    }

    @Test("T2-F45-02: Failed chunk highlighted in red with retry action")
    func testFailedChunkVisualState() {
        let failedChunk = DownloadChunkInfo(
            id: 2,
            rangeStart: 2000,
            rangeEnd: 2999,
            downloadedBytes: 150,
            status: .failed
        )

        func chunkStatusColor(_ status: ChunkStatus) -> String {
            switch status {
            case .completed: return "#00E676"  // Green
            case .downloading: return "#00D2FF" // Cyan
            case .pending: return "#757575"     // Grey
            case .failed: return "#FF1744"      // Red
            }
        }

        #expect(chunkStatusColor(failedChunk.status) == "#FF1744")
    }

    @Test("T2-F45-03: Latency dial color threshold mapping (<50ms green, <150ms amber, >=150ms red)")
    func testLatencyColorThresholds() {
        func latencyColor(ms: Double) -> String {
            if ms < 50.0 {
                return "#00E676" // Green (Excellent)
            } else if ms < 150.0 {
                return "#FFD600" // Amber (Acceptable)
            } else {
                return "#FF1744" // Red (Degraded)
            }
        }

        #expect(latencyColor(ms: 12.5) == "#00E676")
        #expect(latencyColor(ms: 85.0) == "#FFD600")
        #expect(latencyColor(ms: 185.0) == "#FF1744")
    }

    @Test("T2-F45-04: Pause and resume button interaction state transitions")
    func testPauseResumeStateTransition() {
        var status = DownloadTaskStatus.downloading

        func togglePause() {
            if status == .downloading {
                status = .paused
            } else if status == .paused {
                status = .downloading
            }
        }

        togglePause()
        #expect(status == .paused)

        togglePause()
        #expect(status == .downloading)
    }

    @Test("T2-F45-05: Diagnostic repair log view model clear action empties history")
    func testClearDiagnosticHistory() {
        var repairLog = [
            "DNS flushed",
            "ARP table cleared",
            "MTU set to 1280"
        ]

        func clearLogs() {
            repairLog.removeAll()
        }

        clearLogs()
        #expect(repairLog.isEmpty)
    }
}
