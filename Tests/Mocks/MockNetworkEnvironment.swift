import Foundation

public enum NetworkEnvironmentState: Sendable, Equatable, Hashable {
    case campusLAN(interface: String, ip: String, gateway: String, mtu: Int)
    case cellularHotspot(interface: String, ip: String, gateway: String, mtu: Int)
    case externalWiFi(interface: String, ip: String, gateway: String, mtu: Int)
    case disconnected

    public static var defaultCampusLAN: Self {
        .campusLAN(interface: "en10", ip: "10.1.36.52", gateway: "10.1.36.1", mtu: 1500)
    }

    public static var defaultCellularHotspot: Self {
        .cellularHotspot(interface: "en0", ip: "172.20.10.2", gateway: "172.20.10.1", mtu: 1280)
    }

    public static var defaultExternalWiFi: Self {
        .externalWiFi(interface: "en0", ip: "192.168.1.100", gateway: "192.168.1.1", mtu: 1500)
    }

    public var isCampusLAN: Bool {
        if case .campusLAN = self { return true }
        return false
    }

    public var isCellular: Bool {
        if case .cellularHotspot = self { return true }
        return false
    }

    public var isConnected: Bool {
        if case .disconnected = self { return false }
        return true
    }

    public var primaryInterface: String? {
        switch self {
        case .campusLAN(let iface, _, _, _): return iface
        case .cellularHotspot(let iface, _, _, _): return iface
        case .externalWiFi(let iface, _, _, _): return iface
        case .disconnected: return nil
        }
    }

    public var mtu: Int {
        switch self {
        case .campusLAN(_, _, _, let m): return m
        case .cellularHotspot(_, _, _, let m): return m
        case .externalWiFi(_, _, _, let m): return m
        case .disconnected: return 0
        }
    }
}

public final class MockNetworkEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var state: NetworkEnvironmentState
    private var history: [(state: NetworkEnvironmentState, timestamp: Date)] = []
    private var continuations: [UUID: AsyncStream<NetworkEnvironmentState>.Continuation] = [:]

    public var currentState: NetworkEnvironmentState {
        lock.withLock { state }
    }

    public var transitionHistory: [(state: NetworkEnvironmentState, timestamp: Date)] {
        lock.withLock { history }
    }

    public init(initialState: NetworkEnvironmentState = .defaultCampusLAN) {
        self.state = initialState
        self.history.append((state: initialState, timestamp: Date()))
    }

    /// Triggers a simulated transition to a new network environment state.
    public func transition(to newState: NetworkEnvironmentState) {
        let activeContinuations = lock.withLock { () -> [AsyncStream<NetworkEnvironmentState>.Continuation] in
            self.state = newState
            self.history.append((state: newState, timestamp: Date()))
            return Array(continuations.values)
        }

        for continuation in activeContinuations {
            continuation.yield(newState)
        }
    }

    /// Simulates a rapid sequence of state transitions (flapping) with delay between changes.
    public func simulateFlapping(states: [NetworkEnvironmentState], interval: TimeInterval = 0.05) async {
        for s in states {
            transition(to: s)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Creates an AsyncStream delivering network environment updates.
    public func makeStateStream() -> AsyncStream<NetworkEnvironmentState> {
        let streamId = UUID()
        return AsyncStream { continuation in
            let current = lock.withLock { () -> NetworkEnvironmentState in
                continuations[streamId] = continuation
                return self.state
            }

            // Deliver current state immediately
            continuation.yield(current)

            continuation.onTermination = { [weak self] _ in
                guard let self = self else { return }
                self.lock.withLock {
                    _ = self.continuations.removeValue(forKey: streamId)
                }
            }
        }
    }

    public func clearHistory() {
        lock.withLock {
            history.removeAll()
            history.append((state: state, timestamp: Date()))
        }
    }
}
