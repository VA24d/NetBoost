import Foundation

public struct ShellEnvGenerator: Sendable {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int = 1080) {
        self.host = host
        self.port = port
    }

    /// Validates whether a port number is in the valid TCP range (1...65535).
    public static func validatePort(_ port: Int) -> Bool {
        return port >= 1 && port <= 65535
    }

    /// Generates SOCKS5 export command for the specified shell.
    public func socks5Export(for shell: ShellType = .zsh) -> String {
        switch shell {
        case .bash, .zsh:
            return "export ALL_PROXY=socks5://\(host):\(port)"
        case .fish:
            return "set -x ALL_PROXY socks5://\(host):\(port)"
        }
    }

    /// Generates HTTP/HTTPS proxy export commands for the specified shell.
    public func httpExport(for shell: ShellType = .zsh) -> String {
        switch shell {
        case .bash, .zsh:
            return "export http_proxy=http://\(host):\(port) https_proxy=http://\(host):\(port)"
        case .fish:
            return "set -x http_proxy http://\(host):\(port); set -x https_proxy http://\(host):\(port)"
        }
    }

    /// Generates all standard proxy export commands for full environment configuration.
    public func allExports(for shell: ShellType = .zsh) -> String {
        switch shell {
        case .bash, .zsh:
            return """
            export ALL_PROXY=socks5://\(host):\(port)
            export all_proxy=socks5://\(host):\(port)
            export HTTP_PROXY=http://\(host):\(port)
            export http_proxy=http://\(host):\(port)
            export HTTPS_PROXY=http://\(host):\(port)
            export https_proxy=http://\(host):\(port)
            export NO_PROXY=localhost,127.0.0.1,10.0.0.0/8
            export no_proxy=localhost,127.0.0.1,10.0.0.0/8
            """
        case .fish:
            return """
            set -x ALL_PROXY socks5://\(host):\(port)
            set -x all_proxy socks5://\(host):\(port)
            set -x HTTP_PROXY http://\(host):\(port)
            set -x http_proxy http://\(host):\(port)
            set -x HTTPS_PROXY http://\(host):\(port)
            set -x https_proxy http://\(host):\(port)
            set -x NO_PROXY localhost,127.0.0.1,10.0.0.0/8
            set -x no_proxy localhost,127.0.0.1,10.0.0.0/8
            """
        }
    }

    /// Generates a per-job inline proxy execution prefix: `ALL_PROXY=socks5://127.0.0.1:<port> <command>`.
    public func perJobCommand(command: String) -> String {
        return "ALL_PROXY=socks5://\(host):\(port) \(command)"
    }

    /// Generates a static per-job inline proxy execution prefix for a given port.
    public static func perJobCommand(port: Int, host: String = "127.0.0.1", command: String) -> String {
        return "ALL_PROXY=socks5://\(host):\(port) \(command)"
    }

    /// Generates CLI wrapper command: `netboost run --interface <interface> <command>`.
    public static func netboostRunCommand(interface: String, command: String) -> String {
        return "netboost run --interface \(interface) \(command)"
    }

    /// Generates authenticated SOCKS5 URL with percent-encoded credentials.
    public static func authenticatedSocks5URL(
        user: String,
        pass: String,
        host: String = "127.0.0.1",
        port: Int
    ) -> String {
        let allowedCharacters = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/"))
        let encodedUser = user.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? user
        let encodedPass = pass.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? pass
        return "socks5://\(encodedUser):\(encodedPass)@\(host):\(port)"
    }
}
