import Foundation
import Testing
import Darwin
@testable import NetBoostCore

@Suite("Tier 2 - Feature 02: Socket Binding Helper Boundaries", .tags(.tier2, .m1_foundation))
struct Tier2_02_SocketBindingBoundariesTests {

    @Test("T2-F02-01: Bind to invalid interface index (UInt32.max) throws socketOptionFailed")
    func testBindInvalidInterfaceIndex() throws {
        let fd = try DarwinSocketHelper.createSocket()
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        #expect(throws: DarwinSocketError.self) {
            try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: UInt32.max)
        }
    }

    @Test("T2-F02-02: Bind on negative or closed file descriptor throws invalidFileDescriptor")
    func testBindNegativeFileDescriptor() {
        #expect(throws: DarwinSocketError.invalidFileDescriptor) {
            try DarwinSocketHelper.bindSocket(fd: -1, toInterfaceIndex: 1)
        }

        #expect(throws: DarwinSocketError.invalidFileDescriptor) {
            try DarwinSocketHelper.getBoundInterface(fd: -1)
        }
    }

    @Test("T2-F02-03: Query bound interface on unbound socket returns 0 (unbound)")
    func testQueryUnboundSocket() throws {
        let fd = try DarwinSocketHelper.createSocket()
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        let boundIndex = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(boundIndex == 0)
    }

    @Test("T2-F02-04: Non-existent interface name throws interfaceNotFound error")
    func testNonExistentInterfaceBinding() throws {
        let fd = try DarwinSocketHelper.createSocket()
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        let bogusName = "fake_if_9999"
        #expect(throws: DarwinSocketError.interfaceNotFound(bogusName)) {
            try DarwinSocketHelper.bindSocket(fd: fd, toInterface: bogusName)
        }
    }

    @Test("T2-F02-05: Consecutive re-binding to loopback interface updates binding")
    func testConsecutiveSocketRebinding() throws {
        let fd = try DarwinSocketHelper.createSocket()
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        guard let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") else {
            Issue.record("lo0 loopback interface not found")
            return
        }

        try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)
        let boundIndex1 = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(boundIndex1 == loIndex)

        // Re-binding to the same or another index
        try DarwinSocketHelper.bindSocket(fd: fd, toInterface: "lo0")
        let boundIndex2 = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(boundIndex2 == loIndex)
    }
}
