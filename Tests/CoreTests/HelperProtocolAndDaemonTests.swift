import Foundation
import Testing
@testable import NetBoostCore

@Suite("HelperProtocol and Persistent Daemon Tests")
struct HelperProtocolAndDaemonTests {

    @Test("HelperConstants paths and limits match LaunchDaemon specification")
    func testHelperConstants() {
        #expect(HelperConstants.label == "com.netboost.helper")
        #expect(HelperConstants.installedBinaryPath == "/Library/PrivilegedHelperTools/com.netboost.helper")
        #expect(HelperConstants.installedPlistPath == "/Library/LaunchDaemons/com.netboost.helper.plist")
        #expect(HelperConstants.supportDirectory == "/Library/Application Support/NetBoost")
        #expect(HelperConstants.authorizedUIDPath == "/Library/Application Support/NetBoost/authorized_uid")
        #expect(HelperConstants.runtimeDirectory == "/var/run/netboost")
        #expect(HelperConstants.socketPath == "/var/run/netboost/helper.sock")
        #expect(HelperConstants.protocolVersion == "1.0.0")
        #expect(HelperConstants.maxPayloadBytes == 65_536)
    }

    @Test("HelperAction.allCases includes all expected privileged actions")
    func testHelperActionAllCases() {
        let expectedRawValues: Set<String> = [
            "ping", "status", "setIPForwarding", "pfEnable", "pfDisable",
            "pfFlushAnchor", "setMTU", "flushDNS", "flushARP", "disableIPv6",
            "enableIPv6", "resetDNS", "setCampusDNS", "cleanProxies",
            "isolateRelay", "restoreRelay", "batchAutoFix", "orderServices",
            "pinRoute", "unpinRoute", "hotspotStart", "hotspotStop"
        ]
        let actualRawValues = Set(HelperAction.allCases.map(\.rawValue))
        #expect(actualRawValues == expectedRawValues)
        #expect(HelperAction.allCases.count == 22)
    }

    @Test("HelperRequest and HelperResponse round-trip encode and decode cleanly")
    func testRequestResponseRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for action in HelperAction.allCases {
            let request = HelperRequest(
                version: HelperConstants.protocolVersion,
                action: action,
                arguments: ["USB 10/100 LAN", "1280", "192.168.2.1"]
            )
            let data = try encoder.encode(request)
            let decoded = try decoder.decode(HelperRequest.self, from: data)
            #expect(decoded == request)
            #expect(decoded.version == HelperConstants.protocolVersion)
            #expect(decoded.action == action)
            #expect(decoded.arguments == ["USB 10/100 LAN", "1280", "192.168.2.1"])
        }

        let okResponse = HelperResponse(exitCode: 0, stdout: "ok", stderr: "")
        let okDecoded = try decoder.decode(HelperResponse.self, from: encoder.encode(okResponse))
        #expect(okDecoded == okResponse)
        #expect(okDecoded.succeeded)
        #expect(okDecoded.shellOutput == ShellOutput(stdout: "ok", stderr: "", exitCode: 0))

        let errResponse = HelperResponse(exitCode: 2, stdout: "", stderr: "invalid argument")
        let errDecoded = try decoder.decode(HelperResponse.self, from: encoder.encode(errResponse))
        #expect(errDecoded == errResponse)
        #expect(!errDecoded.succeeded)
    }

    @Test("Pure argument validators accept valid inputs and reject flags, traversal, and bounds errors")
    func testArgumentValidators() {
        #expect(HelperConstants.isValidSafeServiceName("Wi-Fi"))
        #expect(HelperConstants.isValidSafeServiceName("USB 10/100 LAN"))
        #expect(HelperConstants.isValidSafeServiceName("iPhone USB"))
        #expect(HelperConstants.isValidSafeServiceName("Thunderbolt Bridge"))
        #expect(!HelperConstants.isValidSafeServiceName(""))
        #expect(!HelperConstants.isValidSafeServiceName("-setMTU"))
        #expect(!HelperConstants.isValidSafeServiceName("-rf"))
        #expect(!HelperConstants.isValidSafeServiceName("Wi-Fi\nrm"))
        #expect(!HelperConstants.isValidSafeServiceName("Wi-Fi\0bad"))
        #expect(!HelperConstants.isValidSafeServiceName(String(repeating: "a", count: 300)))

        #expect(HelperConstants.isValidAnchorName("netboost"))
        #expect(HelperConstants.isValidAnchorName("com.apple/netboost"))
        #expect(HelperConstants.isValidAnchorName("custom_anchor-1.0"))
        #expect(!HelperConstants.isValidAnchorName(""))
        #expect(!HelperConstants.isValidAnchorName("-a"))
        #expect(!HelperConstants.isValidAnchorName("../netboost"))
        #expect(!HelperConstants.isValidAnchorName("com.apple/../netboost"))
        #expect(!HelperConstants.isValidAnchorName("netboost;id"))
        #expect(!HelperConstants.isValidAnchorName("other/anchor"))

        #expect(HelperConstants.isValidMTUString("576"))
        #expect(HelperConstants.isValidMTUString("1280"))
        #expect(HelperConstants.isValidMTUString("1500"))
        #expect(!HelperConstants.isValidMTUString(""))
        #expect(!HelperConstants.isValidMTUString("575"))
        #expect(!HelperConstants.isValidMTUString("1501"))
        #expect(!HelperConstants.isValidMTUString("-1280"))
        #expect(!HelperConstants.isValidMTUString("1280px"))
        #expect(!HelperConstants.isValidMTUString(" 1280"))
    }

    @Test("PrivilegeHelper executable and daemon state detection remain safe and non-destructive")
    func testPrivilegeHelperDaemonDetection() {
        if let located = PrivilegeHelper.locateHelperExecutable() {
            #expect(FileManager.default.isExecutableFile(atPath: located))
        }

        if let bundledOrBuilt = PrivilegeHelper.locateBundledOrBuiltHelperExecutable() {
            #expect(FileManager.default.isExecutableFile(atPath: bundledOrBuilt))
        }

        // Daemon status probe must complete promptly without prompting UI or mutating session state.
        let _ = PrivilegeHelper.isHelperDaemonInstalled
    }

    @Test("LaunchDaemon plist template validates with PropertyListSerialization and plutil -lint")
    func testLaunchDaemonPlistValidation() async throws {
        let plistData = try HelperConstants.makeLaunchDaemonPlistData()
        let parsed = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]

        #expect(parsed?["Label"] as? String == HelperConstants.label)
        #expect(parsed?["ProgramArguments"] as? [String] == [HelperConstants.installedBinaryPath, "--daemon"])
        #expect(parsed?["RunAtLoad"] as? Bool == true)
        #expect(parsed?["KeepAlive"] as? Bool == true)

        let tempPlist = (NSTemporaryDirectory() as NSString).appendingPathComponent("com.netboost.helper.test.\(UUID().uuidString).plist")
        try plistData.write(to: URL(fileURLWithPath: tempPlist), options: .atomic)
        defer { try? FileManager.default.removeItem(atPath: tempPlist) }

        let lint = try await ShellCommand.run("/usr/bin/plutil", arguments: ["-lint", tempPlist])
        #expect(lint.succeeded)
    }
}
