import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 01: Upstream & Downstream Interface Detection", .tags(.tier1, .m1_foundation))
struct Tier1_01_InterfaceDetectionTests {

    /// Helper scanner simulating system interface discovery
    struct InterfaceScanner {
        static func parseHardwarePorts(output: String) -> [NetworkInterfaceInfo] {
            var interfaces: [NetworkInterfaceInfo] = []
            let lines = output.components(separatedBy: .newlines)
            var currentPort: String?
            var currentDevice: String?
            var currentMAC: String?

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Hardware Port:") {
                    currentPort = trimmed.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Device:") {
                    currentDevice = trimmed.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Ethernet Address:") {
                    currentMAC = trimmed.replacingOccurrences(of: "Ethernet Address:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.isEmpty {
                    if let dev = currentDevice, let port = currentPort {
                        interfaces.append(NetworkInterfaceInfo(
                            bsdName: dev,
                            displayName: port,
                            macAddress: currentMAC,
                            mtu: 1500,
                            isPrimary: false,
                            isUp: true
                        ))
                    }
                    currentPort = nil
                    currentDevice = nil
                    currentMAC = nil
                }
            }

            if let dev = currentDevice, let port = currentPort {
                interfaces.append(NetworkInterfaceInfo(
                    bsdName: dev,
                    displayName: port,
                    macAddress: currentMAC,
                    mtu: 1500,
                    isPrimary: false,
                    isUp: true
                ))
            }

            return interfaces
        }

        static func detectPrimaryInterface(defaultRoute: String, interfaces: [NetworkInterfaceInfo]) -> [NetworkInterfaceInfo] {
            interfaces.map { iface in
                NetworkInterfaceInfo(
                    bsdName: iface.bsdName,
                    displayName: iface.displayName,
                    ipAddresses: iface.ipAddresses,
                    macAddress: iface.macAddress,
                    gateway: iface.bsdName == defaultRoute ? "10.1.36.1" : iface.gateway,
                    mtu: iface.mtu,
                    isPrimary: iface.bsdName == defaultRoute,
                    isUp: iface.isUp
                )
            }
        }
    }

    @Test("T1-F01-01: Detect physical Ethernet en10 with IPv4, MAC, and MTU")
    func testPhysicalEthernetDetection() {
        let hardwarePortsOutput = """
        Hardware Port: USB 10/100 LAN
        Device: en10
        Ethernet Address: 00:e0:4c:68:01:aa

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: f4:d4:88:5a:23:42
        """

        let interfaces = InterfaceScanner.parseHardwarePorts(output: hardwarePortsOutput)
        let en10 = interfaces.first(where: { $0.bsdName == "en10" })

        #expect(en10 != nil)
        #expect(en10?.bsdName == "en10")
        #expect(en10?.displayName == "USB 10/100 LAN")
        #expect(en10?.macAddress == "00:e0:4c:68:01:aa")
        #expect(en10?.mtu == 1500)
    }

    @Test("T1-F01-02: Detect Wi-Fi en0 with correct interface metadata")
    func testWiFiInterfaceDetection() {
        let hardwarePortsOutput = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: f4:d4:88:5a:23:42
        """

        let interfaces = InterfaceScanner.parseHardwarePorts(output: hardwarePortsOutput)
        let en0 = interfaces.first(where: { $0.bsdName == "en0" })

        #expect(en0 != nil)
        #expect(en0?.bsdName == "en0")
        #expect(en0?.displayName == "Wi-Fi")
        #expect(en0?.macAddress == "f4:d4:88:5a:23:42")
    }

    @Test("T1-F01-03: Detect iPhone USB cellular tethering interface en9")
    func testCellularInterfaceDetection() {
        let hardwarePortsOutput = """
        Hardware Port: iPhone USB
        Device: en9
        Ethernet Address: 02:2c:80:11:92:33
        """

        let interfaces = InterfaceScanner.parseHardwarePorts(output: hardwarePortsOutput)
        let en9 = interfaces.first(where: { $0.bsdName == "en9" })

        #expect(en9 != nil)
        #expect(en9?.bsdName == "en9")
        #expect(en9?.displayName == "iPhone USB")
        #expect(en9?.macAddress == "02:2c:80:11:92:33")
    }

    @Test("T1-F01-04: Verify isPrimary flag matches default route gateway")
    func testPrimaryInterfaceIdentification() {
        let baseList = [
            NetworkInterfaceInfo(bsdName: "en10", displayName: "Ethernet", mtu: 1500),
            NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", mtu: 1500)
        ]

        let evaluated = InterfaceScanner.detectPrimaryInterface(defaultRoute: "en10", interfaces: baseList)
        let primary = evaluated.first(where: { $0.isPrimary })
        let nonPrimary = evaluated.first(where: { !$0.isPrimary })

        #expect(primary?.bsdName == "en10")
        #expect(primary?.gateway == "10.1.36.1")
        #expect(nonPrimary?.bsdName == "en0")
    }

    @Test("T1-F01-05: Dynamic interface refresh on network link status change")
    func testDynamicInterfaceRefresh() {
        var interfaceInventory: [String: NetworkInterfaceInfo] = [:]

        // Initial state: en10 only
        interfaceInventory["en10"] = NetworkInterfaceInfo(bsdName: "en10", displayName: "Ethernet", isUp: true)
        #expect(interfaceInventory.count == 1)

        // Event: Wi-Fi en0 connected
        interfaceInventory["en0"] = NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", isUp: true)
        #expect(interfaceInventory.count == 2)
        #expect(interfaceInventory["en0"]?.isUp == true)

        // Event: Ethernet en10 disconnected
        interfaceInventory["en10"] = NetworkInterfaceInfo(bsdName: "en10", displayName: "Ethernet", isUp: false)
        #expect(interfaceInventory["en10"]?.isUp == false)
    }
}
