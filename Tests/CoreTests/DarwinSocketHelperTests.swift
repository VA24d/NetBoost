import Foundation
import Testing
import Darwin
@testable import NetBoostCore

@Suite("DarwinSocketHelper BSD Socket Interface Binding Tests")
struct DarwinSocketHelperTests {

    @Test("Verify loopback interface resolution by name and index")
    func testLoopbackResolution() {
        let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0")
        #expect(loIndex != nil)
        #expect(loIndex == 1)

        let loName = DarwinSocketHelper.getInterfaceName(for: 1)
        #expect(loName == "lo0")
    }

    @Test("Create and close TCP socket")
    func testCreateAndCloseSocket() throws {
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        #expect(fd >= 0)
        DarwinSocketHelper.closeSocket(fd: fd)
    }

    @Test("Bind socket to loopback interface using IP_BOUND_IF by index")
    func testBindSocketByIndex() throws {
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        guard let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") else {
            Issue.record("Loopback interface lo0 not found")
            return
        }

        try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)

        let boundIndex = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(boundIndex == loIndex)
    }

    @Test("Bind socket to loopback interface by name")
    func testBindSocketByName() throws {
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        try DarwinSocketHelper.bindSocket(fd: fd, toInterface: "lo0")

        let boundIndex = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(boundIndex == 1)
    }

    @Test("Error handling: invalid file descriptor")
    func testInvalidFileDescriptor() {
        #expect(throws: DarwinSocketError.invalidFileDescriptor) {
            try DarwinSocketHelper.bindSocket(fd: -1, toInterfaceIndex: 1)
        }

        #expect(throws: DarwinSocketError.invalidFileDescriptor) {
            _ = try DarwinSocketHelper.getBoundInterface(fd: -1)
        }
    }

    @Test("Error handling: non-existent interface name")
    func testNonExistentInterface() throws {
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        let fakeIfName = "non_existent_if_xyz_99"
        #expect(throws: DarwinSocketError.interfaceNotFound(fakeIfName)) {
            try DarwinSocketHelper.bindSocket(fd: fd, toInterface: fakeIfName)
        }
    }

    @Test("Query interface MTU via SIOCGIFMTU and verify loopback MTU")
    func testGetInterfaceMTU() {
        let loMTU = DarwinSocketHelper.getInterfaceMTU("lo0")
        #expect(loMTU != nil)
        #expect((loMTU ?? 0) >= 1500)

        #expect(DarwinSocketHelper.getInterfaceMTU("non_existent_if_xyz_99") == nil)
        #expect(DarwinSocketHelper.getInterfaceMTU("") == nil)
    }

    @Test("Extract hardware MAC address from AF_LINK sockaddr_dl")
    func testGetInterfaceMACAddress() {
        // lo0 has no 6-byte Ethernet MAC
        #expect(DarwinSocketHelper.getInterfaceMACAddress("lo0") == nil)
        #expect(DarwinSocketHelper.getInterfaceMACAddress("non_existent_if_xyz_99") == nil)

        // en0 exists on macOS machines and has a 6-octet colon-separated MAC
        if DarwinSocketHelper.getInterfaceIndex(for: "en0") != nil,
           let mac = DarwinSocketHelper.getInterfaceMACAddress("en0") {
            let octets = mac.split(separator: ":")
            #expect(octets.count == 6)
            #expect(octets.allSatisfy { $0.count == 2 })
        }
    }

    @Test("Check interface active flags and parse default gateways from netstat output")
    func testInterfaceActiveAndDefaultGateways() {
        #expect(DarwinSocketHelper.isInterfaceActive("lo0") == true)
        #expect(DarwinSocketHelper.isInterfaceActive("non_existent_if_xyz_99") == false)

        let sampleNetstat = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            10.1.36.1          UGScg                en10
        default            192.168.1.1        UGScIg                en0
        default            link#14            UCSIg               utun4
        10.1.36/22         link#13            UCS                  en10
        """

        let gateways = DarwinSocketHelper.parseDefaultGateways(from: sampleNetstat)
        #expect(gateways["en10"] == "10.1.36.1")
        #expect(gateways["en0"] == "192.168.1.1")
        #expect(gateways["utun4"] == nil)

        // Verify live getDefaultGateways call returns cleanly without crashing
        _ = DarwinSocketHelper.getDefaultGateways()
    }
}
