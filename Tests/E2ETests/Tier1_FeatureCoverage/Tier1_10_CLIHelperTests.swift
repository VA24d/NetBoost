import Testing
import Foundation

@Suite("Feature 10: CLI Environment Helper Generator", .tags(.tier1, .m2_proxy))
struct Tier1_10_CLIHelperTests {

    enum ShellType: String, CaseIterable {
        case bash
        case zsh
        case fish
    }

    struct CLIHelperGenerator {
        let host: String
        let port: Int

        init(host: String = "127.0.0.1", port: Int = 1080) {
            self.host = host
            self.port = port
        }

        func socks5Export(for shell: ShellType = .zsh) -> String {
            switch shell {
            case .bash, .zsh:
                return "export ALL_PROXY=socks5://\(host):\(port)"
            case .fish:
                return "set -x ALL_PROXY socks5://\(host):\(port)"
            }
        }

        func httpExport(for shell: ShellType = .zsh) -> String {
            switch shell {
            case .bash, .zsh:
                return "export http_proxy=http://\(host):\(port) https_proxy=http://\(host):\(port)"
            case .fish:
                return "set -x http_proxy http://\(host):\(port); set -x https_proxy http://\(host):\(port)"
            }
        }

        func perJobCommand(command: String) -> String {
            "ALL_PROXY=socks5://\(host):\(port) \(command)"
        }
    }

    @Test("T1-F10-01: Generate SOCKS5 export string ALL_PROXY=socks5://127.0.0.1:1080")
    func testGenerateSOCKS5Export() {
        let generator = CLIHelperGenerator(host: "127.0.0.1", port: 1080)
        let zshExport = generator.socks5Export(for: .zsh)
        #expect(zshExport == "export ALL_PROXY=socks5://127.0.0.1:1080")
    }

    @Test("T1-F10-02: Generate HTTP and HTTPS proxy exports")
    func testGenerateHTTPProxyExport() {
        let generator = CLIHelperGenerator(host: "127.0.0.1", port: 1080)
        let httpExport = generator.httpExport(for: .zsh)
        #expect(httpExport.contains("http_proxy=http://127.0.0.1:1080"))
        #expect(httpExport.contains("https_proxy=http://127.0.0.1:1080"))
    }

    @Test("T1-F10-03: Generate inline per-job command prefix")
    func testGeneratePerJobPrefix() {
        let generator = CLIHelperGenerator(host: "127.0.0.1", port: 1080)
        let job = generator.perJobCommand(command: "git clone https://github.com/example/repo.git")
        #expect(job == "ALL_PROXY=socks5://127.0.0.1:1080 git clone https://github.com/example/repo.git")
    }

    @Test("T1-F10-04: Generate multi-shell syntax for Bash, Zsh, and Fish")
    func testMultiShellSyntaxSupport() {
        let generator = CLIHelperGenerator(host: "127.0.0.1", port: 1081)

        let bashOut = generator.socks5Export(for: .bash)
        let zshOut = generator.socks5Export(for: .zsh)
        let fishOut = generator.socks5Export(for: .fish)

        #expect(bashOut.hasPrefix("export ALL_PROXY="))
        #expect(zshOut.hasPrefix("export ALL_PROXY="))
        #expect(fishOut.hasPrefix("set -x ALL_PROXY"))
    }

    @Test("T1-F10-05: Clipboard helper buffer model correctly captures snippet")
    func testClipboardHelperModel() {
        final class MockPasteboard {
            private(set) var stringContent: String?
            func setString(_ str: String) {
                self.stringContent = str
            }
        }

        let pasteboard = MockPasteboard()
        let generator = CLIHelperGenerator(host: "127.0.0.1", port: 1082)
        let snippet = generator.perJobCommand(command: "ssh turing.iiit.ac.in")

        pasteboard.setString(snippet)
        #expect(pasteboard.stringContent == "ALL_PROXY=socks5://127.0.0.1:1082 ssh turing.iiit.ac.in")
    }
}
