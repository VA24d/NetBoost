import Foundation

// MARK: - VPN Rule Event

/// Event emitted when a VPN automation rule is evaluated and executed.
public struct VPNRuleEvent: Sendable, Equatable {
    public let timestamp: Date
    public let triggeredAction: VPNAction
    public let environment: NetworkEnvironmentState
    public let description: String

    public init(triggeredAction: VPNAction, environment: NetworkEnvironmentState, description: String, timestamp: Date = Date()) {
        self.timestamp = timestamp
        self.triggeredAction = triggeredAction
        self.environment = environment
        self.description = description
    }
}

// MARK: - Conflict Checker Signature

public typealias ConflictChecker = @Sendable (VPNProfileInfo?, NetworkEnvironmentState) -> [String]

// MARK: - VPN Rule Engine

/// Context-aware state machine coordinating NetworkSensor, RouteConflictDetector, and PassepartoutController.
public final class VPNRuleEngine: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var policy: VPNRulePolicy
    private let vpnController: VPNControllerProtocol
    private let conflictChecker: ConflictChecker

    private var isManualOverrideActive: Bool = false
    public private(set) var lastAction: VPNAction = .none
    public private(set) var transitionNotifications: [String] = []
    private var eventContinuations: [UUID: AsyncStream<VPNRuleEvent>.Continuation] = [:]
    private var observationTask: Task<Void, Never>?

    public var manualOverride: Bool {
        get { lock.withLock { isManualOverrideActive } }
        set { lock.withLock { isManualOverrideActive = newValue } }
    }

    public init(
        policy: VPNRulePolicy = VPNRulePolicy(),
        vpnController: VPNControllerProtocol,
        conflictChecker: ConflictChecker? = nil
    ) {
        self.policy = policy
        self.vpnController = vpnController
        self.conflictChecker = conflictChecker ?? { profile, _ in
            guard let profile = profile else { return [] }
            return RouteConflictDetector.detectConflicts(profile: profile)
        }
        self.isManualOverrideActive = policy.manualOverrideActive
    }

    public func setManualOverride(active: Bool) {
        lock.withLock {
            isManualOverrideActive = active
            policy.manualOverrideActive = active
        }
    }

    public func updatePolicy(_ newPolicy: VPNRulePolicy) {
        lock.withLock {
            policy = newPolicy
            isManualOverrideActive = newPolicy.manualOverrideActive
        }
    }

    /// Evaluates the network environment state and calculates the resulting VPNAction.
    public func evaluate(state: NetworkEnvironmentState, activeProfile: VPNProfileInfo? = nil) -> VPNAction {
        lock.withLock {
            if isManualOverrideActive {
                return .none
            }

            switch state {
            case .campusLAN:
                if policy.promptBeforeDisconnect {
                    transitionNotifications.append("Prompt required before disconnecting VPN on Campus LAN")
                    lastAction = .none
                    return .none
                }
                lastAction = .disconnect(profile: policy.targetProfileName)
                transitionNotifications.append("Disconnected VPN: On Campus LAN")
                return lastAction

            case .cellularHotspot, .externalWiFi:
                guard policy.autoConnectEnabled else {
                    return .none
                }

                // Check for route conflicts
                let conflicts = conflictChecker(activeProfile, state)
                if !conflicts.isEmpty && !policy.conflictOverride {
                    let reason = conflicts.joined(separator: "; ")
                    lastAction = .quarantine(profile: policy.targetProfileName, reason: reason)
                    transitionNotifications.append("Quarantined VPN: Route Conflict Detected - \(reason)")
                    return lastAction
                }

                lastAction = .connect(profile: policy.targetProfileName)
                transitionNotifications.append("Connected VPN: On External/Hotspot Network")
                return lastAction

            case .disconnected:
                lastAction = .none
                return .none
            }
        }
    }

    /// Executes the evaluated VPNAction against the system VPN controller with retry and exponential backoff.
    public func execute(action: VPNAction, state: NetworkEnvironmentState = .disconnected) async throws {
        switch action {
        case .disconnect(let profile):
            try await vpnController.disconnect(profileName: profile)
            broadcast(event: VPNRuleEvent(triggeredAction: action, environment: state, description: "Disengaged \(profile)"))

        case .connect(let profile):
            var attempt = 0
            var success = false
            var lastError: Error?

            while attempt < policy.maxRetries && !success {
                try Task.checkCancellation()
                attempt += 1
                do {
                    try await vpnController.connect(profileName: profile)
                    success = true
                    broadcast(event: VPNRuleEvent(triggeredAction: action, environment: state, description: "Engaged \(profile)"))
                } catch {
                    lastError = error
                    if attempt >= policy.maxRetries {
                        break
                    }
                    let delay = policy.baseBackoffDelay * pow(2.0, Double(attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            if !success, let err = lastError {
                throw err
            }

        case .quarantine(let profile, let reason):
            broadcast(event: VPNRuleEvent(triggeredAction: action, environment: state, description: "Quarantined \(profile): \(reason)"))

        case .none:
            break
        }
    }

    /// Starts observing a NetworkSensor's environment stream to trigger automated actions.
    public func startObserving(sensor: NetworkSensor, activeProfile: VPNProfileInfo? = nil) {
        let task = Task { [weak self] in
            guard let self = self else { return }
            for await env in sensor.makeEnvironmentStream() {
                guard !Task.isCancelled else { break }
                let action = self.evaluate(state: env, activeProfile: activeProfile)
                do {
                    try await self.execute(action: action, state: env)
                } catch is CancellationError {
                    break
                } catch {
                    self.lock.withLock {
                        self.transitionNotifications.append("VPN action failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            let prev = observationTask
            observationTask = task
            return prev
        }
        previous?.cancel()
    }

    /// Stops observing the network sensor.
    public func stopObserving() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let prev = observationTask
            observationTask = nil
            return prev
        }
        task?.cancel()
    }

    private func broadcast(event: VPNRuleEvent) {
        let subs = lock.withLock { Array(eventContinuations.values) }
        for sub in subs {
            sub.yield(event)
        }
    }

    /// Creates an AsyncStream for subscribing to VPNRuleEvents.
    public func makeEventStream() -> AsyncStream<VPNRuleEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { eventContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.eventContinuations.removeValue(forKey: id) }
            }
        }
    }
}
