import Foundation
@_exported import NetBoostCore

// NetworkEnvironmentState is canonically defined in NetBoostCore/VPNModels.swift
public typealias NetworkEnvironmentState = NetBoostCore.NetworkEnvironmentState

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
