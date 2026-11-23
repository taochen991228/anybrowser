import Darwin
import Foundation

/// A Profile's proxy, parsed from the address typed in the editor.
public struct ProxyEndpoint: Equatable, Sendable {
    /// http, https or socks5.
    public var scheme: String
    /// Lowercased host name, IPv4 address or bracketed IPv6 address.
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(scheme: String, host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// The value of `--proxy-server`: never contains credentials.
    public var server: String { "\(scheme)://\(host):\(port)" }

    /// The normalized address, credentials included and percent-encoded. Parsing it gives back this
    /// endpoint, so different ways of writing one proxy share a single value.
    public var url: String {
        guard let username else { return server }
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? text }
        return "\(scheme)://\(encode(username)):\(encode(password ?? ""))@\(host):\(port)"
    }

    public var hasCredentials: Bool { username != nil }

    /// Whether the browser reaches this proxy through `ProxyRelay`. The engine signs in to no
    /// proxy in incognito windows or contexts made over DevTools, and to a SOCKS5 proxy not at all.
    public var needsRelay: Bool { hasCredentials }

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Parses `host:port` (HTTP), `host:port:user:password`, or `scheme://host:port`, optionally with
    /// `user:password@` before the host; the password may be empty. `socks5h://` means the same as
    /// `socks5://`: Chromium already leaves name resolution to a SOCKS5 proxy. An empty address means
    /// no proxy (nil).
    ///
    /// A Profile's browser reaches a proxy with credentials through `ProxyRelay`, since the engine
    /// cannot sign in to SOCKS5 at all; a caller without a relay can refuse SOCKS5 credentials with
    /// `allowingSOCKSCredentials: false`.
    public static func parse(_ text: String, allowingSOCKSCredentials: Bool = true) throws -> ProxyEndpoint? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        guard address.utf8.count <= 512 else { throw invalidAddress }

        let explicitScheme = address.contains("://")
        let uri = explicitScheme ? address : "http://\(address)"
        guard let separator = uri.range(of: "://") else { throw invalidAddress }
        var scheme = uri[..<separator.lowerBound].lowercased()
        switch scheme {
        case "socks5h":
            scheme = "socks5"
        case "socks4", "socks4a":
            throw ProfileError.invalid("不支持 SOCKS4 代理：它不能使用账号密码，域名也可能在本机解析。请改用 SOCKS5 或 HTTP 代理。")
        default:
            break
        }
        let authority = uri[separator.upperBound...]
        // Providers also hand out host:port:user:password, with the credentials as they are rather
        // than percent-encoded. A colon inside them makes the fields ambiguous, so only exactly four
        // qualify; IPv6 hosts are bracketed and never match.
        let fields = authority.split(separator: ":", omittingEmptySubsequences: false)
        let listed = fields.count >= 4 && !fields[0].hasPrefix("[") && !fields[0].contains("@")
            && Int(fields[1]).map { (1...65535).contains($0) } == true
        func asListed() throws -> ProxyEndpoint {
            guard fields.count == 4 else {
                throw ProfileError.invalid(
                    "用户名或密码含有冒号时无法按 主机:端口:用户名:密码 识别，请改写成 http://用户名:密码@主机:端口，并把其中的冒号写成 %3A。")
            }
            return try endpoint(scheme: scheme, authority: authority[..<fields[1].endIndex],
                                credentials: try literalCredentials(fields[2], fields[3]),
                                allowingSOCKSCredentials: allowingSOCKSCredentials)
        }
        func asURL() throws -> ProxyEndpoint {
            // The last @ ends the credentials: an @ inside them has to be written as %40.
            guard let at = authority.lastIndex(of: "@") else {
                return try endpoint(scheme: scheme, authority: authority, credentials: nil,
                                    allowingSOCKSCredentials: allowingSOCKSCredentials)
            }
            return try endpoint(scheme: scheme, authority: authority[authority.index(after: at)...],
                                credentials: try credentials(authority[..<at]),
                                allowingSOCKSCredentials: allowingSOCKSCredentials)
        }
        // A line written with a scheme is a URL, whose password may hold a colon; the provider form
        // only applies when it is not one. Without a scheme the provider form wins: read as
        // user:password@host:port it would need a password with an unencoded colon, so an @ in it
        // belongs to the user name or password.
        if explicitScheme {
            do {
                return try asURL()
            } catch {
                guard listed else { throw error }
                return try asListed()
            }
        }
        return try listed ? asListed() : asURL()
    }

    private static var invalidAddress: ProfileError {
        .invalid("代理须为主机:端口、主机:端口:用户名:密码，或以 http://、https://、socks5:// 开头；HTTP 和 HTTPS 代理可带账号密码，例如 http://用户名:密码@主机:端口。")
    }

    private static func endpoint(scheme: String, authority: Substring, credentials: (username: String, password: String)?,
                                 allowingSOCKSCredentials: Bool) throws -> ProxyEndpoint {
        let invalid = invalidAddress
        if let credentials, scheme == "socks5" {
            guard allowingSOCKSCredentials else {
                throw ProfileError.invalid("内核不支持 SOCKS5 代理的账号密码，请改用 HTTP 代理，或去掉用户名和密码。")
            }
            // RFC 1929 gives each a one-byte length.
            guard credentials.username.utf8.count <= 255, credentials.password.utf8.count <= 255 else {
                throw ProfileError.invalid("SOCKS5 代理的用户名和密码各不能超过 255 字节。")
            }
        }
        let location = "\(scheme)://\(authority)"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:/[]")
        guard location.unicodeScalars.allSatisfy(allowed.contains),
              let parts = URLComponents(string: location), parts.scheme == scheme,
              ["http", "https", "socks5"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              let port = parts.port, (1...65535).contains(port),
              parts.path.isEmpty || parts.path == "/" else { throw invalid }
        if host.hasPrefix("[") {
            var ip = in6_addr()
            let literal = String(host.dropFirst().dropLast())
            guard host.hasSuffix("]"), inet_pton(AF_INET6, literal, &ip) == 1 else { throw invalid }
        } else {
            let name = host.hasSuffix(".") ? String(host.dropLast()) : host
            guard name.utf8.count <= 253, name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-"
                    && !$0.contains(":") && !$0.contains("[") && !$0.contains("]")
            }), !name.isEmpty else { throw invalid }
        }
        return ProxyEndpoint(scheme: scheme, host: host, port: port,
                             username: credentials?.username, password: credentials?.password)
    }

    /// The user name and password of a `host:port:user:password` line, taken as they are.
    private static func literalCredentials(_ username: Substring, _ password: Substring) throws -> (username: String, password: String) {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !username.isEmpty, !(username + password).unicodeScalars.contains(where: forbidden.contains) else {
            throw ProfileError.invalid("代理的用户名不能为空，也不能含有空格。")
        }
        return (String(username), String(password))
    }

    /// `user:password`, each percent-decoded; providers that sign in with a key alone leave the
    /// password empty. Only unreserved characters, sub-delimiters and percent escapes may appear as
    /// typed (RFC 3986 userinfo).
    private static func credentials(_ userInfo: Substring) throws -> (username: String, password: String) {
        let typed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:%")
        let parts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, userInfo.unicodeScalars.allSatisfy(typed.contains),
              let username = parts[0].removingPercentEncoding, let password = parts[1].removingPercentEncoding,
              !username.isEmpty,
              // HTTP Basic authentication ends the user name at the first colon.
              !username.contains(":"),
              !(username + password).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalid(
                "代理的用户名不能为空，写成 http://用户名:密码@主机:端口；其中的 @、/、# 等特殊字符请用百分号编码，例如 @ 写成 %40。")
        }
        return (username, password)
    }
}

/// One or more proxies traffic passes through in order: `hops.first` is dialed directly, each
/// subsequent hop is tunnelled through the previous one, and `hops.last` is the exit.
public struct ProxyChain: Equatable, Sendable {
    public static let separator = " -> "

    public var hops: [ProxyEndpoint]

    public init(hops: [ProxyEndpoint]) {
        self.hops = hops
    }

    public var first: ProxyEndpoint { hops[0] }
    public var exit: ProxyEndpoint { hops[hops.count - 1] }
    public var isChained: Bool { hops.count > 1 }

    /// Any multi-hop chain, or a single proxy with credentials, goes through `ProxyRelay`.
    public var needsRelay: Bool { isChained || exit.needsRelay }

    /// Normalized address key for caching and receipts; identical to `exit.url` for a single proxy.
    public var key: String { hops.map(\.url).joined(separator: Self.separator) }

    /// Human-readable route without credentials.
    public var summary: String { hops.map(\.server).joined(separator: " → ") }

    /// Parses an exit proxy with an optional transit (first-hop) proxy.
    public static func parse(proxy: String, transitProxy: String = "",
                             allowingSOCKSCredentials: Bool = true) throws -> ProxyChain? {
        let exitEndpoint = try ProxyEndpoint.parse(proxy, allowingSOCKSCredentials: allowingSOCKSCredentials)
        let transitEndpoint = try ProxyEndpoint.parse(transitProxy, allowingSOCKSCredentials: allowingSOCKSCredentials)
        guard let exitEndpoint else {
            if transitEndpoint != nil {
                throw ProfileError.invalid("填写前置中转代理时，必须同时填写代理地址。")
            }
            return nil
        }
        guard let transitEndpoint else { return ProxyChain(hops: [exitEndpoint]) }
        guard exitEndpoint.scheme != "https" else {
            throw ProfileError.invalid("链式代理的出口代理目前支持 HTTP 和 SOCKS5，暂不支持 HTTPS 代理作为第二跳。")
        }
        return ProxyChain(hops: [transitEndpoint, exitEndpoint])
    }

    /// Combines `proxy` and optional `transitProxy` into one lookup/cache string (`proxy` alone when
    /// unchained, or `transitProxy -> proxy` when chained).
    public static func spec(proxy: String, transitProxy: String = "") -> String {
        let exitText = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        let transitText = transitProxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transitText.isEmpty else { return exitText }
        return "\(transitText)\(separator)\(exitText)"
    }

    /// Parses either a single proxy address or a `hop1 -> hop2` chain specification.
    public static func parse(spec text: String, allowingSOCKSCredentials: Bool = true) throws -> ProxyChain? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains(separator) else {
            return try ProxyEndpoint.parse(trimmed, allowingSOCKSCredentials: allowingSOCKSCredentials)
                .map { ProxyChain(hops: [$0]) }
        }
        let parts = trimmed.components(separatedBy: separator)
        var hops: [ProxyEndpoint] = []
        for (index, part) in parts.enumerated() {
            guard let endpoint = try ProxyEndpoint.parse(part, allowingSOCKSCredentials: allowingSOCKSCredentials) else {
                throw ProfileError.invalid("链式代理包含空的节点地址。")
            }
            if index > 0, endpoint.scheme == "https" {
                throw ProfileError.invalid("链式代理的后续节点目前支持 HTTP 和 SOCKS5，暂不支持 HTTPS 代理作为后续跳。")
            }
            hops.append(endpoint)
        }
        return hops.isEmpty ? nil : ProxyChain(hops: hops)
    }
}

/// Where a Profile's traffic leaves for the internet, as reported by an IP lookup service.
public struct ProxyExit: Codable, Equatable, Sendable {
    public var ip: String
    /// ISO 3166-1 alpha-2, uppercased; empty when unknown.
    public var countryCode: String
    public var region: String
    public var city: String
    /// IANA time zone; empty when unknown.
    public var timeZone: String
    /// BCP 47 language tags, most common first; may be empty.
    public var languages: [String]

    public init(ip: String, countryCode: String = "", region: String = "", city: String = "",
                timeZone: String = "", languages: [String] = []) {
        self.ip = ip
        self.countryCode = countryCode
        self.region = region
        self.city = city
        self.timeZone = timeZone
        self.languages = languages
    }

    /// Matches a fingerprint's time zone and language to this exit, keeping what it does not know.
    public func apply(to fingerprint: inout FingerprintSettings) {
        if !timeZone.isEmpty { fingerprint.timeZone = timeZone }
        if let language = languages.first { fingerprint.language = language }
    }
}
