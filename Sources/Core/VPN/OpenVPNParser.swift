import Foundation

/// Errors that can occur during OpenVPN profile parsing.
public enum OpenVPNParserError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case unreadableFile(String, String)
    case missingRemoteDirective
    case unclosedBlock(tag: String, line: Int)
    case emptyContent
    case invalidRouteDirective(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "OpenVPN profile file not found at path: \(path)"
        case .unreadableFile(let path, let details):
            return "Failed to read OpenVPN profile at \(path): \(details)"
        case .missingRemoteDirective:
            return "Profile is missing mandatory 'remote' server address directive."
        case .unclosedBlock(let tag, let line):
            return "Unclosed XML block <\(tag)> encountered at line \(line)."
        case .emptyContent:
            return "OpenVPN profile content is empty."
        case .invalidRouteDirective(let line):
            return "Invalid route directive syntax: \(line)"
        }
    }
}

/// Parsed directives representation for inspection.
public struct ParsedOpenVPNDirectives: Sendable {
    public var remoteHost: String?
    public var remotePort: Int = 1194
    public var proto: String = "udp"
    public var dev: String = "tun"
    public var tunMtu: Int?
    public var cipher: String?
    public var auth: String?
    public var routes: [VPNRouteEntry] = []
    public var dnsServers: [String] = []
    public var isRouteNoPull: Bool = false
    public var redirectGateway: Bool = false
    public var verb: Int = 3
    public var certificates: [String: String] = [:]
    public var knownDirectives: [String] = []
    public var unknownDirectives: [String] = []

    public init() {}
}

/// Robust OpenVPN configuration (.ovpn) lexer and parser.
public final class OpenVPNParser: Sendable {

    /// Standard recognized OpenVPN directives.
    public static let recognizedDirectives: Set<String> = [
        "client", "proto", "remote", "dev", "tun-mtu", "cipher", "auth",
        "route", "route-nopull", "redirect-gateway", "dhcp-option",
        "verb", "nobind", "persist-key", "persist-tun", "resolv-retry",
        "auth-user-pass", "auth-retry", "remote-cert-tls", "verify-x509-name",
        "tls-client", "tls-version-min", "tls-cipher", "explicit-exit-notify"
    ]

    /// Tolerant parser that extracts VPNProfileInfo from configuration string.
    public static func parse(content: String, name: String = "profile", filePath: String? = nil) -> VPNProfileInfo {
        var server = ""
        var proto = "udp"
        var port = 1194
        var cipher: String?
        var routes: [VPNRouteEntry] = []
        var isSplit = false
        var redirectGateway = false
        var dnsServers: [String] = []

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let tokens = tokenizeLine(line)
            guard let first = tokens.first else { continue }

            switch first {
            case "remote":
                if tokens.count >= 2 { server = tokens[1] }
                if tokens.count >= 3 { port = Int(tokens[2]) ?? 1194 }
                if tokens.count >= 4 { proto = tokens[3].lowercased() }
            case "proto":
                if tokens.count >= 2 { proto = tokens[1].lowercased() }
            case "cipher":
                if tokens.count >= 2 { cipher = tokens[1] }
            case "route-nopull":
                isSplit = true
            case "redirect-gateway":
                redirectGateway = true
            case "route":
                if tokens.count >= 3 {
                    let gw = tokens.count >= 4 ? tokens[3] : nil
                    routes.append(VPNRouteEntry(destinationSubnet: tokens[1], mask: tokens[2], gateway: gw))
                }
            case "dhcp-option":
                if tokens.count >= 3 && tokens[1].uppercased() == "DNS" {
                    dnsServers.append(tokens[2])
                }
            default:
                break
            }
        }

        // If redirect-gateway is specified, it is a full tunnel regardless of route-nopull
        let effectiveSplit = isSplit && !redirectGateway

        return VPNProfileInfo(
            name: name,
            serverAddress: server,
            proto: proto,
            port: port,
            cipher: cipher,
            routes: routes,
            dnsServers: dnsServers,
            isCampusSplit: effectiveSplit,
            filePath: filePath
        )
    }

    /// Strict parser that validates mandatory directives and balanced XML blocks, throwing on malformed content.
    public static func parseThrowing(content: String, name: String = "profile", filePath: String? = nil) throws -> VPNProfileInfo {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenVPNParserError.emptyContent
        }

        let commonTags = ["ca", "cert", "key", "tls-auth", "tls-crypt"]
        let lines = content.components(separatedBy: .newlines)
        for tag in commonTags {
            if !validateBalancedXMLTags(content, tag: tag) {
                // Find line number of opening tag
                var lineNum = 1
                for (idx, line) in lines.enumerated() {
                    if line.contains("<\(tag)>") {
                        lineNum = idx + 1
                        break
                    }
                }
                throw OpenVPNParserError.unclosedBlock(tag: tag, line: lineNum)
            }
        }

        let profile = parse(content: content, name: name, filePath: filePath)
        guard !profile.serverAddress.isEmpty else {
            throw OpenVPNParserError.missingRemoteDirective
        }

        return profile
    }

    /// Reads and parses an OpenVPN profile from a file URL.
    public static func parse(fileURL: URL) throws -> VPNProfileInfo {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw OpenVPNParserError.fileNotFound(path)
        }
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return try parseThrowing(content: content, name: fileURL.lastPathComponent, filePath: path)
        } catch let err as OpenVPNParserError {
            throw err
        } catch {
            throw OpenVPNParserError.unreadableFile(path, error.localizedDescription)
        }
    }

    /// Reads and parses an OpenVPN profile from a file path string.
    public static func parse(filePath: String) throws -> VPNProfileInfo {
        try parse(fileURL: URL(fileURLWithPath: filePath))
    }

    /// Extracts embedded XML block content bounded by `<tag>` and `</tag>`.
    public static func extractCertificateBlock(tag: String, content: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let startRange = content.range(of: openTag),
              let endRange = content.range(of: closeTag, range: startRange.upperBound..<content.endIndex) else {
            return nil
        }
        return String(content[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validates that `<tag>` and `</tag>` occurrences are balanced.
    public static func validateBalancedXMLTags(_ text: String, tag: String) -> Bool {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        let openCount = text.components(separatedBy: openTag).count - 1
        let closeCount = text.components(separatedBy: closeTag).count - 1
        return openCount == closeCount
    }

    /// Tokenizes a single line respecting double and single quotes, and stripping comments.
    public static func tokenizeLine(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { return [] }

        var tokens: [String] = []
        var currentToken = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        let chars = Array(trimmed)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if isEscaped {
                currentToken.append(c)
                isEscaped = false
                i += 1
                continue
            }

            if c == "\\" {
                isEscaped = true
                i += 1
                continue
            }

            if c == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                i += 1
                continue
            }

            if c == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                i += 1
                continue
            }

            if !inSingleQuote && !inDoubleQuote {
                // Check for inline comment preceded by whitespace
                if (c == "#" || c == ";") && currentToken.isEmpty {
                    break
                }

                if c == " " || c == "\t" {
                    if !currentToken.isEmpty {
                        tokens.append(currentToken)
                        currentToken = ""
                    }
                    i += 1
                    continue
                }
            }

            currentToken.append(c)
            i += 1
        }

        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }

        return tokens
    }
}
