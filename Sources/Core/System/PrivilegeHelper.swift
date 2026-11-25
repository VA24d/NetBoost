import Foundation
import Darwin
import CryptoKit

public enum PrivilegeError: Error, LocalizedError, Sendable, Equatable {
    case elevationDenied
    case helperNotFound(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .elevationDenied:
            return "Administrator privilege elevation was denied or cancelled."
        case .helperNotFound(let path):
            return "Privileged helper script not found at path: \(path)"
        case .executionFailed(let msg):
            return "Privileged command failed: \(msg)"
        }
    }
}

private actor DaemonInstallCoordinator {
    private var isExecuting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func runExclusive(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if isExecuting {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        isExecuting = true
        defer {
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.resume()
            } else {
                isExecuting = false
            }
        }
        try await operation()
    }
}

public final class PrivilegeHelper: @unchecked Sendable {

    private static let sessionLock = NSLock()
    private static let installCoordinator = DaemonInstallCoordinator()
    nonisolated(unsafe) private static var _isAuthorized: Bool = false
    nonisolated(unsafe) private static var _sessionToken: String? = nil
    nonisolated(unsafe) private static var _sessionExpiry: Date? = nil

    /// Checks if the current process is running with root privileges (EUID == 0).
    public static var isRoot: Bool {
        geteuid() == 0
    }

    /// Whether NetBoost currently holds an active, authorized administrative session (or EUID == 0).
    public static var isAuthorized: Bool {
        if isRoot { return true }
        return sessionLock.withLock {
            if let expiry = _sessionExpiry, expiry < Date() {
                _isAuthorized = false
                _sessionToken = nil
                return false
            }
            return _isAuthorized
        }
    }

    /// Current session token if authorized.
    public static var sessionToken: String? {
        sessionLock.withLock { _sessionToken }
    }

    /// Explicitly requests upfront authorization from the user, establishing an in-process or persistent daemon session.
    @discardableResult
    public static func requestAuthorization(
        reason: String = "NetBoost requires administrator privileges to configure network adapters and packet filter routing."
    ) async throws -> Bool {
        if isRoot {
            sessionLock.withLock {
                _isAuthorized = true
                _sessionToken = "root-\(ProcessInfo.processInfo.processIdentifier)"
                _sessionExpiry = Date.distantFuture
            }
            return true
        }

        if await syncAuthorizationFromDaemonAsync() {
            return true
        }

        if isAuthorized {
            return true
        }

        if locateBundledOrBuiltHelperExecutable() != nil {
            try await installHelperDaemon()
            return true
        }

        let validationScript = "echo 'NetBoost privileged session active'"
        let output = try await runElevated(script: validationScript)
        if output.succeeded {
            sessionLock.withLock {
                _isAuthorized = true
                _sessionToken = UUID().uuidString
                _sessionExpiry = Date().addingTimeInterval(3600)
            }
            return true
        } else {
            throw PrivilegeError.executionFailed(output.stderr)
        }
    }

    /// Revokes cached authorization and resets the session.
    public static func revokeAuthorization() {
        sessionLock.withLock {
            _isAuthorized = false
            _sessionToken = nil
            _sessionExpiry = nil
        }
    }

    /// Manually sets authorization state for testing environments.
    public static func setAuthorizedForTesting(_ authorized: Bool) {
        sessionLock.withLock {
            _isAuthorized = authorized
            _sessionToken = authorized ? "test-token" : nil
            _sessionExpiry = authorized ? Date().addingTimeInterval(3600) : nil
        }
    }

    /// Whether an executable `netboost-helper.sh` script is present in any candidate search path.
    public static var hasRootHelper: Bool {
        locateHelperScript() != nil
    }

    /// Locates the `netboost-helper.sh` script across bundle resources, system install locations, and workspace fallback.
    public static func locateHelperScript() -> String? {
        let rawCandidates: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("netboost-helper.sh").path,
            Bundle.main.resourceURL?.appendingPathComponent("Scripts/netboost-helper.sh").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/netboost-helper.sh").path,
            Bundle.main.resourcePath.map { $0 + "/netboost-helper.sh" },
            Bundle.main.resourcePath.map { $0 + "/Scripts/netboost-helper.sh" },
            "/usr/local/bin/netboost-helper.sh",
            "/opt/netboost/bin/netboost-helper.sh",
            FileManager.default.currentDirectoryPath + "/Scripts/netboost-helper.sh"
        ]

        var seen = Set<String>()
        for candidate in rawCandidates.compactMap({ $0 }) {
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { continue }
            if isRegularExecutableFile(atPath: standardized) {
                return standardized
            }
        }
        return nil
    }

    // MARK: - Persistent Helper LaunchDaemon

    /// Locates the bundled or SwiftPM-built `NetBoostHelper` binary (excluding the system-installed copy).
    public static func locateBundledOrBuiltHelperExecutable() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let repoRootFromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // System
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Repo root

        let rawCandidates: [String?] = [
            execDir?.appendingPathComponent("NetBoostHelper").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NetBoostHelper").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/com.netboost.helper").path,
            execDir?.appendingPathComponent(".build/release/NetBoostHelper").path,
            execDir?.appendingPathComponent(".build/debug/NetBoostHelper").path,
            cwd + "/.build/release/NetBoostHelper",
            cwd + "/.build/debug/NetBoostHelper",
            cwd + "/.build/arm64-apple-macosx/release/NetBoostHelper",
            cwd + "/.build/arm64-apple-macosx/debug/NetBoostHelper",
            repoRootFromSource.appendingPathComponent(".build/release/NetBoostHelper").path,
            repoRootFromSource.appendingPathComponent(".build/debug/NetBoostHelper").path,
            repoRootFromSource.appendingPathComponent(".build/arm64-apple-macosx/release/NetBoostHelper").path,
            repoRootFromSource.appendingPathComponent(".build/arm64-apple-macosx/debug/NetBoostHelper").path
        ]

        var seen = Set<String>()
        for candidate in rawCandidates.compactMap({ $0 }) {
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { continue }
            if isRegularExecutableFile(atPath: standardized) {
                return standardized
            }
        }
        return nil
    }

    /// Locates `NetBoostHelper` from bundle/build output or the installed LaunchDaemon binary path.
    public static func locateHelperExecutable() -> String? {
        if let bundledOrBuilt = locateBundledOrBuiltHelperExecutable() {
            return bundledOrBuilt
        }
        if isRegularExecutableFile(atPath: HelperConstants.installedBinaryPath) {
            return HelperConstants.installedBinaryPath
        }
        return nil
    }

    /// Checks whether the LaunchDaemon binary, plist, and live root socket are all present and responding.
    public static var isHelperDaemonInstalled: Bool {
        guard isRegularExecutableFile(atPath: HelperConstants.installedBinaryPath),
              FileManager.default.fileExists(atPath: HelperConstants.installedPlistPath),
              FileManager.default.fileExists(atPath: HelperConstants.socketPath) else {
            return false
        }
        return pingDaemonSync(timeout: 0.15)
    }

    /// Checks live daemon reachability and binary digest off the caller's actor without prompting the user.
    @discardableResult
    public static func syncAuthorizationFromDaemonAsync() async -> Bool {
        await Task.detached(priority: .utility) {
            syncAuthorizationFromDaemon()
        }.value
    }

    /// Checks live daemon reachability and binary digest without prompting the user.
    @discardableResult
    public static func syncAuthorizationFromDaemon() -> Bool {
        guard isRegularExecutableFile(atPath: HelperConstants.installedBinaryPath),
              FileManager.default.fileExists(atPath: HelperConstants.socketPath) else {
            return false
        }

        guard pingDaemonSync(timeout: 0.15) else {
            return false
        }

        if let sourcePath = locateBundledOrBuiltHelperExecutable() {
            guard let sourceDigest = sha256Hex(atPath: sourcePath),
                  let installedDigest = sha256Hex(atPath: HelperConstants.installedBinaryPath),
                  sourceDigest == installedDigest else {
                return false
            }
        }

        sessionLock.withLock {
            _isAuthorized = true
            _sessionToken = "helper-daemon-active"
            _sessionExpiry = Date.distantFuture
        }
        return true
    }

    /// Installs or upgrades the persistent root LaunchDaemon in a single atomic admin prompt.
    public static func installHelperDaemon() async throws {
        try await installCoordinator.runExclusive {
            guard let sourceHelper = locateBundledOrBuiltHelperExecutable() else {
                throw PrivilegeError.helperNotFound("NetBoostHelper")
            }

            if FileManager.default.fileExists(atPath: HelperConstants.installedPlistPath),
               await syncAuthorizationFromDaemonAsync() {
                return
            }

            let plistData = try HelperConstants.makeLaunchDaemonPlistData()
            let plistBase64 = plistData.base64EncodedString()

            let uidString = String(getuid())
            let qBinDir = ShellCommand.shellQuote("/Library/PrivilegedHelperTools")
            let qSupportDir = ShellCommand.shellQuote(HelperConstants.supportDirectory)
            let qRuntimeDir = ShellCommand.shellQuote(HelperConstants.runtimeDirectory)
            let qSource = ShellCommand.shellQuote(sourceHelper)
            let qDestBin = ShellCommand.shellQuote(HelperConstants.installedBinaryPath)
            let qUIDFile = ShellCommand.shellQuote(HelperConstants.authorizedUIDPath)
            let qUIDTmp = ShellCommand.shellQuote(HelperConstants.authorizedUIDPath + ".tmp")
            let qDestPlist = ShellCommand.shellQuote(HelperConstants.installedPlistPath)
            let qPlistTmp = ShellCommand.shellQuote(HelperConstants.installedPlistPath + ".tmp")
            let qPlistBase64 = ShellCommand.shellQuote(plistBase64)
            let qServiceTarget = ShellCommand.shellQuote("system/\(HelperConstants.label)")

            let commands: [String] = [
                "/usr/bin/install -d -m 755 -o root -g wheel \(qBinDir) \(qSupportDir) \(qRuntimeDir)",
                "/usr/bin/install -m 755 -o root -g wheel \(qSource) \(qDestBin)",
                "/bin/rm -f \(qUIDTmp) && (umask 077 && /usr/bin/printf '%s\\n' \(ShellCommand.shellQuote(uidString)) > \(qUIDTmp)) && /usr/sbin/chown root:wheel \(qUIDTmp) && /bin/chmod 644 \(qUIDTmp) && /bin/mv -f \(qUIDTmp) \(qUIDFile)",
                "/bin/rm -f \(qPlistTmp) && (umask 077 && /usr/bin/printf '%s' \(qPlistBase64) | /usr/bin/base64 -D > \(qPlistTmp)) && /usr/sbin/chown root:wheel \(qPlistTmp) && /bin/chmod 644 \(qPlistTmp) && /bin/mv -f \(qPlistTmp) \(qDestPlist)",
                "/usr/bin/plutil -lint \(qDestPlist)",
                "(/bin/launchctl bootout \(qServiceTarget) 2>/dev/null || true)",
                "(/bin/launchctl enable \(qServiceTarget) 2>/dev/null || true)",
                "/bin/launchctl bootstrap system \(qDestPlist)"
            ]

            _ = try await runBatchElevated(commands: commands)

            for _ in 0..<20 {
                if await syncAuthorizationFromDaemonAsync() {
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            throw PrivilegeError.executionFailed("Helper daemon installed but failed to respond on \(HelperConstants.socketPath)")
        }
    }

    /// Unloads and removes the persistent LaunchDaemon and revokes cached authorization.
    public static func uninstallDaemon() async throws {
        try await installCoordinator.runExclusive {
            let pathsToCheck = [
                HelperConstants.installedPlistPath,
                HelperConstants.installedBinaryPath,
                HelperConstants.supportDirectory,
                HelperConstants.runtimeDirectory
            ]
            if pathsToCheck.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                let qServiceTarget = ShellCommand.shellQuote("system/\(HelperConstants.label)")
                let qPlist = ShellCommand.shellQuote(HelperConstants.installedPlistPath)
                let qBin = ShellCommand.shellQuote(HelperConstants.installedBinaryPath)
                let qSupport = ShellCommand.shellQuote(HelperConstants.supportDirectory)
                let qRuntime = ShellCommand.shellQuote(HelperConstants.runtimeDirectory)

                let commands = [
                    "(/bin/launchctl bootout \(qServiceTarget) 2>/dev/null || true)",
                    "/bin/rm -f \(qPlist) \(qBin)",
                    "/bin/rm -rf \(qSupport) \(qRuntime)"
                ]
                _ = try await runBatchElevated(commands: commands)
            }
            revokeAuthorization()
        }
    }

    /// Executes a privileged action over the persistent root LaunchDaemon socket, installing it once if permitted.
    public static func runDaemonAction(
        action: HelperAction,
        arguments: [String] = [],
        allowInteractiveInstall: Bool = true,
        timeout: TimeInterval = 30.0
    ) async throws -> ShellOutput {
        if !(await syncAuthorizationFromDaemonAsync()) {
            if allowInteractiveInstall && locateBundledOrBuiltHelperExecutable() != nil {
                try await installHelperDaemon()
            } else {
                let installed = await Task.detached(priority: .utility) { isHelperDaemonInstalled }.value
                if !installed {
                    throw PrivilegeError.helperNotFound(HelperConstants.installedBinaryPath)
                }
            }
        }

        let request = HelperRequest(action: action, arguments: arguments)
        let response: HelperResponse
        do {
            response = try await sendSocketRequest(request, timeout: timeout)
        } catch PrivilegeError.helperNotFound(_) where allowInteractiveInstall && locateBundledOrBuiltHelperExecutable() != nil {
            try await installHelperDaemon()
            response = try await sendSocketRequest(request, timeout: timeout)
        }

        guard response.succeeded else {
            let err = response.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivilegeError.executionFailed(err.isEmpty ? "Helper action '\(action.rawValue)' failed with exit code \(response.exitCode)" : err)
        }
        return response.shellOutput
    }

    /// Runs an action as root directly, via the persistent LaunchDaemon, or via `osascript` fallback.
    public static func executeDaemonOrElevated(
        rootExecutable: String? = nil,
        rootArguments: [String] = [],
        daemonAction: HelperAction,
        daemonArguments: [String] = [],
        fallbackScript: String,
        timeout: TimeInterval = 60.0
    ) async throws -> ShellOutput {
        if isRoot {
            if let rootExecutable {
                return try await ShellCommand.run(rootExecutable, arguments: rootArguments, timeout: timeout)
            }
            return try await ShellCommand.runBash(fallbackScript, timeout: timeout)
        }

        var daemonAvailable = locateBundledOrBuiltHelperExecutable() != nil
        if !daemonAvailable {
            daemonAvailable = await Task.detached(priority: .utility) { isHelperDaemonInstalled }.value
        }
        if daemonAvailable {
            do {
                return try await runDaemonAction(
                    action: daemonAction,
                    arguments: daemonArguments,
                    timeout: timeout
                )
            } catch PrivilegeError.helperNotFound {
                // Fall back to osascript elevation when daemon is unavailable.
            }
        }

        if let rootExecutable {
            return try await runElevated(script: rootExecutable, arguments: rootArguments, timeout: timeout)
        }
        return try await runElevated(script: fallbackScript, timeout: timeout)
    }

    // MARK: - Legacy / Fallback osascript Elevation

    /// Executes a command with root privileges. If already root (`EUID == 0`), executes directly.
    public static func runElevated(
        script: String,
        arguments: [String] = [],
        timeout: TimeInterval = 60.0
    ) async throws -> ShellOutput {
        let fullCommand: String
        if arguments.isEmpty {
            fullCommand = script
        } else {
            let quotedScript = ShellCommand.shellQuote(script)
            let quotedArgs = arguments.map { ShellCommand.shellQuote($0) }
            fullCommand = "\(quotedScript) \(quotedArgs.joined(separator: " "))"
        }

        if isRoot {
            return try await ShellCommand.runBash(fullCommand, timeout: timeout)
        }

        let escapedScript = fullCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = "do shell script \"\(escapedScript)\" with administrator privileges"

        let output = try await ShellCommand.run(
            "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            timeout: timeout
        )

        do {
            let handled = try handleElevationResult(output)
            sessionLock.withLock {
                _isAuthorized = true
                _sessionToken = UUID().uuidString
                _sessionExpiry = Date().addingTimeInterval(3600)
            }
            return handled
        } catch PrivilegeError.elevationDenied {
            sessionLock.withLock {
                _isAuthorized = false
                _sessionToken = nil
                _sessionExpiry = nil
            }
            throw PrivilegeError.elevationDenied
        }
    }

    /// Executes an array of shell commands in a single atomic script ('cmd1 && cmd2 && ...')
    /// ensuring only a single upfront authorization prompt is presented.
    public static func runBatchElevated(
        commands: [String],
        timeout: TimeInterval = 60.0
    ) async throws -> ShellOutput {
        guard !commands.isEmpty else {
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        let combined = commands.joined(separator: " && ")
        return try await runElevated(script: combined, timeout: timeout)
    }

    /// Evaluates the ShellOutput from an elevation attempt, throwing PrivilegeError if execution failed or elevation was denied.
    public static func handleElevationResult(_ output: ShellOutput) throws -> ShellOutput {
        if !output.succeeded {
            let err = output.stderr
            if err.contains("User canceled") || err.contains("-128") || err.contains("Authentication dialog dismissed") {
                throw PrivilegeError.elevationDenied
            }
            throw PrivilegeError.executionFailed(output.stderr)
        }
        return output
    }

    /// Runs an action via the netboost-helper.sh script with root privileges.
    public static func runHelper(
        action: String,
        arguments: [String] = [],
        timeout: TimeInterval = 60.0
    ) async throws -> ShellOutput {
        guard let helperPath = locateHelperScript() else {
            throw PrivilegeError.helperNotFound("Scripts/netboost-helper.sh")
        }

        var fullArgs = [action]
        fullArgs.append(contentsOf: arguments)

        return try await runElevated(
            script: helperPath,
            arguments: fullArgs,
            timeout: timeout
        )
    }

    // MARK: - Private Socket & File Helpers

    private static func isRegularExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func sha256Hex(atPath path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pingDaemonSync(timeout: TimeInterval) -> Bool {
        let req = HelperRequest(action: .ping, arguments: [])
        guard let response = try? sendSocketRequestSync(req, socketPath: HelperConstants.socketPath, timeout: timeout) else {
            return false
        }
        return response.succeeded && response.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == HelperConstants.protocolVersion
    }

    private static func sendSocketRequest(
        _ request: HelperRequest,
        timeout: TimeInterval
    ) async throws -> HelperResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try sendSocketRequestSync(
                        request,
                        socketPath: HelperConstants.socketPath,
                        timeout: timeout
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func sendSocketRequestSync(
        _ request: HelperRequest,
        socketPath: String,
        timeout: TimeInterval
    ) throws -> HelperResponse {
        let payload: Data
        do {
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            payload = encoded
        } catch {
            throw PrivilegeError.executionFailed("Failed to encode helper request: \(error.localizedDescription)")
        }

        guard payload.count <= HelperConstants.maxPayloadBytes else {
            throw PrivilegeError.executionFailed("Helper request exceeds \(HelperConstants.maxPayloadBytes) byte limit")
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PrivilegeError.executionFailed("Unable to create AF_UNIX socket (errno \(errno))")
        }
        defer { Darwin.close(fd) }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let clampedMs = max(1, Int(timeout * 1000))
        var tv = timeval(tv_sec: clampedMs / 1000, tv_usec: Int32((clampedMs % 1000) * 1000))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            throw PrivilegeError.executionFailed("Helper socket path exceeds sun_path limit")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            rawBuf.initializeMemory(as: UInt8.self, repeating: 0)
            for (idx, cChar) in pathBytes.enumerated() {
                rawBuf[idx] = UInt8(bitPattern: cChar)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let errCode = errno
            if errCode == ENOENT || errCode == ECONNREFUSED {
                throw PrivilegeError.helperNotFound(socketPath)
            }
            throw PrivilegeError.executionFailed("Failed to connect to helper daemon (errno \(errCode))")
        }

        let writeOk = payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                offset += n
            }
            return true
        }
        guard writeOk else {
            throw PrivilegeError.executionFailed("Failed to write request to helper daemon (errno \(errno))")
        }
        _ = Darwin.shutdown(fd, SHUT_WR)

        var responseData = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let maxResponseBytes = HelperConstants.maxPayloadBytes * 4

        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw PrivilegeError.executionFailed("Timed out or failed reading helper response (errno \(errno))")
            }
            if bytesRead == 0 { break }

            if let nlIndex = chunk[0..<bytesRead].firstIndex(of: 0x0A) {
                responseData.append(contentsOf: chunk[0..<nlIndex])
                break
            } else {
                responseData.append(contentsOf: chunk[0..<bytesRead])
            }

            if responseData.count > maxResponseBytes {
                throw PrivilegeError.executionFailed("Helper daemon response exceeded size limit")
            }
        }

        guard !responseData.isEmpty else {
            throw PrivilegeError.executionFailed("Helper daemon closed connection without response")
        }

        do {
            return try JSONDecoder().decode(HelperResponse.self, from: responseData)
        } catch {
            throw PrivilegeError.executionFailed("Failed to decode helper daemon response: \(error.localizedDescription)")
        }
    }
}
