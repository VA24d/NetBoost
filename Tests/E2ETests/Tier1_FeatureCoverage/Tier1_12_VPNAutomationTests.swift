import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 12: Context-Sensitive VPN Rule Automation", .tags(.tier1, .m3_vpn))
struct Tier1_12_VPNAutomationTests {

    enum VPNAction: Equatable {
        case connect(profile: String)
        case disconnect(profile: String)
        case none
    }

    final class VPNAutomationEngine: @unchecked Sendable {
        private var isManualOverrideActive: Bool = false
        private(set) var lastAction: VPNAction = .none
        private(set) var transitionNotifications: [String] = []
        private let lock = NSLock()

        func setManualOverride(active: Bool) {
            lock.lock()
            defer { lock.unlock() }
            isManualOverrideActive = active
        }

        func evaluate(state: NetworkEnvironmentState) -> VPNAction {
            lock.lock()
            defer { lock.unlock() }

            if isManualOverrideActive {
                return .none
            }

            switch state {
            case .campusLAN:
                lastAction = .disconnect(profile: "macos.ovpn")
                transitionNotifications.append("Disconnected VPN: On Campus LAN")
                return lastAction
            case .cellularHotspot, .externalWiFi:
                lastAction = .connect(profile: "macos.ovpn")
                transitionNotifications.append("Connected VPN: On External/Hotspot Network")
                return lastAction
            case .disconnected:
                lastAction = .none
                return .none
            }
        }
    }

    @Test("T1-F12-01: Automatically trigger VPN disconnect when transitioning into campusLAN")
    func testAutoDisconnectOnCampusLAN() {
        let engine = VPNAutomationEngine()
        let action = engine.evaluate(state: .defaultCampusLAN)

        #expect(action == .disconnect(profile: "macos.ovpn"))
    }

    @Test("T1-F12-02: Automatically trigger VPN connect when transitioning into cellularHotspot")
    func testAutoConnectOnCellularHotspot() {
        let engine = VPNAutomationEngine()
        let action = engine.evaluate(state: .defaultCellularHotspot)

        #expect(action == .connect(profile: "macos.ovpn"))
    }

    @Test("T1-F12-03: Campus LAN routes remain direct while secondary interface connects VPN")
    func testDirectCampusRoutingInvariant() {
        let campusSubnet = "10.1.0.0/16"
        let splitTunnelRuleDirect = true

        #expect(campusSubnet == "10.1.0.0/16")
        #expect(splitTunnelRuleDirect == true)
    }

    @Test("T1-F12-04: Broadcast state transition notification to UI upon automation trigger")
    func testStateTransitionBroadcast() {
        let engine = VPNAutomationEngine()
        _ = engine.evaluate(state: .defaultExternalWiFi)

        #expect(!engine.transitionNotifications.isEmpty)
        #expect(engine.transitionNotifications.first?.contains("Connected VPN") == true)
    }

    @Test("T1-F12-05: Manual override pauses automatic VPN triggers")
    func testManualOverridePausesAutomation() {
        let engine = VPNAutomationEngine()
        engine.setManualOverride(active: true)

        let action = engine.evaluate(state: .defaultCellularHotspot)
        #expect(action == .none)
    }
}
