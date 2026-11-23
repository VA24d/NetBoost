import Testing
import Foundation
@testable import NetBoostCore

@Suite("Downloader: ClipboardWatcher Unit Tests", .tags(.tier1, .m4_downloader))
struct ClipboardWatcherTests {

    final class MockPasteboard: PasteboardProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        private var changes: Int = 0

        func currentString() -> String? {
            lock.withLock { text }
        }

        func changeCount() -> Int {
            lock.withLock { changes }
        }

        func copyText(_ newText: String) {
            lock.withLock {
                text = newText
                changes += 1
            }
        }
    }

    @Test("Detect valid downloadable URLs with supported extensions")
    func testDetectValidDownloadableURLs() {
        let watcher = ClipboardWatcher()

        let iso = watcher.evaluateClipboardContent("https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop.iso")
        let dmg = watcher.evaluateClipboardContent("https://example.com/software.dmg")
        let zip = watcher.evaluateClipboardContent("https://example.com/archive.zip")
        let targz = watcher.evaluateClipboardContent("https://example.com/source.tar.gz")
        let mp4 = watcher.evaluateClipboardContent("https://example.com/lecture.mp4")
        let pkg = watcher.evaluateClipboardContent("https://example.com/installer.pkg")
        let bin = watcher.evaluateClipboardContent("https://example.com/payload.bin")

        #expect(iso != nil)
        #expect(dmg != nil)
        #expect(zip != nil)
        #expect(targz != nil)
        #expect(mp4 != nil)
        #expect(pkg != nil)
        #expect(bin != nil)
    }

    @Test("Rejection of non-HTTP schemes and plain text")
    func testRejectionOfInvalidContent() {
        let watcher = ClipboardWatcher()

        #expect(watcher.evaluateClipboardContent("javascript:alert(1)") == nil)
        #expect(watcher.evaluateClipboardContent("file:///Users/va/Downloads/file.iso") == nil)
        #expect(watcher.evaluateClipboardContent("ftp://ftp.example.com/file.zip") == nil)
        #expect(watcher.evaluateClipboardContent("Just regular clipboard text copied by user") == nil)
        #expect(watcher.evaluateClipboardContent("https://news.ycombinator.com/item?id=123") == nil)
        #expect(watcher.evaluateClipboardContent("") == nil)
    }

    @Test("URLs with query parameters preserve extension detection")
    func testURLWithQueryParameters() {
        let watcher = ClipboardWatcher()
        let detected = watcher.evaluateClipboardContent("https://cdn.example.com/dataset.zip?token=xyz123&expires=1700000000")

        #expect(detected != nil)
        #expect(detected?.path.hasSuffix(".zip") == true)
    }

    @Test("Debounce window suppresses rapid duplicate copies")
    func testDebounceDuplicateSuppression() {
        let watcher = ClipboardWatcher(debounceInterval: 5.0)
        let url = URL(string: "https://example.com/dataset.iso")!

        let t0 = Date()
        #expect(watcher.shouldEmit(url: url, now: t0) == true)
        #expect(watcher.shouldEmit(url: url, now: t0.addingTimeInterval(1.0)) == false)
        #expect(watcher.shouldEmit(url: url, now: t0.addingTimeInterval(3.0)) == false)
        #expect(watcher.shouldEmit(url: url, now: t0.addingTimeInterval(6.0)) == true)
    }

    @Test("Settings toggle disabling clipboard watcher ignores all inputs")
    func testDisabledToggleIgnoresCopies() {
        let watcher = ClipboardWatcher()
        watcher.isEnabled = false

        let detected = watcher.evaluateClipboardContent("https://example.com/ubuntu.iso")
        #expect(detected == nil)

        watcher.isEnabled = true
        let detectedEnabled = watcher.evaluateClipboardContent("https://example.com/ubuntu.iso")
        #expect(detectedEnabled != nil)
    }

    @Test("Mock pasteboard triggers event emission via detectedURLs stream")
    func testMonitoringStreamEmission() async throws {
        let mockPasteboard = MockPasteboard()
        let watcher = ClipboardWatcher(pasteboard: mockPasteboard, debounceInterval: 1.0)
        watcher.startMonitoring(interval: 0.05)
        defer { watcher.stopMonitoring() }

        // Start listening task
        let emissionTask = Task { () -> [URL] in
            var received: [URL] = []
            for await url in watcher.detectedURLs {
                received.append(url)
                if received.count >= 2 {
                    break
                }
            }
            return received
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        mockPasteboard.copyText("https://example.com/first.iso")

        try await Task.sleep(nanoseconds: 100_000_000)
        mockPasteboard.copyText("https://example.com/second.dmg")

        let collected = await emissionTask.value
        #expect(collected.count == 2)
        #expect(collected[0].lastPathComponent == "first.iso")
        #expect(collected[1].lastPathComponent == "second.dmg")
    }
}
