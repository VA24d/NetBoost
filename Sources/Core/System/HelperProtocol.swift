import Foundation

public enum HelperConstants: Sendable {
    public static let label = "com.netboost.helper"
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/com.netboost.helper"
    public static let installedPlistPath = "/Library/LaunchDaemons/com.netboost.helper.plist"
    public static let supportDirectory = "/Library/Application Support/NetBoost"
    public static let authorizedUIDPath = "/Library/Application Support/NetBoost/authorized_uid"
    public static let runtimeDirectory = "/var/run/netboost"
    public static let socketPath = "/var/run/netboost/helper.sock"
    public static let protocolVersion = "1.0.0"
    public static let maxPayloadBytes = 65_536

    public static func isValidSafeServiceName(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.hasPrefix("-"),
              name.utf8.count <= 256 else {
            return false
        }
        return !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    public static func isValidAnchorName(_ anchor: String) -> Bool {
        guard !anchor.isEmpty,
              anchor.utf8.count <= 128,
              !anchor.contains("..") else {
            return false
        }
        let pattern = #"^(?:com\.apple/)?[A-Za-z0-9][A-Za-z0-9._-]*$"#
        return anchor.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isValidMTUString(_ mtu: String) -> Bool {
        guard !mtu.isEmpty,
              mtu.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(mtu) else {
            return false
        }
        return (MTUManager.minimumMTU...MTUManager.maximumMTU).contains(value)
    }

    public static func makeLaunchDaemonPlistData(
        binaryPath: String = installedBinaryPath,
        label: String = label
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "--daemon"],
            "RunAtLoad": true,
            "KeepAlive": true
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

public enum HelperAction: String, Codable, Sendable, CaseIterable {
    case ping
    case status
    case setIPForwarding
    case pfEnable
    case pfDisable
    case pfFlushAnchor
    case setMTU
    case flushDNS
    case flushARP
    case disableIPv6
    case enableIPv6
    case resetDNS
    case setCampusDNS
    case cleanProxies
    case isolateRelay
    case restoreRelay
    case batchAutoFix
    case orderServices
    case pinRoute
    case unpinRoute
    case hotspotStart
    case hotspotStop
}

public struct HelperRequest: Codable, Sendable, Equatable {
    public let version: String
    public let action: HelperAction
    public let arguments: [String]

    public init(
        version: String = HelperConstants.protocolVersion,
        action: HelperAction,
        arguments: [String] = []
    ) {
        self.version = version
        self.action = action
        self.arguments = arguments
    }
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public var shellOutput: ShellOutput {
        ShellOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
