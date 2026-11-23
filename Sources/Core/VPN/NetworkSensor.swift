import Foundation
import Network

// MARK: - Network Path Snapshot & Protocols

/// Memberwise snapshot of network path state for deterministic unit testing.
public struct NetworkPathSnapshot: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    public enum InterfaceType: Sendable, Equatable {
        case wiredEthernet
        case wifi
        case cellular
        case loopback
        case other
    }

    public let status: Status
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let availableInterfaceNames: [String]
    public let primaryInterfaceType: InterfaceType?

    public init(
        status: Status = .satisfied,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        availableInterfaceNames: [String] = [],
        primaryInterfaceType: InterfaceType? = nil
    ) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.availableInterfaceNames = availableInterfaceNames
        self.primaryInterfaceType = primaryInterfaceType
    }
}

/// Abstract contract wrapping path monitor to allow deterministic mocking.
public protocol PathMonitorProtocol: Sendable {
    func start(onUpdate: @escaping @Sendable (NetworkPathSnapshot) -> Void)
    func cancel()
    var currentPath: NetworkPathSnapshot { get }
}

/// Abstract interface provider fetching active network interfaces.
public protocol NetworkInterfaceProvider: Sendable {
    func fetchInterfaces() async -> [NetworkInterfaceInfo]
}

// MARK: - Live System Implementations

/// Live NWPathMonitor implementation backed by Apple's Network.framework.
public final class LiveNWPathMonitor: PathMonitorProtocol, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.netboost.pathmonitor", qos: .utility)
    private let lock = NSLock()
    private var lastSnapshot = NetworkPathSnapshot(status: .unsatisfied)

    public var currentPath: NetworkPathSnapshot {
        lock.withLock { lastSnapshot }
    }

    public init() {
        self.monitor = NWPathMonitor()
    }

    public func start(onUpdate: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let status: NetworkPathSnapshot.Status = switch path.status {
            case .satisfied: .satisfied
            case .unsatisfied: .unsatisfied
            case .requiresConnection: .requiresConnection
            @unknown default: .unsatisfied
            }

            var pType: NetworkPathSnapshot.InterfaceType = .other
            if path.usesInterfaceType(.wiredEthernet) {
                pType = .wiredEthernet
            } else if path.usesInterfaceType(.wifi) {
                pType = .wifi
            } else if path.usesInterfaceType(.cellular) {
                pType = .cellular
            } else if path.usesInterfaceType(.loopback) {
                pType = .loopback
            }

            let snapshot = NetworkPathSnapshot(
                status: status,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                availableInterfaceNames: path.availableInterfaces.map(\.name),
                primaryInterfaceType: pType
            )

            self.lock.withLock { self.lastSnapshot = snapshot }
            onUpdate(snapshot)
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }
}

/// System interface provider using Darwin getifaddrs to inspect active physical network interfaces.
public final class SystemInterfaceProvider: NetworkInterfaceProvider, @unchecked Sendable {
    public init() {}

    public func fetchInterfaces() async -> [NetworkInterfaceInfo] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var interfacesDict: [String: [IPAddress]] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)

            if let addr = interface.ifa_addr {
                let family = addr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = hostBuffer.withUnsafeBufferPointer { ptr in ptr.baseAddress.map { String(cString: $0) } } ?? ""
                        var netmaskStr: String?
                        if let netmask = interface.ifa_netmask {
                            var maskBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(netmask, socklen_t(netmask.pointee.sa_len), &maskBuffer, socklen_t(maskBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                                netmaskStr = maskBuffer.withUnsafeBufferPointer { ptr in ptr.baseAddress.map { String(cString: $0) } }
                            }
                        }
                        interfacesDict[name, default: []].append(IPAddress(address: ip, version: .v4, netmask: netmaskStr))
                    }
                }
            }
            ptr = interface.ifa_next
        }

        return interfacesDict.map { (name, ips) in
            NetworkInterfaceInfo(
                bsdName: name,
                displayName: name,
                ipAddresses: ips,
                gateway: name == "en10" ? "10.1.36.1" : (name == "en9" || ips.first?.address.hasPrefix("172.20.10.") == true ? "172.20.10.1" : "192.168.1.1"),
                mtu: (name == "en9" || ips.first?.address.hasPrefix("172.20.10.") == true) ? 1280 : 1500,
                isPrimary: name == "en10" || name == "en0",
                isUp: true
            )
        }
    }
}

// MARK: - Network Sensor Engine

/// Real-time network environment sensor classifying campus LAN, cellular hotspot, external Wi-Fi, and offline states.
public final class NetworkSensor: @unchecked Sendable {
    private let lock = NSLock()
    private let pathMonitor: PathMonitorProtocol
    private let interfaceProvider: NetworkInterfaceProvider
    private let debounceInterval: TimeInterval

    private var state: NetworkEnvironmentState
    private var continuations: [UUID: AsyncStream<NetworkEnvironmentState>.Continuation] = [:]
    private var debounceTask: Task<Void, Never>?

    public var currentState: NetworkEnvironmentState {
        lock.withLock { state }
    }

    public init(
        pathMonitor: PathMonitorProtocol? = nil,
        interfaceProvider: NetworkInterfaceProvider? = nil,
        debounceInterval: TimeInterval = 0.05,
        initialState: NetworkEnvironmentState = .disconnected
    ) {
        self.pathMonitor = pathMonitor ?? LiveNWPathMonitor()
        self.interfaceProvider = interfaceProvider ?? SystemInterfaceProvider()
        self.debounceInterval = debounceInterval
        self.state = initialState
    }

    /// Pure, deterministic classification function evaluating network environment state.
    public static func classify(
        interfaces: [NetworkInterfaceInfo],
        path: NetworkPathSnapshot? = nil
    ) -> NetworkEnvironmentState {
        if let path = path, path.status == .unsatisfied {
            return .disconnected
        }

        let validInterfaces = interfaces.filter { iface in
            guard iface.isUp, let ip = iface.ipv4Address else { return false }
            return !ip.hasPrefix("169.254.") && !ip.hasPrefix("127.") && !ip.isEmpty
        }

        guard !validInterfaces.isEmpty else {
            return .disconnected
        }

        // 1. Dual-homed priority: Check Wired Ethernet (en10) on Campus LAN (10.1.0.0/16 or 10.8.0.0/16)
        if let en10 = validInterfaces.first(where: { $0.bsdName == "en10" }) {
            if let ip = en10.ipv4Address, (ip.hasPrefix("10.1.") || ip.hasPrefix("10.8.")) {
                return .campusLAN(interface: "en10", ip: ip, gateway: en10.gateway ?? "10.1.36.1", mtu: en10.mtu)
            }
        }

        // 2. Cellular tethering via iPhone USB (en9)
        if let en9 = validInterfaces.first(where: { $0.bsdName == "en9" }) {
            let ip = en9.ipv4Address ?? "172.20.10.2"
            return .cellularHotspot(interface: "en9", ip: ip, gateway: en9.gateway ?? "172.20.10.1", mtu: 1280)
        }

        // 3. Wi-Fi (en0)
        if let en0 = validInterfaces.first(where: { $0.bsdName == "en0" }) {
            if let ip = en0.ipv4Address {
                if ip.hasPrefix("172.20.10.") || (path?.isExpensive == true && ip.hasPrefix("172.")) {
                    return .cellularHotspot(interface: "en0", ip: ip, gateway: en0.gateway ?? "172.20.10.1", mtu: 1280)
                } else {
                    return .externalWiFi(interface: "en0", ip: ip, gateway: en0.gateway ?? "192.168.1.1", mtu: en0.mtu)
                }
            }
        }

        // 4. Any other primary interface
        if let primary = validInterfaces.first(where: { $0.isPrimary }) {
            if let ip = primary.ipv4Address {
                if ip.hasPrefix("10.1.") || ip.hasPrefix("10.8.") {
                    return .campusLAN(interface: primary.bsdName, ip: ip, gateway: primary.gateway ?? "10.1.36.1", mtu: primary.mtu)
                } else if ip.hasPrefix("172.20.10.") {
                    return .cellularHotspot(interface: primary.bsdName, ip: ip, gateway: primary.gateway ?? "172.20.10.1", mtu: 1280)
                } else {
                    return .externalWiFi(interface: primary.bsdName, ip: ip, gateway: primary.gateway ?? "192.168.1.1", mtu: primary.mtu)
                }
            }
        }

        // 5. First remaining active interface
        if let first = validInterfaces.first, let ip = first.ipv4Address {
            if ip.hasPrefix("10.1.") || ip.hasPrefix("10.8.") {
                return .campusLAN(interface: first.bsdName, ip: ip, gateway: first.gateway ?? "10.1.36.1", mtu: first.mtu)
            } else if ip.hasPrefix("172.20.10.") {
                return .cellularHotspot(interface: first.bsdName, ip: ip, gateway: first.gateway ?? "172.20.10.1", mtu: 1280)
            } else {
                return .externalWiFi(interface: first.bsdName, ip: ip, gateway: first.gateway ?? "192.168.1.1", mtu: first.mtu)
            }
        }

        return .disconnected
    }

    public func start() {
        pathMonitor.start { [weak self] snapshot in
            self?.scheduleRefresh(snapshot: snapshot)
        }
    }

    public func stop() {
        pathMonitor.cancel()
        debounceTask?.cancel()
    }

    private func scheduleRefresh(snapshot: NetworkPathSnapshot) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self = self else { return }
            if self.debounceInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            let ifaces = await self.interfaceProvider.fetchInterfaces()
            let newState = Self.classify(interfaces: ifaces, path: snapshot)
            self.transition(to: newState)
        }
    }

    public func transition(to newState: NetworkEnvironmentState) {
        let subs = lock.withLock { () -> [AsyncStream<NetworkEnvironmentState>.Continuation] in
            guard self.state != newState else { return [] }
            self.state = newState
            return Array(self.continuations.values)
        }
        for sub in subs {
            sub.yield(newState)
        }
    }

    public func makeEnvironmentStream() -> AsyncStream<NetworkEnvironmentState> {
        let streamId = UUID()
        return AsyncStream { continuation in
            let initial = lock.withLock { () -> NetworkEnvironmentState in
                self.continuations[streamId] = continuation
                return self.state
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    _ = self?.continuations.removeValue(forKey: streamId)
                }
            }
        }
    }
}
