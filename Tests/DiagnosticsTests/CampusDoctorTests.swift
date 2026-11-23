import Testing
import Foundation
@testable import NetBoostCore

@Suite("Campus Diagnostics: CampusDoctor Master Coordinator Tests")
struct CampusDoctorTests {

    final class MockDiagnosticsInterfaceProvider: NetworkInterfaceProvider, @unchecked Sendable {
        let mockInterfaces: [NetworkInterfaceInfo]
        init(interfaces: [NetworkInterfaceInfo]) {
            self.mockInterfaces = interfaces
        }
        func fetchInterfaces() async -> [NetworkInterfaceInfo] {
            mockInterfaces
        }
    }

    @Test("Doctor runs full diagnostics and aggregates probe results into telemetry report")
    func testRunFullDiagnostics() async {
        let mockInterfaces = [
            NetworkInterfaceInfo(
                bsdName: "en10",
                displayName: "USB 10/100 LAN",
                ipAddresses: [IPAddress(address: "10.1.36.52")],
                gateway: "10.1.36.1",
                mtu: 1500,
                isPrimary: true
            ),
            NetworkInterfaceInfo(
                bsdName: "en0",
                displayName: "Wi-Fi",
                ipAddresses: [IPAddress(address: "172.20.10.2")],
                gateway: "172.20.10.1",
                mtu: 1500, // Misconfigured cellular MTU
                isPrimary: false
            )
        ]

        let provider = MockDiagnosticsInterfaceProvider(interfaces: mockInterfaces)
        let doctor = CampusDoctor(interfaceProvider: provider)

        let report = await doctor.runFullDiagnostics()

        #expect(report.interfaces.count == 2)
        #expect(report.interfaces.first?.bsdName == "en10")
        // MTU 1500 on cellular Wi-Fi should be flagged
        #expect(report.activeIssues.contains { $0.title.contains("MTU") })
    }

    @Test("Doctor pings target endpoint and returns probe result")
    func testPingTarget() async {
        let doctor = CampusDoctor()
        let result = await doctor.pingTarget(host: "127.0.0.1")

        #expect(result.targetHost == "127.0.0.1")
        #expect(result.packetLossPercent <= 100.0)
    }

    @Test("Doctor checks captive portal status")
    func testCheckCaptivePortal() async {
        let doctor = CampusDoctor()
        let status = await doctor.checkCaptivePortal()

        #expect(status == .notDetected || status == .unknown || status == .detected || status == .redirecting)
    }

    @Test("Doctor records repair routines in history")
    func testDoctorRepairRoutinesHistory() {
        let routines = RepairRoutines()
        let doctor = CampusDoctor(repairRoutines: routines)

        doctor.repairRoutines.recordEvent("MTU adjusted to 1280")
        #expect(doctor.repairRoutines.history.count == 1)
        #expect(doctor.repairRoutines.history.first?.contains("1280") == true)
    }
}
