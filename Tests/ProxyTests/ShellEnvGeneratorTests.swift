import Foundation
import Testing
@testable import NetBoostCore

@Suite("Shell Environment Generator Unit Tests")
struct ShellEnvGeneratorTests {

    @Test("TCP port boundary validation (1...65535)")
    func testPortValidation() {
        #expect(ShellEnvGenerator.validatePort(1080) == true)
        #expect(ShellEnvGenerator.validatePort(1081) == true)
        #expect(ShellEnvGenerator.validatePort(1082) == true)
        #expect(ShellEnvGenerator.validatePort(1) == true)
        #expect(ShellEnvGenerator.validatePort(80) == true)
        #expect(ShellEnvGenerator.validatePort(443) == true)
        #expect(ShellEnvGenerator.validatePort(65535) == true)

        #expect(ShellEnvGenerator.validatePort(0) == false)
        #expect(ShellEnvGenerator.validatePort(-1) == false)
        #expect(ShellEnvGenerator.validatePort(65536) == false)
        #expect(ShellEnvGenerator.validatePort(99999) == false)
    }

    @Test("SOCKS5 export statement generation for Bash, Zsh, and Fish")
    func testSocks5Export() {
        let generator = ShellEnvGenerator(host: "127.0.0.1", port: 1080)

        let zsh = generator.socks5Export(for: .zsh)
        #expect(zsh == "export ALL_PROXY=socks5://127.0.0.1:1080")

        let bash = generator.socks5Export(for: .bash)
        #expect(bash == "export ALL_PROXY=socks5://127.0.0.1:1080")

        let fish = generator.socks5Export(for: .fish)
        #expect(fish == "set -x ALL_PROXY socks5://127.0.0.1:1080")
    }

    @Test("HTTP proxy export statement generation")
    func testHttpExport() {
        let generator = ShellEnvGenerator(host: "127.0.0.1", port: 1081)

        let zsh = generator.httpExport(for: .zsh)
        #expect(zsh == "export http_proxy=http://127.0.0.1:1081 https_proxy=http://127.0.0.1:1081")

        let fish = generator.httpExport(for: .fish)
        #expect(fish == "set -x http_proxy http://127.0.0.1:1081; set -x https_proxy http://127.0.0.1:1081")
    }

    @Test("Full environment export block containing uppercase and lowercase variables")
    func testAllExports() {
        let generator = ShellEnvGenerator(host: "127.0.0.1", port: 1080)

        let zshBlock = generator.allExports(for: .zsh)
        #expect(zshBlock.contains("ALL_PROXY=socks5://127.0.0.1:1080"))
        #expect(zshBlock.contains("all_proxy=socks5://127.0.0.1:1080"))
        #expect(zshBlock.contains("HTTP_PROXY=http://127.0.0.1:1080"))
        #expect(zshBlock.contains("http_proxy=http://127.0.0.1:1080"))
        #expect(zshBlock.contains("HTTPS_PROXY=http://127.0.0.1:1080"))
        #expect(zshBlock.contains("https_proxy=http://127.0.0.1:1080"))
        #expect(zshBlock.contains("NO_PROXY=localhost,127.0.0.1,10.0.0.0/8"))

        let fishBlock = generator.allExports(for: .fish)
        #expect(fishBlock.contains("set -x ALL_PROXY socks5://127.0.0.1:1080"))
        #expect(fishBlock.contains("set -x HTTP_PROXY http://127.0.0.1:1080"))
    }

    @Test("Per-job command prefix generation preserves quotes and pipes")
    func testPerJobCommand() {
        let generator = ShellEnvGenerator(host: "127.0.0.1", port: 1080)
        let command = "git clone \"https://turing.iiit.ac.in/repo.git\" && echo 'done'"
        let wrapped = generator.perJobCommand(command: command)

        #expect(wrapped == "ALL_PROXY=socks5://127.0.0.1:1080 git clone \"https://turing.iiit.ac.in/repo.git\" && echo 'done'")

        let staticWrapped = ShellEnvGenerator.perJobCommand(port: 1082, command: "curl -s http://example.com | grep status")
        #expect(staticWrapped == "ALL_PROXY=socks5://127.0.0.1:1082 curl -s http://example.com | grep status")
    }

    @Test("NetBoost run CLI command wrapper")
    func testNetboostRunCommand() {
        let cmd1 = ShellEnvGenerator.netboostRunCommand(interface: "en10", command: "git fetch origin")
        #expect(cmd1 == "netboost run --interface en10 git fetch origin")

        let cmd2 = ShellEnvGenerator.netboostRunCommand(interface: "en0", command: "curl -O https://cdn.example.com/file")
        #expect(cmd2 == "netboost run --interface en0 curl -O https://cdn.example.com/file")

        let cmd3 = ShellEnvGenerator.netboostRunCommand(interface: "auto", command: "brew update")
        #expect(cmd3 == "netboost run --interface auto brew update")
    }

    @Test("Authenticated SOCKS5 URL generation with percent-encoding")
    func testAuthenticatedSocks5URL() {
        let plain = ShellEnvGenerator.authenticatedSocks5URL(user: "admin", pass: "secret123", host: "127.0.0.1", port: 1080)
        #expect(plain == "socks5://admin:secret123@127.0.0.1:1080")

        let encoded = ShellEnvGenerator.authenticatedSocks5URL(user: "student@iiit", pass: "p@ss:word!", host: "127.0.0.1", port: 1080)
        #expect(encoded.contains("%40"))
        #expect(encoded.contains("%3A"))
        #expect(encoded.hasPrefix("socks5://"))
        #expect(encoded.hasSuffix("@127.0.0.1:1080"))
    }
}
