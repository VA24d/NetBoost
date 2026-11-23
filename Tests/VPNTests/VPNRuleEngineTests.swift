import Testing
import Foundation
@testable import NetBoostCore

@Suite("VPN Subsystem: VPN Rule Engine Automation Unit Tests", .tags(.tier1, .m3_vpn))
struct VPNRuleEngineTests {

    final class MockVPNController: VPNControllerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        var connectCallCount: Int = 0
        var disconnectCallCount: Int = 0
        var shouldFailConnect: Bool = false
        var failureAttemptsRemaining: Int = 0
        var lastProfileConnected: String?
        var lastProfileDisconnected: String?
        var status: VPNStatus = .disconnected

        func checkStatus(profileName: String) async -> VPNStatus {
            lock.withLock { status }
        }

        func connect(profileName: String) async throws {
            try lock.withLock {
                connectCallCount += 1
                lastProfileConnected = profileName
                if shouldFailConnect {
                    throw VPNControllerError.commandFailed(exitCode: 1, message: "Connection refused")
                }
                if failureAttemptsRemaining > 0 {
                    failureAttemptsRemaining -= 1
                    throw VPNControllerError.commandFailed(exitCode: 1, message: "Transient error")
                }
                status = .connected
            }
        }

        func disconnect(profileName: String) async throws {
            lock.withLock {
                disconnectCallCount += 1
                lastProfileDisconnected = profileName
                status = .disconnected
            }
        }

        func parseProfile(url: URL) throws -> VPNProfileInfo {
            VPNProfileInfo(name: url.lastPathComponent, serverAddress: "vpn.test")
        }

        func detectConflicts(profile: VPNProfileInfo, currentLAN: String) -> [String] {
            []
        }
    }

    @Test("Transition into campusLAN evaluates to disconnect(profile: 'macos.ovpn')")
    func testTransitionCampusLAN() {
        let mockController = MockVPNController()
        let engine = VPNRuleEngine(vpnController: mockController)

        let action = engine.evaluate(state: .defaultCampusLAN)
        #expect(action == .disconnect(profile: "macos.ovpn"))
        #expect(engine.lastAction == .disconnect(profile: "macos.ovpn"))
        #expect(engine.transitionNotifications.contains { $0.contains("Disconnected VPN: On Campus LAN") })
    }

    @Test("Transition into cellularHotspot evaluates to connect(profile: 'macos.ovpn')")
    func testTransitionCellularHotspot() {
        let mockController = MockVPNController()
        let engine = VPNRuleEngine(vpnController: mockController)

        let action = engine.evaluate(state: .defaultCellularHotspot)
        #expect(action == .connect(profile: "macos.ovpn"))
        #expect(engine.lastAction == .connect(profile: "macos.ovpn"))
        #expect(engine.transitionNotifications.contains { $0.contains("Connected VPN: On External/Hotspot Network") })
    }

    @Test("Transition into externalWiFi evaluates to connect(profile: 'macos.ovpn')")
    func testTransitionExternalWiFi() {
        let mockController = MockVPNController()
        let engine = VPNRuleEngine(vpnController: mockController)

        let action = engine.evaluate(state: .defaultExternalWiFi)
        #expect(action == .connect(profile: "macos.ovpn"))
    }

    @Test("Transition into disconnected evaluates to none")
    func testTransitionDisconnected() {
        let mockController = MockVPNController()
        let engine = VPNRuleEngine(vpnController: mockController)

        let action = engine.evaluate(state: .disconnected)
        #expect(action == .none)
    }

    @Test("Manual override suppresses automatic actions")
    func testManualOverrideSuppression() {
        let mockController = MockVPNController()
        let engine = VPNRuleEngine(vpnController: mockController)

        engine.setManualOverride(active: true)
        #expect(engine.manualOverride == true)

        let actionLAN = engine.evaluate(state: .defaultCampusLAN)
        #expect(actionLAN == .none)

        let actionHotspot = engine.evaluate(state: .defaultCellularHotspot)
        #expect(actionHotspot == .none)
    }

    @Test("Policy autoConnectEnabled = false suppresses auto-connect on hotspot")
    func testAutoConnectDisabled() {
        let mockController = MockVPNController()
        var policy = VPNRulePolicy()
        policy.autoConnectEnabled = false

        let engine = VPNRuleEngine(policy: policy, vpnController: mockController)
        let action = engine.evaluate(state: .defaultCellularHotspot)
        #expect(action == .none)
    }

    @Test("Route conflict quarantine triggers quarantine action when conflict detected")
    func testRouteConflictQuarantine() {
        let mockController = MockVPNController()
        let conflictingProfile = VPNProfileInfo(
            name: "iiit_split.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0")],
            isCampusSplit: true
        )

        let engine = VPNRuleEngine(
            vpnController: mockController,
            conflictChecker: { profile, _ in
                guard let p = profile, p.routes.contains(where: { $0.destinationSubnet == "10.1.0.0" }) else { return [] }
                return ["Route 10.1.0.0/16 collides with local campus switch gateway"]
            }
        )

        let action = engine.evaluate(state: .defaultCellularHotspot, activeProfile: conflictingProfile)
        guard case .quarantine(let profile, let reason) = action else {
            Issue.record("Expected quarantine action, got \(action)")
            return
        }
        #expect(profile == "macos.ovpn")
        #expect(reason.contains("10.1.0.0/16"))
        #expect(engine.transitionNotifications.contains { $0.contains("Quarantined VPN") })
    }

    @Test("Conflict override policy flag allows connection despite route conflict")
    func testConflictOverridePolicy() {
        let mockController = MockVPNController()
        var policy = VPNRulePolicy()
        policy.conflictOverride = true

        let conflictingProfile = VPNProfileInfo(
            name: "iiit_split.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            routes: [VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0")],
            isCampusSplit: true
        )

        let engine = VPNRuleEngine(
            policy: policy,
            vpnController: mockController,
            conflictChecker: { _, _ in ["Collision detected"] }
        )

        let action = engine.evaluate(state: .defaultCellularHotspot, activeProfile: conflictingProfile)
        #expect(action == .connect(profile: "macos.ovpn"))
    }

    @Test("Execute connect retries with backoff up to maxRetries on failure")
    func testRetryWithBackoff() async throws {
        let mockController = MockVPNController()
        mockController.failureAttemptsRemaining = 2 // Fails twice, succeeds on 3rd

        var policy = VPNRulePolicy()
        policy.maxRetries = 3
        policy.baseBackoffDelay = 0.01 // Fast delay for test

        let engine = VPNRuleEngine(policy: policy, vpnController: mockController)
        try await engine.execute(action: .connect(profile: "macos.ovpn"))

        #expect(mockController.connectCallCount == 3)
        #expect(mockController.lastProfileConnected == "macos.ovpn")
    }

    @Test("Event stream receives broadcast when action executes")
    func testEventStreamDelivery() async throws {
        let mockController = MockVPNController()
        let engine = VPNRuleEngine(vpnController: mockController)

        let stream = engine.makeEventStream()
        var iterator = stream.makeAsyncIterator()

        let disconnectAction = VPNAction.disconnect(profile: "macos.ovpn")
        try await engine.execute(action: disconnectAction, state: .defaultCampusLAN)

        let event = await iterator.next()
        #expect(event?.triggeredAction == disconnectAction)
        #expect(event?.environment == .defaultCampusLAN)
    }

    @Test("Observe NetworkSensor automatically drives state transitions")
    func testObservingNetworkSensor() async throws {
        let mockController = MockVPNController()
        let engine = VPNRuleEngine(vpnController: mockController)

        let sensor = NetworkSensor(debounceInterval: 0.01, initialState: .disconnected)
        engine.startObserving(sensor: sensor)
        defer { engine.stopObserving() }

        // Transition sensor to Campus LAN
        sensor.transition(to: .defaultCampusLAN)

        // Wait brief moment for async execution
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(mockController.disconnectCallCount >= 1)
        #expect(mockController.lastProfileDisconnected == "macos.ovpn")
    }

    @Test("Policy promptBeforeDisconnect = true suppresses auto-disconnect on campus LAN and returns none")
    func testPromptBeforeDisconnectSuppressesDisconnect() {
        let mockController = MockVPNController()
        var policy = VPNRulePolicy()
        policy.promptBeforeDisconnect = true

        let engine = VPNRuleEngine(policy: policy, vpnController: mockController)
        let action = engine.evaluate(state: .defaultCampusLAN)
        #expect(action == .none)
        #expect(engine.lastAction == .none)
        #expect(engine.transitionNotifications.contains { $0.contains("Prompt required before disconnecting VPN on Campus LAN") })
    }

    @Test("Dynamic policy update changing promptBeforeDisconnect toggles campus LAN evaluation behavior")
    func testDynamicPolicyUpdatePromptBeforeDisconnect() {
        let mockController = MockVPNController()
        var policy = VPNRulePolicy()
        policy.promptBeforeDisconnect = true

        let engine = VPNRuleEngine(policy: policy, vpnController: mockController)
        #expect(engine.evaluate(state: .defaultCampusLAN) == .none)

        policy.promptBeforeDisconnect = false
        engine.updatePolicy(policy)
        #expect(engine.evaluate(state: .defaultCampusLAN) == .disconnect(profile: "macos.ovpn"))
    }

    @Test("Policy promptBeforeDisconnect = true does not interfere with cellular hotspot auto-connect")
    func testPromptBeforeDisconnectAllowsHotspotConnect() {
        let mockController = MockVPNController()
        var policy = VPNRulePolicy()
        policy.promptBeforeDisconnect = true

        let engine = VPNRuleEngine(policy: policy, vpnController: mockController)
        let action = engine.evaluate(state: .defaultCellularHotspot)
        #expect(action == .connect(profile: "macos.ovpn"))
    }
}
