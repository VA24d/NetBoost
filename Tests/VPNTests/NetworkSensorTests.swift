import Testing
import Foundation
@testable import NetBoostCore

@Suite("VPN Subsystem: Network Environment Sensor Unit Tests", .tags(.tier1, .m3_vpn, .network_env))
struct NetworkSensorTests {

    // Helper mock provider
    struct StaticInterfaceProvider: NetworkInterfaceProvider {
        let interfaces: [NetworkInterfaceInfo]
        func fetchInterfaces() async -> [NetworkInterfaceInfo] {
            interfaces
        }
    }

    final class MockPathMonitor: PathMonitorProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (NetworkPathSnapshot) -> Void)?
        private var snapshot: NetworkPathSnapshot

        var currentPath: NetworkPathSnapshot {
            lock.withLock { snapshot }
        }

        init(initial: NetworkPathSnapshot = NetworkPathSnapshot(status: .satisfied)) {
            self.snapshot = initial
        }

        func start(onUpdate: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
            lock.withLock { self.handler = onUpdate }
            onUpdate(currentPath)
        }

        func cancel() {
            lock.withLock { self.handler = nil }
        }

        func update(path: NetworkPathSnapshot) {
            let callback = lock.withLock { () -> (@Sendable (NetworkPathSnapshot) -> Void)? in
                self.snapshot = path
                return self.handler
            }
            callback?(path)
        }
    }

    @Test("Classify en10 with campus LAN IP 10.1.36.52 as campusLAN")
    func testClassifyCampusLAN() {
        let en10 = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB Ethernet",
            ipAddresses: [IPAddress(address: "10.1.36.52", version: .v4)],
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let state = NetworkSensor.classify(interfaces: [en10])
        #expect(state.isCampusLAN == true)
        #expect(state.primaryInterface == "en10")
        #expect(state.mtu == 1500)
    }

    @Test("Classify en9 (iPhone USB) and en0 (172.20.10.0/28) as cellularHotspot with MTU 1280")
    func testClassifyCellularHotspot() {
        let en9 = NetworkInterfaceInfo(
            bsdName: "en9",
            displayName: "iPhone USB",
            ipAddresses: [IPAddress(address: "172.20.10.2", version: .v4)],
            gateway: "172.20.10.1",
            mtu: 1280,
            isPrimary: true,
            isUp: true
        )
        let stateEn9 = NetworkSensor.classify(interfaces: [en9])
        #expect(stateEn9.isCellular == true)
        #expect(stateEn9.mtu == 1280)

        let en0Hotspot = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.3", version: .v4)],
            gateway: "172.20.10.1",
            mtu: 1280,
            isPrimary: true,
            isUp: true
        )
        let stateEn0 = NetworkSensor.classify(interfaces: [en0Hotspot])
        #expect(stateEn0.isCellular == true)
        #expect(stateEn0.primaryInterface == "en0")
    }

    @Test("Classify en0 on non-campus private network as externalWiFi")
    func testClassifyExternalWiFi() {
        let en0Home = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "192.168.1.100", version: .v4)],
            gateway: "192.168.1.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let state = NetworkSensor.classify(interfaces: [en0Home])
        #expect(state.isConnected == true)
        #expect(!state.isCampusLAN)
        #expect(!state.isCellular)
        #expect(state.primaryInterface == "en0")
    }

    @Test("Dual-homed priority: en10 on campus LAN takes precedence over active en0 hotspot")
    func testDualHomedPriority() {
        let en10 = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB Ethernet",
            ipAddresses: [IPAddress(address: "10.1.36.52", version: .v4)],
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let en0 = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2", version: .v4)],
            gateway: "172.20.10.1",
            mtu: 1280,
            isPrimary: false,
            isUp: true
        )

        let state = NetworkSensor.classify(interfaces: [en0, en10])
        #expect(state.isCampusLAN == true)
        #expect(state.primaryInterface == "en10")
    }

    @Test("Classify empty interfaces or link-local 169.254.x.x addresses as disconnected")
    func testDisconnectedClassification() {
        #expect(NetworkSensor.classify(interfaces: []) == .disconnected)

        let linkLocal = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "169.254.10.20", version: .v4)],
            isPrimary: true,
            isUp: true
        )
        #expect(NetworkSensor.classify(interfaces: [linkLocal]) == .disconnected)

        let downIface = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "Ethernet",
            ipAddresses: [IPAddress(address: "10.1.36.52", version: .v4)],
            isPrimary: true,
            isUp: false
        )
        #expect(NetworkSensor.classify(interfaces: [downIface]) == .disconnected)

        let unsatisfiedPath = NetworkPathSnapshot(status: .unsatisfied)
        #expect(NetworkSensor.classify(interfaces: [linkLocal], path: unsatisfiedPath) == .disconnected)
    }

    @Test("NetworkSensor environment stream delivers initial state and manual transitions")
    func testEnvironmentStreamDelivery() async {
        let sensor = NetworkSensor(
            debounceInterval: 0.01,
            initialState: .disconnected
        )

        let stream = sensor.makeEnvironmentStream()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        #expect(initial == .disconnected)

        let target = NetworkEnvironmentState.defaultCampusLAN
        sensor.transition(to: target)

        guard let next = await iterator.next() else {
            Issue.record("Expected next environment state")
            return
        }
        #expect(next == target)
        #expect(sensor.currentState == target)
    }

    @Test("Path monitor update triggers classification and state transition")
    func testPathMonitorUpdateClassification() async throws {
        let campusLAN = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "Ethernet",
            ipAddresses: [IPAddress(address: "10.1.36.52", version: .v4)],
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let mockMonitor = MockPathMonitor(initial: NetworkPathSnapshot(status: .satisfied))
        let provider = StaticInterfaceProvider(interfaces: [campusLAN])
        let sensor = NetworkSensor(
            pathMonitor: mockMonitor,
            interfaceProvider: provider,
            debounceInterval: 0.01,
            initialState: .disconnected
        )

        let stream = sensor.makeEnvironmentStream()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // initial .disconnected

        sensor.start()
        defer { sensor.stop() }

        // Trigger path update
        mockMonitor.update(path: NetworkPathSnapshot(status: .satisfied))

        // Await updated state from stream
        let updatedState = await iterator.next()
        #expect(updatedState?.isCampusLAN == true)
        #expect(sensor.currentState.isCampusLAN == true)
    }
}
