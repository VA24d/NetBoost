import Foundation
@testable import NetBoostCore

public struct RecordedCommand: Sendable, Equatable {
    public let id: UUID
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]?
    public let isElevated: Bool
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        isElevated: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.isElevated = isElevated
        self.timestamp = timestamp
    }

    public var fullCommandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public struct CommandStub: @unchecked Sendable {
    public let matcher: @Sendable (RecordedCommand) -> Bool
    public let handler: @Sendable (RecordedCommand) throws -> ShellOutput

    public init(
        matcher: @escaping @Sendable (RecordedCommand) -> Bool,
        handler: @escaping @Sendable (RecordedCommand) throws -> ShellOutput
    ) {
        self.matcher = matcher
        self.handler = handler
    }
}

public final class MockProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [RecordedCommand] = []
    private var stubs: [CommandStub] = []

    public var recordedCommands: [RecordedCommand] {
        lock.withLock { commands }
    }

    public init() {
        registerDefaultStubs()
    }

    public func clearHistory() {
        lock.withLock { commands.removeAll() }
    }

    public func clearCustomStubs() {
        lock.withLock {
            stubs.removeAll()
            registerDefaultStubs()
        }
    }

    public func didExecute(commandContaining substring: String) -> Bool {
        lock.withLock {
            commands.contains { $0.fullCommandLine.contains(substring) }
        }
    }

    public func executionCount(commandContaining substring: String) -> Int {
        lock.withLock {
            commands.filter { $0.fullCommandLine.contains(substring) }.count
        }
    }

    public func lastExecutedCommand() -> RecordedCommand? {
        lock.withLock { commands.last }
    }

    // MARK: - Stub Registration

    public func registerStub(
        commandContaining substring: String,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0
    ) {
        let stub = CommandStub(
            matcher: { $0.fullCommandLine.contains(substring) },
            handler: { _ in ShellOutput(stdout: stdout, stderr: stderr, exitCode: exitCode) }
        )
        lock.withLock {
            stubs.insert(stub, at: 0)
        }
    }

    public func registerStub(
        matcher: @escaping @Sendable (RecordedCommand) -> Bool,
        handler: @escaping @Sendable (RecordedCommand) throws -> ShellOutput
    ) {
        let stub = CommandStub(matcher: matcher, handler: handler)
        lock.withLock {
            stubs.insert(stub, at: 0)
        }
    }

    // MARK: - Execution

    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        isElevated: Bool = false
    ) async throws -> ShellOutput {
        let cmd = RecordedCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            isElevated: isElevated,
            timestamp: Date()
        )

        let activeStubs = lock.withLock { () -> [CommandStub] in
            commands.append(cmd)
            return self.stubs
        }

        for stub in activeStubs {
            if stub.matcher(cmd) {
                return try stub.handler(cmd)
            }
        }

        // Default fallback for unstubbed commands
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
    }

    // MARK: - Default Intelligent Stubs

    private func registerDefaultStubs() {
        // networksetup -getMTU
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("networksetup") && $0.arguments.contains("-getMTU") },
            handler: { _ in
                return ShellOutput(stdout: "Active MTU: 1500 (Current Setting: 1500)\n", stderr: "", exitCode: 0)
            }
        ))

        // networksetup -setMTU
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("networksetup") && $0.arguments.contains("-setMTU") },
            handler: { _ in ShellOutput(stdout: "Setting MTU succeeded\n", stderr: "", exitCode: 0) }
        ))

        // networksetup -listnetworkserviceorder
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("-listnetworkserviceorder") },
            handler: { _ in
                let output = """
                An asterisk (*) denotes that a network service is disabled.
                (1) USB 10/100 LAN
                (Hardware Port: USB 10/100 LAN, Device: en10)

                (2) Wi-Fi
                (Hardware Port: Wi-Fi, Device: en0)

                (3) iPhone USB
                (Hardware Port: iPhone USB, Device: en9)
                """
                return ShellOutput(stdout: output, stderr: "", exitCode: 0)
            }
        ))

        // networksetup -ordernetworkservices
        stubs.append(CommandStub(
            matcher: { $0.arguments.contains("-ordernetworkservices") },
            handler: { _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
        ))

        // networksetup -setdnsservers / -getdnsservers
        stubs.append(CommandStub(
            matcher: { $0.arguments.contains("-getdnsservers") },
            handler: { _ in ShellOutput(stdout: "10.4.20.21\n10.4.20.222\n", stderr: "", exitCode: 0) }
        ))
        stubs.append(CommandStub(
            matcher: { $0.arguments.contains("-setdnsservers") },
            handler: { _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
        ))

        // dscacheutil -flushcache
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("dscacheutil") && $0.arguments.contains("-flushcache") },
            handler: { _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
        ))

        // killall -HUP mDNSResponder
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("mDNSResponder") },
            handler: { _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
        ))

        // arp -an
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("arp") && $0.arguments.contains("-an") },
            handler: { _ in
                let table = """
                ? (10.1.36.1) at 0:11:22:33:44:55 on en10 ifscope [ethernet]
                ? (10.8.0.80) at 0:aa:bb:cc:dd:ee on en10 ifscope [ethernet]
                ? (192.168.2.1) at 0:12:34:56:78:9a on bridge0 ifscope [ethernet]
                ? (192.168.2.15) at a4:c3:f0:12:34:56 on bridge0 ifscope [ethernet]
                """
                return ShellOutput(stdout: table, stderr: "", exitCode: 0)
            }
        ))

        // arp -d
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("arp") && $0.arguments.contains("-d") },
            handler: { _ in ShellOutput(stdout: "10.1.36.1 (10.1.36.1) deleted\n", stderr: "", exitCode: 0) }
        ))

        // scutil --nc status
        stubs.append(CommandStub(
            matcher: { $0.arguments.contains("--nc") && $0.arguments.contains("status") },
            handler: { _ in ShellOutput(stdout: "Disconnected\n", stderr: "", exitCode: 0) }
        ))

        // scutil --nc start / stop / list
        stubs.append(CommandStub(
            matcher: { $0.arguments.contains("--nc") && ($0.arguments.contains("start") || $0.arguments.contains("stop")) },
            handler: { _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
        ))
        stubs.append(CommandStub(
            matcher: { $0.arguments.contains("--nc") && $0.arguments.contains("list") },
            handler: { _ in
                let listOutput = """
                Available network connection services in the current set:
                   (Disconnected)   A1B2C3D4-E5F6-7890-ABCD-EF1234567890 VPN         "macos.ovpn"  [VPN:OpenVPN]
                """
                return ShellOutput(stdout: listOutput, stderr: "", exitCode: 0)
            }
        ))

        // sysctl net.inet.ip.forwarding
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("sysctl") && $0.arguments.contains("net.inet.ip.forwarding") },
            handler: { _ in ShellOutput(stdout: "net.inet.ip.forwarding: 1\n", stderr: "", exitCode: 0) }
        ))

        // pfctl -a netboost
        stubs.append(CommandStub(
            matcher: { $0.fullCommandLine.contains("pfctl") },
            handler: { _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
        ))
    }
}
