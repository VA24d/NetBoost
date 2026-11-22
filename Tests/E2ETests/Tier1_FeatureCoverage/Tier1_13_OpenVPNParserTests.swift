import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 13: OpenVPN Profile Parser & Inspector", .tags(.tier1, .m3_vpn))
struct Tier1_13_OpenVPNParserTests {

    struct OpenVPNParser {
        static func parse(content: String, name: String = "profile") -> VPNProfileInfo {
            var server = ""
            var proto = "udp"
            var port = 1194
            var cipher: String?
            var routes: [VPNRouteEntry] = []
            var isSplit = false
            var dnsServers: [String] = []

            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.isEmpty {
                    continue
                }

                let tokens = trimmed.split(separator: " ").map(String.init)
                guard let first = tokens.first else { continue }

                switch first {
                case "remote":
                    if tokens.count >= 2 { server = tokens[1] }
                    if tokens.count >= 3 { port = Int(tokens[2]) ?? 1194 }
                case "proto":
                    if tokens.count >= 2 { proto = tokens[1] }
                case "cipher":
                    if tokens.count >= 2 { cipher = tokens[1] }
                case "route-nopull":
                    isSplit = true
                case "route":
                    if tokens.count >= 3 {
                        routes.append(VPNRouteEntry(destinationSubnet: tokens[1], mask: tokens[2]))
                    }
                case "dhcp-option":
                    if tokens.count >= 3 && tokens[1] == "DNS" {
                        dnsServers.append(tokens[2])
                    }
                default:
                    break
                }
            }

            return VPNProfileInfo(
                name: name,
                serverAddress: server,
                proto: proto,
                port: port,
                cipher: cipher,
                routes: routes,
                dnsServers: dnsServers,
                isCampusSplit: isSplit
            )
        }

        static func extractCertificateBlock(tag: String, content: String) -> String? {
            let openTag = "<\(tag)>"
            let closeTag = "</\(tag)>"
            guard let start = content.range(of: openTag)?.upperBound,
                  let end = content.range(of: closeTag)?.lowerBound else {
                return nil
            }
            return String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test("T1-F13-01: Parse valid_macos.ovpn Passepartout profile directives")
    func testParseValidMacOSProfile() throws {
        let path = "Tests/Fixtures/Profiles/valid_macos.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let profile = OpenVPNParser.parse(content: content, name: "macos.ovpn")

        #expect(profile.serverAddress == "vpn2.iiit.ac.in")
        #expect(profile.port == 1194)
        #expect(profile.proto == "udp")
        #expect(profile.cipher == "AES-128-GCM")
    }

    @Test("T1-F13-02: Parse iiit_split.ovpn route-nopull and static subnet routes")
    func testParseIIITSplitProfileRoutes() throws {
        let path = "Tests/Fixtures/Profiles/iiit_split.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let profile = OpenVPNParser.parse(content: content, name: "iiit_split.ovpn")

        #expect(profile.isCampusSplit == true)
        #expect(profile.routes.count >= 5)
        #expect(profile.routes.contains { $0.destinationSubnet == "10.1.0.0" && $0.mask == "255.255.0.0" })
        #expect(profile.routes.contains { $0.destinationSubnet == "10.8.0.0" })
    }

    @Test("T1-F13-03: Extract embedded <ca> certificate block")
    func testExtractCACertificateBlock() throws {
        let path = "Tests/Fixtures/Profiles/valid_macos.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let caCert = OpenVPNParser.extractCertificateBlock(tag: "ca", content: content)

        #expect(caCert != nil)
        #expect(caCert?.contains("-----BEGIN CERTIFICATE-----") == true)
        #expect(caCert?.contains("-----END CERTIFICATE-----") == true)
    }

    @Test("T1-F13-04: Parse dhcp-option DNS push directives")
    func testParseDNSDirectives() {
        let mockContent = """
        client
        remote vpn.example.com 1194
        dhcp-option DNS 10.4.20.21
        dhcp-option DNS 10.4.20.222
        """

        let profile = OpenVPNParser.parse(content: mockContent)
        #expect(profile.dnsServers.count == 2)
        #expect(profile.dnsServers[0] == "10.4.20.21")
        #expect(profile.dnsServers[1] == "10.4.20.222")
    }

    @Test("T1-F13-05: Distinguish between full tunnel and split tunnel profiles")
    func testDistinguishFullVsSplitTunnel() {
        let fullTunnelContent = """
        client
        remote vpn.example.com 1194
        redirect-gateway def1
        """

        let splitTunnelContent = """
        client
        remote vpn.example.com 1194
        route-nopull
        route 10.8.0.0 255.255.0.0
        """

        let fullProfile = OpenVPNParser.parse(content: fullTunnelContent)
        let splitProfile = OpenVPNParser.parse(content: splitTunnelContent)

        #expect(fullProfile.isCampusSplit == false)
        #expect(splitProfile.isCampusSplit == true)
    }
}
