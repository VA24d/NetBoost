import Testing
import Foundation
import Darwin
@testable import NetBoostCore

@Suite("Feature 02: Darwin Socket Interface Binding Helper", .tags(.tier1, .m1_foundation))
struct Tier1_02_SocketBindingTests {

    @Test("T1-F02-01: Bind TCP socket to loopback interface index via IP_BOUND_IF")
    func testBindTCPSocketToInterfaceIndex() throws {
        guard let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") else {
            Issue.record("Loopback interface lo0 not found")
            return
        }

        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)
        let boundIndex = try DarwinSocketHelper.getBoundInterface(fd: fd)

        #expect(boundIndex == loIndex)
    }

    @Test("T1-F02-02: Bind TCP socket to interface by BSD name")
    func testBindTCPSocketToInterfaceName() throws {
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        try DarwinSocketHelper.bindSocket(fd: fd, toInterface: "lo0")
        let boundIndex = try DarwinSocketHelper.getBoundInterface(fd: fd)

        let expectedIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0")
        #expect(boundIndex == expectedIndex)
    }

    @Test("T1-F02-03: Bind UDP socket file descriptor to specified interface index")
    func testBindUDPSocketToInterfaceIndex() throws {
        guard let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") else {
            Issue.record("Loopback interface lo0 not found")
            return
        }

        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_DGRAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)
        let boundIndex = try DarwinSocketHelper.getBoundInterface(fd: fd)

        #expect(boundIndex == loIndex)
    }

    @Test("T1-F02-04: Query getsockopt for IP_BOUND_IF and verify returned index")
    func testQueryGetsockoptBoundInterface() throws {
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        // Initial unbound socket should return 0 (no specific interface bound)
        let initialBound = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(initialBound == 0)

        // Bind to lo0
        guard let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") else {
            Issue.record("lo0 missing")
            return
        }
        try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)

        // Query again and verify it matches loIndex
        let boundAfter = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(boundAfter == loIndex)
    }

    @Test("T1-F02-05: Interface name and index bidirectional mapping invariants")
    func testInterfaceNameIndexMapping() {
        guard let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") else {
            Issue.record("lo0 not found")
            return
        }

        let resolvedName = DarwinSocketHelper.getInterfaceName(for: loIndex)
        #expect(resolvedName == "lo0")

        let nonExistentIndex = DarwinSocketHelper.getInterfaceIndex(for: "nonexistent999")
        #expect(nonExistentIndex == nil)
    }
}
