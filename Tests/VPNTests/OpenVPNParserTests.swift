import Testing
import Foundation
@testable import NetBoostCore

@Suite("VPN Subsystem: OpenVPN Configuration Parser Unit Tests", .tags(.tier1, .m3_vpn))
struct OpenVPNParserTests {

    let fixturesDir = "Tests/Fixtures/Profiles/"

    @Test("Parse clean_split.ovpn fixture verifying directives and absence of 10.1.0.0 route")
    func testParseCleanSplitFixture() throws {
        let path = fixturesDir + "clean_split.ovpn"
        let profile = try OpenVPNParser.parse(filePath: path)

        #expect(profile.serverAddress == "vpn.iiit.ac.in")
        #expect(profile.port == 1194)
        #expect(profile.proto == "udp")
        #expect(profile.cipher == "AES-128-GCM")
        #expect(profile.isCampusSplit == true)

        let destinations = profile.routes.map(\.destinationSubnet)
        #expect(destinations.contains("10.4.0.0"))
        #expect(destinations.contains("10.8.0.0"))
        #expect(destinations.contains("10.10.0.0"))
        #expect(!destinations.contains("10.1.0.0"))
    }

    @Test("Parse iiit_split.ovpn fixture verifying route collision route 10.1.0.0/16 presence")
    func testParseIIITSplitFixture() throws {
        let path = fixturesDir + "iiit_split.ovpn"
        let profile = try OpenVPNParser.parse(filePath: path)

        #expect(profile.serverAddress == "vpn.iiit.ac.in")
        #expect(profile.port == 1194)
        #expect(profile.isCampusSplit == true)
        #expect(profile.routes.count == 5)

        let route101 = profile.routes.first(where: { $0.destinationSubnet == "10.1.0.0" })
        #expect(route101 != nil)
        #expect(route101?.mask == "255.255.0.0")
    }

    @Test("Parse valid_macos.ovpn full-tunnel profile fixture")
    func testParseValidMacOSFixture() throws {
        let path = fixturesDir + "valid_macos.ovpn"
        let profile = try OpenVPNParser.parse(filePath: path)

        #expect(profile.serverAddress == "vpn2.iiit.ac.in")
        #expect(profile.port == 1194)
        #expect(profile.proto == "udp")
        #expect(profile.cipher == "AES-128-GCM")
        #expect(profile.isCampusSplit == false)
    }

    @Test("Extract certificate blocks (<ca>) from profile content")
    func testExtractCACertificateBlock() throws {
        let path = fixturesDir + "valid_macos.ovpn"
        let content = try String(contentsOfFile: path, encoding: .utf8)

        let caBlock = OpenVPNParser.extractCertificateBlock(tag: "ca", content: content)
        #expect(caBlock != nil)
        #expect(caBlock?.contains("BEGIN CERTIFICATE") == true)
        #expect(caBlock?.contains("END CERTIFICATE") == true)

        let missingBlock = OpenVPNParser.extractCertificateBlock(tag: "nonexistent", content: content)
        #expect(missingBlock == nil)
    }

    @Test("Validate balanced and unbalanced XML tags in profile content")
    func testValidateBalancedXMLTags() throws {
        let balanced = "<ca>\nMIIB...\n</ca>"
        #expect(OpenVPNParser.validateBalancedXMLTags(balanced, tag: "ca") == true)

        let unbalanced = "<ca>\nMIIB..."
        #expect(OpenVPNParser.validateBalancedXMLTags(unbalanced, tag: "ca") == false)

        let notPresent = "client\nproto udp"
        #expect(OpenVPNParser.validateBalancedXMLTags(notPresent, tag: "ca") == true)
    }

    @Test("Parse dhcp-option DNS directives into dnsServers array")
    func testParseDNSDirectives() {
        let content = """
        client
        remote 10.8.0.80 1194
        dhcp-option DNS 10.4.20.245
        dhcp-option DNS 10.4.20.246
        """
        let profile = OpenVPNParser.parse(content: content)
        #expect(profile.dnsServers.count == 2)
        #expect(profile.dnsServers.contains("10.4.20.245"))
        #expect(profile.dnsServers.contains("10.4.20.246"))
    }

    @Test("Full tunnel vs split tunnel resolution logic")
    func testFullVsSplitTunnelResolution() {
        // Case 1: route-nopull alone is split
        let splitContent = "client\nremote vpn.example.com 1194\nroute-nopull"
        let splitProfile = OpenVPNParser.parse(content: splitContent)
        #expect(splitProfile.isCampusSplit == true)

        // Case 2: redirect-gateway alone is full tunnel
        let fullContent = "client\nremote vpn.example.com 1194\nredirect-gateway def1"
        let fullProfile = OpenVPNParser.parse(content: fullContent)
        #expect(fullProfile.isCampusSplit == false)

        // Case 3: redirect-gateway overrides route-nopull
        let overrideContent = "client\nremote vpn.example.com 1194\nroute-nopull\nredirect-gateway def1"
        let overrideProfile = OpenVPNParser.parse(content: overrideContent)
        #expect(overrideProfile.isCampusSplit == false)
    }

    @Test("Windows CRLF (\\r\\n) and Unix LF (\\n) produce bit-exact equivalent profile models")
    func testWindowsCRLFEquivalence() {
        let lf = "client\nremote vpn.iiit.ac.in 1194\nproto udp\ncipher AES-128-GCM\nroute-nopull\nroute 10.4.0.0 255.255.0.0\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        let profileLF = OpenVPNParser.parse(content: lf, name: "test")
        let profileCRLF = OpenVPNParser.parse(content: crlf, name: "test")

        #expect(profileLF == profileCRLF)
    }

    @Test("Tokenize line strips leading comments (# and ;) and inline comments preceded by whitespace")
    func testCommentStripping() {
        let lineHash = "# This is a comment"
        #expect(OpenVPNParser.tokenizeLine(lineHash).isEmpty)

        let lineSemicolon = "; Another comment"
        #expect(OpenVPNParser.tokenizeLine(lineSemicolon).isEmpty)

        let lineInline = "remote vpn.example.com 1194 # main server"
        let tokens = OpenVPNParser.tokenizeLine(lineInline)
        #expect(tokens == ["remote", "vpn.example.com", "1194"])
    }

    @Test("Tokenize line handles single and double quotes preserving whitespace and symbols inside quotes")
    func testQuotedTokens() {
        let lineDouble = "remote \"vpn server.iiit.ac.in\" 1194"
        let tokensDouble = OpenVPNParser.tokenizeLine(lineDouble)
        #expect(tokensDouble == ["remote", "vpn server.iiit.ac.in", "1194"])

        let lineSingle = "dev 'tun' cipher 'AES-256-CBC'"
        let tokensSingle = OpenVPNParser.tokenizeLine(lineSingle)
        #expect(tokensSingle == ["dev", "tun", "cipher", "AES-256-CBC"])
    }

    @Test("Throwing parser catches empty content, missing remote, and unclosed XML blocks")
    func testParserErrorHandling() {
        // Empty content
        #expect(throws: OpenVPNParserError.emptyContent) {
            try OpenVPNParser.parseThrowing(content: "   \n\t  ")
        }

        // Missing remote
        #expect(throws: OpenVPNParserError.missingRemoteDirective) {
            try OpenVPNParser.parseThrowing(content: "client\nproto udp\ndev tun\n")
        }

        // Malformed fixture with unclosed <ca> tag
        let malformedPath = fixturesDir + "malformed.ovpn"
        #expect(throws: OpenVPNParserError.self) {
            try OpenVPNParser.parse(filePath: malformedPath)
        }

        // Non-existent file
        #expect(throws: OpenVPNParserError.self) {
            try OpenVPNParser.parse(filePath: "/non/existent/path.ovpn")
        }
    }
}
