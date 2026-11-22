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
}
