import Foundation

/// Inspects and manages macOS network service priority order via networksetup.
public final class ServiceOrderManager: Sendable {

    public struct ServiceEntry: Codable, Sendable, Equatable, Identifiable {
        public var id: Int { order }
        public let order: Int
        public let name: String
        public let device: String

        public init(order: Int, name: String, device: String) {
            self.order = order
            self.name = name
            self.device = device
        }
    }

    public init() {}

    /// Parses output from `networksetup -listnetworkserviceorder`.
    public static func parseServiceOrder(output: String) -> [ServiceEntry] {
        var entries: [ServiceEntry] = []
        let lines = output.components(separatedBy: .newlines)
        var currentOrder: Int?
        var currentName: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("(Hardware Port:") {
                if let devRange = trimmed.range(of: "Device: ") {
                    let devPart = String(trimmed[devRange.upperBound...])
                        .replacingOccurrences(of: ")", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let order = currentOrder, let name = currentName {
                        entries.append(ServiceEntry(order: order, name: name, device: devPart))
                    }
                }
                currentOrder = nil
                currentName = nil
            } else if trimmed.hasPrefix("(") && trimmed.contains(")") {
                if let endParen = trimmed.firstIndex(of: ")") {
                    let numStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<endParen])
                    if let num = Int(numStr) {
                        currentOrder = num
                        currentName = String(trimmed[trimmed.index(after: endParen)...]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        return entries
    }

    /// Generates command arguments for `networksetup -ordernetworkservices`.
    public static func makeOrderNetworkServicesCommand(orderedServices: [String]) -> [String] {
        ["/usr/sbin/networksetup", "-ordernetworkservices"] + orderedServices
    }

    /// Queries the system and returns currently active network services ordered by priority.
    public func getServiceOrder() async throws -> [ServiceEntry] {
        let output = try await ShellCommand.run("/usr/sbin/networksetup", arguments: ["-listnetworkserviceorder"])
        guard output.succeeded else { return [] }
        return Self.parseServiceOrder(output: output.stdout)
    }

    /// Applies a new service priority order.
    public func reorderServices(orderedServices: [String]) async throws {
        let cmd = Self.makeOrderNetworkServicesCommand(orderedServices: orderedServices)
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "order-services", arguments: orderedServices)
            }
        }
    }

    /// Sorts an existing list of network services to prioritize wired Ethernet over Wi-Fi.
    public func prioritizeEthernet(services: [String]) -> [String] {
        var sorted = services
        sorted.sort { s1, s2 in
            let isEth1 = s1.contains("LAN") || s1.contains("Ethernet")
            let isEth2 = s2.contains("LAN") || s2.contains("Ethernet")
            if isEth1 && !isEth2 { return true }
            if !isEth1 && isEth2 { return false }

            let isWiFi1 = s1.contains("Wi-Fi") || s1.contains("AirPort")
            let isWiFi2 = s2.contains("Wi-Fi") || s2.contains("AirPort")
            if isWiFi1 && !isWiFi2 { return true }
            if !isWiFi1 && isWiFi2 { return false }

            return s1 < s2
        }
        return sorted
    }
}
