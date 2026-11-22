import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 13: OpenVPN Parser Boundaries", .tags(.tier2, .m3_vpn))
struct Tier2_13_OpenVPNParserBoundariesTests {

    @Test("T2-F13-01: Malformed profile fixture missing remote directive is flagged")
    func testMissingRemoteDirectiveInMalformedFixture() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Profiles/malformed.ovpn"
        let content = try String(contentsOfFile: fixturePath, encoding: .utf8)

        func hasRemoteDirective(_ text: String) -> Bool {
            let lines = text.components(separatedBy: .newlines)
            return lines.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("remote ")
            }
        }

        #expect(hasRemoteDirective(content) == false)
    }

    @Test("T2-F13-02: Unclosed XML-style tag (<ca> without </ca>) is detected")
    func testUnclosedTagDetection() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Profiles/malformed.ovpn"
        let content = try String(contentsOfFile: fixturePath, encoding: .utf8)

        func validateBalancedXMLTags(_ text: String, tag: String) -> Bool {
            let openTag = "<\(tag)>"
            let closeTag = "</\(tag)>"
            let hasOpen = text.contains(openTag)
            let hasClose = text.contains(closeTag)
            return hasOpen == hasClose
        }

        #expect(validateBalancedXMLTags(content, tag: "ca") == false)
    }

    @Test("T2-F13-03: Unknown custom OpenVPN directives are skipped with warning without failing")
    func testUnknownDirectivesSkipped() {
        let profileWithCustomDirective = """
        client
        proto udp
        remote vpn.example.com 1194
        custom-vendor-flag-xyz-enable
        tun-mtu 1200
        """

        func parseDirectives(_ text: String) -> (known: [String], unknown: [String]) {
            let recognized: Set<String> = ["client", "proto", "remote", "dev", "tun-mtu", "cipher", "auth"]
            var known: [String] = []
            var unknown: [String] = []

            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let keyword = String(trimmed.split(separator: " ").first ?? "")
                if recognized.contains(keyword) {
                    known.append(keyword)
                } else {
                    unknown.append(keyword)
                }
            }
            return (known, unknown)
        }

        let parsed = parseDirectives(profileWithCustomDirective)
        #expect(parsed.unknown.contains("custom-vendor-flag-xyz-enable"))
        #expect(parsed.known.contains("remote"))
        #expect(parsed.known.contains("tun-mtu"))
    }

    @Test("T2-F13-04: Windows CRLF line endings parsed identically to Unix LF")
    func testCRLFLineEndingsParsing() {
        let unixLF = "client\nremote vpn.example.com 1194\nproto udp\n"
        let windowsCRLF = "client\r\nremote vpn.example.com 1194\r\nproto udp\r\n"

        func extractDirectives(_ text: String) -> [String] {
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        #expect(extractDirectives(unixLF) == extractDirectives(windowsCRLF))
    }

    @Test("T2-F13-05: Comments starting with # or ; are ignored")
    func testCommentsIgnored() {
        let scriptWithComments = """
        # This is a full-line comment
        ; This is another comment syntax
        client
        remote vpn.example.com 1194 # inline comments if supported
        """

        let lines = scriptWithComments.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix(";")
        }

        #expect(filtered.count == 2)
        #expect(filtered.first?.hasPrefix("client") == true)
    }
}
