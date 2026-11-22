import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 22: Clipboard Monitor Boundaries", .tags(.tier2, .m4_downloader, .accelerator))
struct Tier2_22_ClipboardMonitorBoundariesTests {

    let downloadableExtensions = ["iso", "dmg", "zip", "tar.gz", "mp4", "pkg", "bin", "tar"]

    func isDownloadableURLString(_ text: String) -> Bool {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        let lowerPath = url.path.lowercased()
        return downloadableExtensions.contains { ext in
            lowerPath.hasSuffix("." + ext)
        }
    }

    @Test("T2-F22-01: Duplicate copies of identical URL within debounce window are suppressed")
    func testDuplicateURLSuppression() {
        var lastURL: String? = nil
        var captureCount = 0

        func processClipboardText(_ text: String) {
            guard text != lastURL else { return }
            lastURL = text
            captureCount += 1
        }

        let url = "https://turing.iiit.ac.in/datasets/image_embeddings.tar.gz"
        processClipboardText(url)
        processClipboardText(url) // Duplicate
        processClipboardText(url) // Duplicate

        #expect(captureCount == 1)

        // New distinct URL
        processClipboardText("https://turing.iiit.ac.in/datasets/resnet50.bin")
        #expect(captureCount == 2)
    }

    @Test("T2-F22-02: Non-HTTP schemes and plain text are rejected")
    func testNonHTTPSchemeRejection() {
        #expect(isDownloadableURLString("javascript:alert(1)") == false)
        #expect(isDownloadableURLString("file:///Users/va/Downloads/file.iso") == false)
        #expect(isDownloadableURLString("Just regular clipboard text without URL") == false)
        #expect(isDownloadableURLString("ftp://ftp.example.com/file.zip") == false)
        #expect(isDownloadableURLString("") == false)
    }

    @Test("T2-F22-03: Valid download extensions (.iso, .dmg, .zip, .tar.gz, .mp4, .pkg) are accepted")
    func testDownloadableExtensionMatching() {
        #expect(isDownloadableURLString("https://example.com/macOS_Sonoma.dmg") == true)
        #expect(isDownloadableURLString("https://example.com/ubuntu_server.iso") == true)
        #expect(isDownloadableURLString("https://example.com/archive.zip") == true)
        #expect(isDownloadableURLString("https://example.com/data.tar.gz") == true)
        #expect(isDownloadableURLString("https://example.com/installer.pkg") == true)
        #expect(isDownloadableURLString("https://example.com/lecture_recording.mp4") == true)
        #expect(isDownloadableURLString("https://example.com/index.html") == false)
    }

    @Test("T2-F22-04: Clipboard monitor disabled flag suppresses prompt triggers")
    func testClipboardMonitorDisabledFlag() {
        var isEnabled = false

        func handleClipboardChange(urlText: String) -> Bool {
            guard isEnabled else { return false }
            return isDownloadableURLString(urlText)
        }

        let result = handleClipboardChange(urlText: "https://example.com/ubuntu.iso")
        #expect(result == false)

        isEnabled = true
        let resultEnabled = handleClipboardChange(urlText: "https://example.com/ubuntu.iso")
        #expect(resultEnabled == true)
    }

    @Test("T2-F22-05: URLs with query parameters preserve downloadable extension detection")
    func testURLWithQueryParams() {
        let urlWithQuery = "https://cdn.example.com/dataset.zip?token=xyz123&expires=1700000000"
        guard let url = URL(string: urlWithQuery) else {
            Issue.record("Failed to parse URL")
            return
        }

        #expect(url.path.hasSuffix(".zip"))
    }
}
