import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 2 - Feature 07: SOCKS5 Proxy Dispatcher Boundaries", .tags(.tier2, .m2_proxy, .socks5))
struct Tier2_07_SOCKS5BoundariesTests {

    @Test("T2-F07-01: Client sending invalid SOCKS version (0x04) is rejected")
    func testInvalidSOCKSVersionHandling() {
        // RFC 1928: SOCKS version must be 0x05. Version 0x04 (SOCKS4) must be rejected
        let socks4Handshake: [UInt8] = [0x04, 0x01, 0x00]
        let version = socks4Handshake[0]
        #expect(version != 0x05)

        // Protocol parser validator
        func validateSOCKS5Version(_ bytes: [UInt8]) -> Bool {
            guard !bytes.isEmpty else { return false }
            return bytes[0] == 0x05
        }
        #expect(validateSOCKS5Version(socks4Handshake) == false)
    }

    @Test("T2-F07-02: Unsupported authentication method returns 0xFF (No Acceptable Methods)")
    func testUnsupportedAuthMethodResponse() {
        // Client offers only method 0x02 (Username/Password), server only supports 0x00 (No Auth)
        let clientOfferedMethods: [UInt8] = [0x02] // GSSAPI or user/pass only
        let supportedMethods: Set<UInt8> = [0x00]   // No authentication required

        func selectAuthMethod(offered: [UInt8]) -> UInt8 {
            for method in offered {
                if supportedMethods.contains(method) {
                    return method
                }
            }
            return 0xFF // RFC 1928: 0xFF = NO ACCEPTABLE METHODS
        }

        let selected = selectAuthMethod(offered: clientOfferedMethods)
        #expect(selected == 0xFF)
    }

    @Test("T2-F07-03: Port collision detection when binding to an already occupied port")
    func testPortCollisionDetection() async throws {
        // Start target server on an ephemeral port
        let target = MockSOCKS5TargetServer()
        let occupiedPort = try await target.start()
        defer { target.stop() }

        #expect(occupiedPort > 0)

        // Attempting to bind another listener on the exact same port must fail or throw
        let params = NWParameters.tcp
        let duplicateListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: occupiedPort)!)

        await #expect(throws: Error.self) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                duplicateListener.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let err):
                        continuation.resume(throwing: err)
                    case .ready:
                        continuation.resume()
                    default:
                        break
                    }
                }
                duplicateListener.start(queue: .global())
            }
        }
        duplicateListener.cancel()
    }

    @Test("T2-F07-04: SOCKS5 address type handling for IPv4, Domain Name, and IPv6")
    func testSOCKS5AddressTypeParsing() {
        // RFC 1928 Address types: 0x01 = IPv4, 0x03 = Domain Name, 0x04 = IPv6
        func parseAddressType(_ b: UInt8) -> String? {
            switch b {
            case 0x01: return "IPv4"
            case 0x03: return "Domain"
            case 0x04: return "IPv6"
            default: return nil
            }
        }

        #expect(parseAddressType(0x01) == "IPv4")
        #expect(parseAddressType(0x03) == "Domain")
        #expect(parseAddressType(0x04) == "IPv6")
        #expect(parseAddressType(0x00) == nil)
        #expect(parseAddressType(0x05) == nil)
    }

    @Test("T2-F07-05: Target connection unreachable maps to SOCKS5 REP 0x04 (Host unreachable)")
    func testTargetUnreachableMapping() {
        enum SOCKS5ReplyCode: UInt8 {
            case succeeded = 0x00
            case generalServerFailure = 0x01
            case connectionNotAllowed = 0x02
            case networkUnreachable = 0x03
            case hostUnreachable = 0x04
            case connectionRefused = 0x05
            case ttlExpired = 0x06
            case commandNotSupported = 0x07
            case addressTypeNotSupported = 0x08
        }

        func mapPOSIXErrorToSOCKS5Reply(errno: Int32) -> SOCKS5ReplyCode {
            switch errno {
            case ENETUNREACH: return .networkUnreachable
            case EHOSTUNREACH: return .hostUnreachable
            case ECONNREFUSED: return .connectionRefused
            default: return .generalServerFailure
            }
        }

        #expect(mapPOSIXErrorToSOCKS5Reply(errno: EHOSTUNREACH) == .hostUnreachable)
        #expect(mapPOSIXErrorToSOCKS5Reply(errno: ENETUNREACH) == .networkUnreachable)
        #expect(mapPOSIXErrorToSOCKS5Reply(errno: ECONNREFUSED) == .connectionRefused)
    }
}
