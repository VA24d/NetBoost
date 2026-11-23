import Testing
import Foundation
@testable import NetBoostCore

@Suite("VPN Subsystem: Passepartout Controller Unit Tests", .tags(.tier1, .m3_vpn))
struct PassepartoutControllerTests {

    @Test("Generate scutil CLI commands for status, start, stop, and list operations")
    func testCommandGenerators() {
        let statusCmd = PassepartoutController.makeStatusCommand(profile: "macos.ovpn")
        #expect(statusCmd == ["/usr/sbin/scutil", "--nc", "status", "macos.ovpn"])

        let startCmd = PassepartoutController.makeStartCommand(profile: "macos.ovpn")
        #expect(startCmd == ["/usr/sbin/scutil", "--nc", "start", "macos.ovpn"])

        let stopCmd = PassepartoutController.makeStopCommand(profile: "macos.ovpn")
        #expect(stopCmd == ["/usr/sbin/scutil", "--nc", "stop", "macos.ovpn"])

        let listCmd = PassepartoutController.makeListCommand()
        #expect(listCmd == ["/usr/sbin/scutil", "--nc", "list"])
    }

    @Test("Parse scutil status outputs into VPNStatus enum cases")
    func testParseScutilStatus() {
        #expect(PassepartoutController.parseScutilStatus(output: "Connected") == .connected)
        #expect(PassepartoutController.parseScutilStatus(output: "Connected\nExtended Status <dictionary> {\n}") == .connected)
        #expect(PassepartoutController.parseScutilStatus(output: "Connecting") == .connecting)
        #expect(PassepartoutController.parseScutilStatus(output: "Disconnected") == .disconnected)
        #expect(PassepartoutController.parseScutilStatus(output: "Disconnecting") == .disconnecting)
        #expect(PassepartoutController.parseScutilStatus(output: "No service") == .error)
    }

    @Test("Parse multi-line scutil list output extracting service profiles")
    func testParseListOutput() {
        let rawList = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   09C7C32A-1DF8-4783-953E-E22F5972C95B VPN (com.algoritmico.ios.Passepartout) "macos.ovpn"                     [VPN:com.algoritmico.ios.Passepartout]
          (Connected)      550E8400-E29B-41D4-A716-446655440000 VPN (com.apple.ppp.l2tp) "BackupVPN"                                   [VPN:com.apple.ppp.l2tp]
        """

        let profiles = PassepartoutController.parseListOutput(output: rawList)
        #expect(profiles.count == 2)

        let macos = profiles[0]
        #expect(macos.name == "macos.ovpn")
        #expect(macos.serviceID == "09C7C32A-1DF8-4783-953E-E22F5972C95B")
        #expect(macos.isDefault == true)
        #expect(macos.status == .disconnected)

        let backup = profiles[1]
        #expect(backup.name == "BackupVPN")
        #expect(backup.isDefault == false)
        #expect(backup.status == .connected)

        let names = PassepartoutController.parseProfileNames(output: rawList)
        #expect(names == ["macos.ovpn", "BackupVPN"])
    }

    @Test("Idempotent connect skips start command when already connected")
    func testIdempotentConnect() async throws {
        let executedCommands = LockIsolated<[[String]]>([])

        let mockRunner = MockCommandRunner { exe, args in
            executedCommands.withValue { $0.append([exe] + args) }
            if args.contains("status") {
                return ShellOutput(stdout: "Connected\n", stderr: "", exitCode: 0)
            }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }

        let controller = PassepartoutController(runner: mockRunner)
        try await controller.connect(profileName: "macos.ovpn")

        // Should have called status, but NOT start
        let cmds = executedCommands.value
        #expect(cmds.count == 1)
        #expect(cmds[0].contains("status"))
        #expect(!cmds.contains { $0.contains("start") })
    }

    @Test("Idempotent disconnect skips stop command when already disconnected")
    func testIdempotentDisconnect() async throws {
        let executedCommands = LockIsolated<[[String]]>([])

        let mockRunner = MockCommandRunner { exe, args in
            executedCommands.withValue { $0.append([exe] + args) }
            if args.contains("status") {
                return ShellOutput(stdout: "Disconnected\n", stderr: "", exitCode: 0)
            }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }

        let controller = PassepartoutController(runner: mockRunner)
        try await controller.disconnect(profileName: "macos.ovpn")

        // Should have called status, but NOT stop
        let cmds = executedCommands.value
        #expect(cmds.count == 1)
        #expect(cmds[0].contains("status"))
        #expect(!cmds.contains { $0.contains("stop") })
    }

    @Test("Connect and disconnect execute scutil start and stop when state changes")
    func testConnectAndDisconnectExecution() async throws {
        let executedCommands = LockIsolated<[[String]]>([])

        let mockRunner = MockCommandRunner { exe, args in
            executedCommands.withValue { $0.append([exe] + args) }
            if args.contains("status") {
                // If previous was start, report connected; if previous was stop, report disconnected
                let isNowConnected = executedCommands.value.contains { $0.contains("start") }
                let statusStr = isNowConnected ? "Connected\n" : "Disconnected\n"
                return ShellOutput(stdout: statusStr, stderr: "", exitCode: 0)
            }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }

        let controller = PassepartoutController(runner: mockRunner)

        // 1. Connect from disconnected state
        try await controller.connect(profileName: "macos.ovpn")
        #expect(executedCommands.value.contains { $0.contains("start") && $0.contains("macos.ovpn") })

        // 2. Disconnect from connected state
        try await controller.disconnect(profileName: "macos.ovpn")
        #expect(executedCommands.value.contains { $0.contains("stop") && $0.contains("macos.ovpn") })
    }

    @Test("Resolve profile name resolves 'macos' to 'macos.ovpn' when present in scutil list")
    func testProfileNameResolution() async {
        let rawList = """
        * (Disconnected) 09C7C32A-1DF8-4783-953E-E22F5972C95B VPN (com.algoritmico.ios.Passepartout) "macos.ovpn"
        """

        let mockRunner = MockCommandRunner { exe, args in
            if args.contains("list") {
                return ShellOutput(stdout: rawList, stderr: "", exitCode: 0)
            }
            return ShellOutput(stdout: "Disconnected", stderr: "", exitCode: 0)
        }

        let controller = PassepartoutController(runner: mockRunner)
        let resolved = await controller.resolveProfileName("macos")
        #expect(resolved == "macos.ovpn")
    }

    @Test("Command failure throws VPNControllerError.commandFailed")
    func testCommandFailureThrows() async {
        let mockRunner = MockCommandRunner { exe, args in
            if args.contains("start") {
                return ShellOutput(stdout: "", stderr: "Permission denied", exitCode: 1)
            }
            return ShellOutput(stdout: "Disconnected", stderr: "", exitCode: 0)
        }

        let controller = PassepartoutController(runner: mockRunner)
        await #expect(throws: VPNControllerError.self) {
            try await controller.connect(profileName: "macos.ovpn")
        }
    }

    @Test("Check status returns .error when scutil returns exit code 1 with 'No service' in stderr and empty stdout")
    func testCheckStatusReturnsErrorOnStderrNoService() async {
        let mockRunner = MockCommandRunner { exe, args in
            if args.contains("status") {
                return ShellOutput(stdout: "", stderr: "No service\n", exitCode: 1)
            }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }

        let controller = PassepartoutController(runner: mockRunner)
        let status = await controller.checkStatus(profileName: "nonexistent_profile")
        #expect(status == .error)
    }

    @Test("Check status returns .error when scutil returns non-zero exit code with unrecognized output")
    func testCheckStatusReturnsErrorOnNonZeroExitCode() async {
        let mockRunner = MockCommandRunner { exe, args in
            if args.contains("status") {
                return ShellOutput(stdout: "", stderr: "Internal scutil failure\n", exitCode: 2)
            }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }

        let controller = PassepartoutController(runner: mockRunner)
        let status = await controller.checkStatus(profileName: "faulty_profile")
        #expect(status == .error)
    }

    @Test("Live check status returns .error for nonexistent profile on macOS")
    func testLiveCheckStatusNonexistentProfile() async {
        let liveController = PassepartoutController()
        let status = await liveController.checkStatus(profileName: "netboost_nonexistent_profile_12345")
        #expect(status == .error)
    }
}

// Small thread-safe helper for test recording
private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        lock.withLock { _value }
    }

    func withValue<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLock {
            try body(&_value)
        }
    }
}
