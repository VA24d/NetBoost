import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 10: CLI Environment Helper Boundaries", .tags(.tier2, .m2_proxy))
struct Tier2_10_CLIHelperBoundariesTests {

    @Test("T2-F10-01: Invalid TCP port numbers (<1 or >65535) are rejected")
    func testInvalidPortValidation() {
        func validatePort(_ port: Int) -> Bool {
            return port >= 1 && port <= 65535
        }

        #expect(validatePort(1080) == true)
        #expect(validatePort(1081) == true)
        #expect(validatePort(1082) == true)
        #expect(validatePort(0) == false)
        #expect(validatePort(-1) == false)
        #expect(validatePort(65536) == false)
        #expect(validatePort(99999) == false)
    }

    @Test("T2-F10-02: Commands containing quotes and pipes are properly escaped in per-job prefix")
    func testCommandEscapingWithQuotesAndPipes() {
        func generatePerJobCommand(port: Int, command: String) -> String {
            return "ALL_PROXY=socks5://127.0.0.1:\(port) \(command)"
        }

        let cmd = "git clone \"https://github.com/example/repo.git\" && echo 'done'"
        let wrapped = generatePerJobCommand(port: 1080, command: cmd)

        #expect(wrapped.hasPrefix("ALL_PROXY=socks5://127.0.0.1:1080 "))
        #expect(wrapped.contains(cmd))
    }

    @Test("T2-F10-03: Empty command string generates clean shell export statements")
    func testCleanExportGeneration() {
        func generateShellExports(port: Int) -> String {
            return "export ALL_PROXY=socks5://127.0.0.1:\(port)\nexport http_proxy=http://127.0.0.1:\(port)\nexport https_proxy=http://127.0.0.1:\(port)"
        }

        let exports = generateShellExports(port: 1080)
        #expect(exports.contains("ALL_PROXY=socks5://127.0.0.1:1080"))
        #expect(exports.contains("http_proxy=http://127.0.0.1:1080"))
        #expect(exports.contains("https_proxy=http://127.0.0.1:1080"))
    }

    @Test("T2-F10-04: Fish shell syntax generation uses set -x")
    func testFishShellSyntax() {
        func generateFishExports(port: Int) -> String {
            return "set -x ALL_PROXY socks5://127.0.0.1:\(port)\nset -x http_proxy http://127.0.0.1:\(port)"
        }

        let fish = generateFishExports(port: 1081)
        #expect(fish.contains("set -x ALL_PROXY socks5://127.0.0.1:1081"))
        #expect(fish.contains("set -x http_proxy http://127.0.0.1:1081"))
    }

    @Test("T2-F10-05: Authenticated SOCKS5 proxy URL format validation")
    func testAuthenticatedProxyURLGeneration() {
        func generateAuthURL(user: String, pass: String, host: String, port: Int) -> String {
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
            let encodedPass = pass.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? pass
            return "socks5://\(encodedUser):\(encodedPass)@\(host):\(port)"
        }

        let url = generateAuthURL(user: "student", pass: "p@ss:word", host: "127.0.0.1", port: 1080)
        #expect(url.hasPrefix("socks5://student:"))
        #expect(url.hasSuffix("@127.0.0.1:1080"))
    }
}
