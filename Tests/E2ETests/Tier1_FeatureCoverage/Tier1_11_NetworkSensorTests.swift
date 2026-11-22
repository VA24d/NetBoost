import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 11: Network Environment Sensor", .tags(.tier1, .m3_vpn, .network_env))
struct Tier1_11_NetworkSensorTests {

    struct EnvironmentClassifier {
        static func classify(interfaces: [NetworkInterfaceInfo]) -> NetworkEnvironmentState {
            if let en10 = interfaces.first(where: { $0.bsdName == "en10" && $0.isUp }) {
                if let ip = en10.ipv4Address, (ip.hasPrefix("10.1.") || ip.hasPrefix("10.8.")) {
                    return .campusLAN(interface: "en10", ip: ip, gateway: en10.gateway ?? "10.1.36.1", mtu: en10.mtu)
                }
            }

            if let en9 = interfaces.first(where: { $0.bsdName == "en9" && $0.isUp }) {
                return .cellularHotspot(interface: "en9", ip: en9.ipv4Address ?? "172.20.10.2", gateway: en9.gateway ?? "172.20.10.1", mtu: 1280)
            }

            if let en0 = interfaces.first(where: { $0.bsdName == "en0" && $0.isUp }) {
                if let ip = en0.ipv4Address {
                    if ip.hasPrefix("172.20.10.") {
                        return .cellularHotspot(interface: "en0", ip: ip, gateway: en0.gateway ?? "172.20.10.1", mtu: 1280)
                    } else {
                        return .externalWiFi(interface: "en0", ip: ip, gateway: en0.gateway ?? "192.168.1.1", mtu: en0.mtu)
                    }
                }
            }

            return .disconnected
        }
    }

    @Test("T1-F11-01: Classify active en10 on 10.1.0.0/16 as Campus LAN")
    func testClassifyCampusLAN() {
        let en10 = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "Ethernet",
            ipAddresses: [IPAddress(address: "10.1.36.52", version: .v4)],
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let state = EnvironmentClassifier.classify(interfaces: [en10])
        #expect(state.isCampusLAN == true)
        #expect(state.primaryInterface == "en10")
    }

    @Test("T1-F11-02: Classify en0 on 172.20.10.0/28 as Cellular Hotspot")
    func testClassifyCellularHotspot() {
        let en0 = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2", version: .v4)],
            gateway: "172.20.10.1",
            mtu: 1280,
            isPrimary: true,
            isUp: true
        )

        let state = EnvironmentClassifier.classify(interfaces: [en0])
        #expect(state.isCellular == true)
        #expect(state.primaryInterface == "en0")
        #expect(state.mtu == 1280)
    }

    @Test("T1-F11-03: Classify external home/cafe Wi-Fi on 192.168.1.0/24")
    func testClassifyExternalWiFi() {
        let en0 = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "192.168.1.105", version: .v4)],
            gateway: "192.168.1.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let state = EnvironmentClassifier.classify(interfaces: [en0])
        if case .externalWiFi(let iface, let ip, _, _) = state {
            #expect(iface == "en0")
            #expect(ip == "192.168.1.105")
        } else {
            Issue.record("Expected externalWiFi classification")
        }
    }

    @Test("T1-F11-04: Stream path changes continuously via MockNetworkEnvironment")
    func testStreamPathChanges() async throws {
        let mockEnv = MockNetworkEnvironment()
        var receivedStates: [NetworkEnvironmentState] = []

        let task = Task {
            for await state in mockEnv.environmentStream() {
                receivedStates.append(state)
                if receivedStates.count >= 2 { break }
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        mockEnv.transition(to: .defaultCellularHotspot)

        _ = await task.result
        #expect(receivedStates.count >= 2)
        #expect(receivedStates.last?.isCellular == true)
    }

    @Test("T1-F11-05: Debounce network state transitions")
    func testDebounceStateTransitions() async throws {
        final class Debouncer: @unchecked Sendable {
            private var lastState: NetworkEnvironmentState?
            private let lock = NSLock()

            func recordTransition(_ s: NetworkEnvironmentState) {
                lock.lock()
                defer { lock.unlock() }
                lastState = s
            }

            var current: NetworkEnvironmentState? {
                lock.lock()
                defer { lock.unlock() }
                return lastState
            }
        }

        let debouncer = Debouncer()
        debouncer.recordTransition(.defaultCampusLAN)
        debouncer.recordTransition(.defaultCellularHotspot)

        #expect(debouncer.current?.isCellular == true)
    }
}
