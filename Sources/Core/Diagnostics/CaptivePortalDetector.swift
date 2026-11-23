import Foundation

/// Detects captive portals, captive network redirection, and Wi-Fi login walls.
public final class CaptivePortalDetector: Sendable {

    public static let appleHotspotDetectURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    public static let successPayload = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

    public init() {}

    /// Evaluates whether a captive portal is active using the specified or default probe URL.
    /// - Parameter probeURL: URL to probe (defaults to Apple's hotspot-detect endpoint).
    /// - Returns: Tuple of `(status: CaptivePortalStatus, redirectURL: String?)`.
    public func evaluate(
        probeURL: URL = appleHotspotDetectURL
    ) async throws -> (status: CaptivePortalStatus, redirectURL: String?) {
        return try await CaptiveDetector.evaluate(probeURL: probeURL)
    }

    /// Checks captive portal state and returns a `CaptivePortalStatus`.
    public func checkStatus(
        probeURL: URL = appleHotspotDetectURL
    ) async -> CaptivePortalStatus {
        do {
            let (status, _) = try await evaluate(probeURL: probeURL)
            return status
        } catch {
            return .unknown
        }
    }

    /// Creates a diagnostic `DetectedIssue` if a captive portal is active.
    public func createIssueIfActive(
        status: CaptivePortalStatus,
        redirectURL: String?
    ) -> DetectedIssue? {
        switch status {
        case .redirecting:
            let target = redirectURL ?? "login portal"
            return DetectedIssue(
                severity: .critical,
                title: "Captive Portal Active",
                description: "Campus Wi-Fi requires authentication. Redirecting to \(target)",
                recommendedFixAction: "Open login portal in browser: \(target)",
                automatedFixAvailable: true
            )
        case .detected:
            return DetectedIssue(
                severity: .critical,
                title: "Campus Wi-Fi Captive Portal Active",
                description: "Captive portal intercepting HTTP/HTTPS traffic.",
                recommendedFixAction: "open_login_page",
                automatedFixAvailable: true
            )
        case .notDetected, .authenticated, .unknown:
            return nil
        }
    }
}

// MARK: - CaptiveDetector Static Interface

public struct CaptiveDetector: Sendable {

    public static func evaluate(
        probeURL: URL
    ) async throws -> (status: CaptivePortalStatus, redirectURL: String?) {
        var request = URLRequest(url: probeURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let delegate = RedirectCatcherDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return (.unknown, nil)
        }

        // 302 Redirection: Captive portal is intercepting traffic
        if http.statusCode == 302 || http.statusCode == 301 || http.statusCode == 307 {
            let location = http.value(forHTTPHeaderField: "Location")
            return (.redirecting, location)
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        if bodyString.contains("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>") ||
           bodyString.contains("<TITLE>Success</TITLE>") {
            return (.notDetected, nil)
        }

        if bodyString.contains("login") || bodyString.contains("Login") || bodyString.contains("<form") || bodyString.contains("captive") {
            return (.detected, nil)
        }

        // Non-200 or unexpected payload
        if http.statusCode != 200 {
            return (.detected, nil)
        }

        return (.unknown, nil)
    }

    private final class RedirectCatcherDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            // Do not follow redirect; catch the 302 response directly
            return nil
        }
    }
}
