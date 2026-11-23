import Foundation
import AppKit

public protocol PasteboardProvider: Sendable {
    func currentString() -> String?
    func changeCount() -> Int
}

public final class SystemPasteboardProvider: PasteboardProvider, @unchecked Sendable {
    public init() {}

    public func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }
}

public protocol ClipboardWatcherProtocol: Sendable {
    var isEnabled: Bool { get set }
    var detectedURLs: AsyncStream<URL> { get }
    func evaluateClipboardContent(_ text: String) -> URL?
    func startMonitoring(interval: TimeInterval)
    func stopMonitoring()
}

public final class ClipboardWatcher: ClipboardWatcherProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _isEnabled: Bool = true
    private let debounceInterval: TimeInterval
    private var history: [String: Date] = [:]
    private var lastObservedChangeCount: Int = -1
    private var timerTask: Task<Void, Never>?
    private let pasteboard: PasteboardProvider
    private var continuation: AsyncStream<URL>.Continuation?

    public let detectedURLs: AsyncStream<URL>

    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isEnabled = newValue
        }
    }

    public static let defaultSupportedExtensions: Set<String> = [
        "iso", "dmg", "zip", "tar.gz", "mp4", "pkg", "bin", "tar", "gz"
    ]

    public let supportedExtensions: Set<String>

    public init(
        pasteboard: PasteboardProvider = SystemPasteboardProvider(),
        debounceInterval: TimeInterval = 10.0,
        supportedExtensions: Set<String> = ClipboardWatcher.defaultSupportedExtensions
    ) {
        self.pasteboard = pasteboard
        self.debounceInterval = debounceInterval
        self.supportedExtensions = supportedExtensions

        var cont: AsyncStream<URL>.Continuation?
        self.detectedURLs = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    deinit {
        stopMonitoring()
        continuation?.finish()
    }

    /// Evaluates candidate text and returns a valid downloadable URL if it matches rules and isEnabled.
    public func evaluateClipboardContent(_ text: String) -> URL? {
        guard isEnabled else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }

        let lowerPath = url.path.lowercased()
        let hasMatchingExtension = supportedExtensions.contains { ext in
            lowerPath.hasSuffix("." + ext) || url.pathExtension.lowercased() == ext
        }

        return hasMatchingExtension ? url : nil
    }

    /// Evaluates if the URL should be emitted or suppressed by debouncing.
    public func shouldEmit(url: URL, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let key = url.absoluteString
        if let lastSeen = history[key], now.timeIntervalSince(lastSeen) < debounceInterval {
            return false // Debounced duplicate
        }
        history[key] = now
        return true
    }

    /// Starts polling the pasteboard for changes.
    public func startMonitoring(interval: TimeInterval = 0.5) {
        lock.lock()
        defer { lock.unlock() }

        guard timerTask == nil else { return }
        lastObservedChangeCount = pasteboard.changeCount()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self = self else { break }
                self.checkPasteboard()
            }
        }
    }

    /// Stops polling.
    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        timerTask?.cancel()
        timerTask = nil
    }

    private func checkPasteboard() {
        guard isEnabled else { return }

        let currentChangeCount = pasteboard.changeCount()
        let hasChanged = lock.withLock { () -> Bool in
            guard currentChangeCount != lastObservedChangeCount else { return false }
            lastObservedChangeCount = currentChangeCount
            return true
        }

        guard hasChanged, let content = pasteboard.currentString() else { return }

        if let validURL = evaluateClipboardContent(content) {
            if shouldEmit(url: validURL) {
                continuation?.yield(validURL)
            }
        }
    }
}
