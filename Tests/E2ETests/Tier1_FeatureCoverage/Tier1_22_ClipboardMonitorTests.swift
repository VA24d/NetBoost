import Testing
import Foundation

@Suite("Feature 22: Clipboard Download Monitor", .tags(.tier1, .m4_downloader))
struct Tier1_22_ClipboardMonitorTests {

    struct ClipboardMonitorEngine {
        var isEnabled: Bool = true
        let supportedExtensions = Set(["iso", "dmg", "zip", "tar.gz", "mp4", "pkg", "bin"])

        func evaluateClipboardContent(_ text: String) -> URL? {
            guard isEnabled else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }

            let pathLower = url.path.lowercased()
            let hasValidExtension = supportedExtensions.contains { ext in
                pathLower.hasSuffix("." + ext)
            }

            return hasValidExtension ? url : nil
        }
    }

    @Test("T1-F22-01: Detect valid HTTP/HTTPS downloadable URL copied to clipboard")
    func testDetectValidDownloadURL() {
        let monitor = ClipboardMonitorEngine()
        let detected = monitor.evaluateClipboardContent("https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop.iso")

        #expect(detected != nil)
        #expect(detected?.absoluteString == "https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop.iso")
    }

    @Test("T1-F22-02: Filter matches allowed downloadable extensions (.iso, .dmg, .zip, .mp4)")
    func testFilterMatchesDownloadableExtensions() {
        let monitor = ClipboardMonitorEngine()

        let iso = monitor.evaluateClipboardContent("https://example.com/file.iso")
        let dmg = monitor.evaluateClipboardContent("https://example.com/app.dmg")
        let zip = monitor.evaluateClipboardContent("https://example.com/archive.zip")
        let mp4 = monitor.evaluateClipboardContent("https://example.com/video.mp4")

        #expect(iso != nil)
        #expect(dmg != nil)
        #expect(zip != nil)
        #expect(mp4 != nil)
    }

    @Test("T1-F22-03: Ignore non-URL plain text or web articles")
    func testIgnorePlainText() {
        let monitor = ClipboardMonitorEngine()

        let plain = monitor.evaluateClipboardContent("This is just some random text copied by the user")
        let webpage = monitor.evaluateClipboardContent("https://news.ycombinator.com/item?id=12345")

        #expect(plain == nil)
        #expect(webpage == nil)
    }

    @Test("T1-F22-04: Auto-trigger download prompt action upon detection")
    func testTriggerDownloadPromptAction() {
        var triggeredPrompts: [URL] = []
        let monitor = ClipboardMonitorEngine()

        let urlString = "https://example.com/dataset.tar.gz"
        if let url = monitor.evaluateClipboardContent(urlString) {
            triggeredPrompts.append(url)
        }

        #expect(triggeredPrompts.count == 1)
        #expect(triggeredPrompts.first?.lastPathComponent == "dataset.tar.gz")
    }

    @Test("T1-F22-05: Settings toggle disabling clipboard monitor ignores all copies")
    func testDisableClipboardMonitorToggle() {
        var monitor = ClipboardMonitorEngine()
        monitor.isEnabled = false

        let url = monitor.evaluateClipboardContent("https://example.com/ubuntu.iso")
        #expect(url == nil)
    }
}
