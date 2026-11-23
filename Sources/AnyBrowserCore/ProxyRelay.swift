import Foundation
import Network
import Security

/// A proxy on 127.0.0.1 without sign-in that hands every connection to one upstream proxy and signs in
/// there. Chromium cannot sign in to a SOCKS5 proxy, and answers an HTTP proxy's challenge only
/// through an extension, which never runs in incognito windows or in contexts made with
/// `Target.createBrowserContext`; a `--proxy-server` pointing at the relay works in all of them.
///
/// To the browser it is an HTTP proxy. CONNECT requests are tunnelled with the host name kept, so the
/// upstream resolves it; absolute-form requests (plain http://) are forwarded one per connection, so
/// that each one carries the sign-in. Like the debugging port, the relay serves any program on this Mac.
public final class ProxyRelay: @unchecked Sendable {
    /// Why the upstream did not carry a connection, as the browser learns it from the relay's status.
    public enum Failure: Error, Equatable, Sendable {
        /// The upstream refused the user name or password (407, or RFC 1929 failure).
        case credentialsRejected
        /// The upstream asks for a user name and password and the address has none.
        case credentialsRequired
        /// No connection to the upstream itself, with the system's reason.
        case unreachable(String)
        /// The upstream would not connect to the destination, with its reason.
        case refused(String)
        case timedOut
        /// The upstream answered something that is not HTTP or SOCKS5.
        case invalidResponse

        public var message: String {
            switch self {
            case .credentialsRejected: return "上游代理拒绝了用户名或密码。"
            case .credentialsRequired: return "上游代理要求登录，请在代理地址里填写用户名和密码。"
            case .unreachable(let reason): return "无法连接上游代理：\(reason)。"
            case .refused(let reason): return "上游代理拒绝了这个连接：\(reason)。"
            case .timedOut: return "上游代理没有及时响应。"
            case .invalidResponse: return "上游代理的响应无法识别。"
            }
        }

        /// 407 without a challenge, so the browser shows an error instead of a sign-in dialog that
        /// could only reach the relay.
        var status: Int {
            switch self {
            case .credentialsRejected, .credentialsRequired: return 407
            case .timedOut: return 504
            case .unreachable, .refused, .invalidResponse: return 502
            }
        }
    }

    /// Ordered proxy hops from first hop (dialed directly) to final exit proxy.
    public let chain: [ProxyEndpoint]
    /// The exit proxy (final hop in `chain`).
    public var upstream: ProxyEndpoint { chain[chain.count - 1] }
    /// How long the upstream chain may take to open a tunnel or answer a forwarded request's headers.
    public let connectTimeout: TimeInterval
    /// Called on a relay queue for every failed connection, with the destination it was for.
    public var failureHandler: (@Sendable (Failure, String) -> Void)?

    /// Trust decisions for an HTTPS first-hop upstream; nil keeps the system's certificate checks.
    var verifyUpstream: (@Sendable (sec_trust_t) -> Bool)?

    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: Int?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var latestFailure: Failure?
    private let listenerQueue = DispatchQueue(label: "anybrowser.relay.listener")

    static let maximumHead = 65_536

    /// `upstream` must be an http, https or socks5 proxy; credentials are optional.
    public convenience init(upstream: ProxyEndpoint, connectTimeout: TimeInterval = 15) throws {
        try self.init(chain: [upstream], connectTimeout: connectTimeout)
    }

    /// A single proxy or a multi-hop chain (`chain.first` is dialed directly; subsequent hops must
    /// be http or socks5 and are tunnelled through the previous hop).
    public init(chain: [ProxyEndpoint], connectTimeout: TimeInterval = 15) throws {
        guard !chain.isEmpty else {
            throw ProfileError.invalid("代理链不能为空。")
        }
        for (index, hop) in chain.enumerated() {
            let allowed = index == 0 ? ["http", "https", "socks5"] : ["http", "socks5"]
            guard allowed.contains(hop.scheme),
                  (1...65535).contains(hop.port), !hop.host.isEmpty else {
                throw ProfileError.invalid(index == 0
                    ? "代理中继只支持 HTTP、HTTPS 和 SOCKS5 上游代理。"
                    : "链式代理的后续节点目前只支持 HTTP 和 SOCKS5 代理。")
            }
            if hop.scheme == "socks5", hop.username.map({ $0.utf8.count > 255 }) == true
                || hop.password.map({ $0.utf8.count > 255 }) == true {
                throw ProfileError.invalid("SOCKS5 代理的用户名和密码各不能超过 255 字节。")
            }
        }
        self.chain = chain
        self.connectTimeout = connectTimeout
    }

    deinit {
        listener?.cancel()
    }

    /// The port the relay listens on once started.
    public var port: Int? { locked { boundPort } }

    /// The value for `--proxy-server` once started.
    public var server: String? { port.map { "http://127.0.0.1:\($0)" } }

    /// The most recent failure, if any connection has failed.
    public var lastFailure: Failure? { locked { latestFailure } }

    /// Connections currently open from the browser.
    var openSessions: Int { locked { sessions.count } }

    /// Starts listening on 127.0.0.1, on `port` or one the system picks, and returns the port.
    @discardableResult
    public func start(port: Int = 0) async throws -> Int {
        let parameters = NWParameters.tcp
        guard let local = NWEndpoint.Port(rawValue: UInt16(clamping: port)), (0...65535).contains(port) else {
            throw ProfileError.invalid("代理中继的端口无效。")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: local)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ProfileError.invalid("无法启动本机代理中继：\(error.localizedDescription)")
        }
        try locked {
            guard self.listener == nil else { throw ProfileError.invalid("代理中继已经启动。") }
            self.listener = listener
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.accept(connection)
        }
        let bound: Int
        do {
            bound = try await withCheckedThrowingContinuation { continuation in
                // Cleared on the first final state, so the continuation resumes once.
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        listener.cancel()
                        continuation.resume(throwing: ProfileError.invalid("无法启动本机代理中继：\(error.localizedDescription)"))
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: ProfileError.invalid("代理中继已停止。"))
                    default:
                        break
                    }
                }
                listener.start(queue: listenerQueue)
            }
        } catch {
            // A listener that never became ready leaves the relay free to start again.
            locked { if self.listener === listener { self.listener = nil } }
            throw error
        }
        locked { boundPort = bound }
        return bound
    }

    /// Stops listening and closes every open connection.
    public func stop() {
        let (listener, open) = locked { () -> (NWListener?, [Session]) in
            defer {
                self.listener = nil
                sessions = [:]
            }
            return (self.listener, Array(sessions.values))
        }
        listener?.cancel()
        for session in open { session.queue.async { session.close() } }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(relay: self, client: connection)
        let open = locked { () -> Bool in
            guard listener != nil else { return false }
            sessions[ObjectIdentifier(session)] = session
            return true
        }
        guard open else { return connection.cancel() }
        session.begin()
    }

    fileprivate func ended(_ session: Session) {
        locked { _ = sessions.removeValue(forKey: ObjectIdentifier(session)) }
    }

    fileprivate func report(_ failure: Failure, target: String) {
        locked { latestFailure = failure }
        failureHandler?(failure, target)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// One connection from the browser and the upstream connection carrying it. Everything runs on `queue`.
private final class Session {
    private enum Request {
        /// A tunnel to host:port; `headers` are the browser's, for an HTTP upstream to see as usual.
        case connect(host: String, port: Int, headers: [String])
        /// An absolute-form request for http://host:port; `head` is the request to send on.
        case forward(host: String, port: Int, head: [String])
    }

    let queue = DispatchQueue(label: "anybrowser.relay.session", target: .global(qos: .userInitiated))
    private let relay: ProxyRelay
    private let client: NWConnection
    private var upstream: NWConnection?
    private var clientBuffer = Data()
    private var upstreamBuffer = Data()
    private var clientEnded = false
    private var upstreamEnded = false
    private var target = ""
    private var timer: DispatchWorkItem?
    private var openDirections = 2
    private var tunnelled = false
    private var closed = false
    /// Set once an error status is on its way to the browser; nothing else may follow it.
    private var answered = false

    private var active: Bool { !closed && !answered }

    private static let headEnd = Data("\r\n\r\n".utf8)

    init(relay: ProxyRelay, client: NWConnection) {
        self.relay = relay
        self.client = client
    }

    func begin() {
        // Once tunnelling, the copying notices a failed side itself, after passing on what arrived.
        client.stateUpdateHandler = { [self] state in
            if case .failed = state, !tunnelled { close() }
        }
        client.start(queue: queue)
        readClientHead()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        relay.ended(self)
    }

    // MARK: The browser's request

    private func readClientHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            guard active else { return }
            if let data { clientBuffer.append(data) }
            if let end = clientBuffer.range(of: Self.headEnd) {
                clientEnded = isComplete
                let head = String(decoding: clientBuffer[..<end.lowerBound], as: UTF8.self)
                clientBuffer = Data(clientBuffer[end.upperBound...])
                handle(head)
            } else if clientBuffer.count > ProxyRelay.maximumHead {
                respond(431, "请求头过大。")
            } else if isComplete || error != nil {
                close()
            } else {
                readClientHead()
            }
        }
    }

    private func handle(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), !start[0].isEmpty else {
            return respond(400, "无法识别的请求。")
        }
        // The relay signs in itself; whatever the browser sent for that is not passed on.
        let headers = { (dropping: Set<String>) in
            lines.dropFirst().filter { !dropping.contains($0.prefix { $0 != ":" }.lowercased()) }
        }
        let request: Request
        if start[0].uppercased() == "CONNECT" {
            guard let authority = Self.authority(start[1]) else { return respond(400, "CONNECT 的目标地址无效。") }
            target = start[1]
            request = .connect(host: authority.host, port: authority.port, headers: headers(["proxy-authorization"]))
        } else {
            guard start[1].lowercased().hasPrefix("http://") else {
                return respond(400, "代理中继只转发 http:// 请求，其他请求请使用 CONNECT。")
            }
            let remainder = start[1].dropFirst("http://".count)
            let split = remainder.firstIndex { $0 == "/" || $0 == "?" } ?? remainder.endIndex
            guard let authority = Self.authority(String(remainder[..<split]), defaultPort: 80) else {
                return respond(400, "请求的网址无效。")
            }
            target = start[1]
            // Each forwarded request goes out on its own connection, so it always carries the sign-in.
            let forwarded = headers(["proxy-authorization", "proxy-connection", "connection", "keep-alive"])
                + ["Connection: close"]
            let path = remainder[split...]
            let origin = path.isEmpty ? "/" : path.hasPrefix("?") ? "/" + path : String(path)
            request = .forward(host: authority.host, port: authority.port,
                               head: ["\(start[0]) \(relay.upstream.scheme == "socks5" ? origin : start[1]) \(start[2])"] + forwarded)
        }
        connectUpstream(for: request)
    }

    /// `host:port`, with IPv6 addresses in brackets; the host comes back without them.
    private static func authority(_ text: String, defaultPort: Int? = nil) -> (host: String, port: Int)? {
        var host = Substring(text)
        var port = defaultPort
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                port = Int(rest.dropFirst())
            }
        } else if let colon = text.lastIndex(of: ":") {
            host = text[..<colon]
            port = Int(text[text.index(after: colon)...])
        }
        guard let port, (1...65535).contains(port), !host.isEmpty, host.utf8.count <= 255,
              !host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f || "/@\\".unicodeScalars.contains($0) })
        else { return nil }
        return (String(host), port)
    }

    // MARK: The upstream

    private func connectUpstream(for request: Request) {
        let endpoint = relay.chain[0]
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(relay.connectTimeout.rounded(.up)))
        var tls: NWProtocolTLS.Options?
        if endpoint.scheme == "https" {
            let options = NWProtocolTLS.Options()
            if let verify = relay.verifyUpstream {
                sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                    complete(verify(trust))
                }, queue)
            }
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        let host = endpoint.host.hasPrefix("[") ? String(endpoint.host.dropFirst().dropLast()) : endpoint.host
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(endpoint.port))!,
                                      using: parameters)
        upstream = connection
        let timer = DispatchWorkItem { [self] in fail(.timedOut) }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + relay.connectTimeout, execute: timer)
        var opened = false
        connection.stateUpdateHandler = { [self] state in
            guard active else { return }
            switch state {
            case .ready where !opened:
                opened = true
                handshake(hopIndex: 0, for: request)
            // A refused connection waits for the network to change; nothing will change for a proxy.
            case .waiting(let error) where !opened, .failed(let error) where !opened:
                fail(.unreachable("\(endpoint.host):\(endpoint.port) \(error.localizedDescription)"))
            // Later failures reach the pending receive or send, which handles them in order.
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func authorization(for hop: ProxyEndpoint) -> String? {
        guard let username = hop.username else { return nil }
        return "Proxy-Authorization: Basic " + Data("\(username):\(hop.password ?? "")".utf8).base64EncodedString()
    }

    /// Walks each hop in `relay.chain`: intermediate hops open a raw tunnel to the next hop, and
    /// the final hop carries the browser's actual request. Any hop failing aborts the connection
    /// without ever falling back to a direct or shorter path.
    private func handshake(hopIndex: Int, for request: Request) {
        let hop = relay.chain[hopIndex]
        if hopIndex < relay.chain.count - 1 {
            let next = relay.chain[hopIndex + 1]
            let nextHost = next.host.hasPrefix("[") ? String(next.host.dropFirst().dropLast()) : next.host
            let advance: () -> Void = { [self] in handshake(hopIndex: hopIndex + 1, for: request) }
            if hop.scheme == "socks5" {
                greetSOCKS(through: hop, targetHost: nextHost, targetPort: next.port, then: advance)
            } else {
                tunnelHTTP(through: hop, targetHost: nextHost, targetPort: next.port, then: advance)
            }
            return
        }
        if hop.scheme == "socks5" {
            let (host, port): (String, Int)
            switch request {
            case let .connect(name, number, _), let .forward(name, number, _): (host, port) = (name, number)
            }
            greetSOCKS(through: hop, targetHost: host, targetPort: port) { [self] in
                switch request {
                case .connect:
                    established(reply: true)
                case .forward(_, _, let head):
                    var bytes = Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8)
                    bytes.append(clientBuffer)
                    clientBuffer = Data()
                    sendUpstream(bytes)
                    established(reply: false)
                }
            }
        } else {
            sendHTTP(request, through: hop)
        }
    }

    /// Opens an HTTP CONNECT tunnel through an intermediate hop to the next proxy hop.
    private func tunnelHTTP(through hop: ProxyEndpoint, targetHost: String, targetPort: Int,
                            then complete: @escaping () -> Void) {
        let authority = targetHost.contains(":") ? "[\(targetHost)]:\(targetPort)" : "\(targetHost):\(targetPort)"
        var head = ["CONNECT \(authority) HTTP/1.1", "Host: \(authority)"]
        if let auth = authorization(for: hop) { head.append(auth) }
        let bytes = Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        upstream?.send(content: bytes, completion: .contentProcessed { [self] error in
            guard active else { return }
            guard error == nil else { return fail(.unreachable(error!.localizedDescription)) }
            readIntermediateHTTPHead(for: hop, then: complete)
        })
    }

    private func readIntermediateHTTPHead(for hop: ProxyEndpoint, then complete: @escaping () -> Void) {
        if let end = upstreamBuffer.range(of: Self.headEnd) {
            let head = String(decoding: upstreamBuffer[..<end.lowerBound], as: UTF8.self)
            let status = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ")
            guard let status, status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
                return fail(.invalidResponse)
            }
            if code == 407 {
                return fail(hop.hasCredentials ? .credentialsRejected : .credentialsRequired)
            }
            guard (200..<300).contains(code) else {
                return fail(.refused("HTTP \(code)"))
            }
            upstreamBuffer = Data(upstreamBuffer[end.upperBound...])
            complete()
            return
        }
        guard upstreamBuffer.count <= ProxyRelay.maximumHead, !upstreamEnded else { return fail(.invalidResponse) }
        receiveUpstream { [self] in readIntermediateHTTPHead(for: hop, then: complete) }
    }

    private func sendHTTP(_ request: Request, through hop: ProxyEndpoint) {
        var head: [String]
        switch request {
        case let .connect(host, port, headers):
            let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            head = ["CONNECT \(authority) HTTP/1.1"] + headers
            if !headers.contains(where: { $0.lowercased().hasPrefix("host:") }) { head.append("Host: \(authority)") }
        case let .forward(_, _, forwarded):
            head = forwarded
        }
        if let auth = authorization(for: hop) { head.append(auth) }
        var bytes = Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if case .forward = request {
            // The body, if any, follows the headers.
            bytes.append(clientBuffer)
            clientBuffer = Data()
        }
        upstream?.send(content: bytes, completion: .contentProcessed { [self] error in
            guard active else { return }
            guard error == nil else { return fail(.unreachable(error!.localizedDescription)) }
            if case .forward = request {
                // The response may take as long as the website likes.
                timer?.cancel()
                pump(from: client, to: upstream!, ended: clientEnded)
            }
            readUpstreamHead(for: request, hop: hop)
        })
    }

    private func readUpstreamHead(for request: Request, hop: ProxyEndpoint) {
        if let end = upstreamBuffer.range(of: Self.headEnd) {
            let head = String(decoding: upstreamBuffer[..<end.lowerBound], as: UTF8.self)
            let status = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ")
            guard let status, status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
                return fail(.invalidResponse)
            }
            if code == 407 {
                return fail(hop.hasCredentials ? .credentialsRejected : .credentialsRequired)
            }
            switch request {
            case .connect where (200..<300).contains(code):
                upstreamBuffer = Data(upstreamBuffer[end.upperBound...])
                established(reply: true)
            case .connect:
                fail(.refused("HTTP \(code)"))
            case .forward:
                // The upstream's own answer, error pages included, goes to the browser unchanged.
                established(reply: false, alreadyPumpingClient: true)
            }
            return
        }
        guard upstreamBuffer.count <= ProxyRelay.maximumHead, !upstreamEnded else { return fail(.invalidResponse) }
        receiveUpstream { [self] in readUpstreamHead(for: request, hop: hop) }
    }

    /// RFC 1928, offering user name and password sign-in (RFC 1929) when `hop` has them.
    private func greetSOCKS(through hop: ProxyEndpoint, targetHost: String, targetPort: Int,
                            then complete: @escaping () -> Void) {
        let methods: [UInt8] = hop.hasCredentials ? [0x00, 0x02] : [0x00]
        sendUpstream(Data([0x05, UInt8(methods.count)] + methods))
        need(2) { [self] reply in
            guard reply[0] == 0x05 else { return fail(.invalidResponse) }
            switch reply[1] {
            case 0x00:
                requestSOCKS(host: targetHost, port: targetPort, then: complete)
            case 0x02 where hop.hasCredentials:
                let username = Array((hop.username ?? "").utf8)
                let password = Array((hop.password ?? "").utf8)
                sendUpstream(Data([0x01, UInt8(username.count)] + username + [UInt8(password.count)] + password))
                need(2) { [self] status in
                    guard status[0] == 0x01 else { return fail(.invalidResponse) }
                    guard status[1] == 0x00 else { return fail(.credentialsRejected) }
                    requestSOCKS(host: targetHost, port: targetPort, then: complete)
                }
            case 0xff where !hop.hasCredentials:
                fail(.credentialsRequired)
            default:
                fail(.refused("SOCKS5 代理要求不支持的登录方式"))
            }
        }
    }

    private func requestSOCKS(host: String, port: Int, then complete: @escaping () -> Void) {
        // Names go to the proxy as names, so the proxy resolves them rather than this Mac.
        var address: [UInt8]
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            address = [0x01] + withUnsafeBytes(of: &ipv4) { Array($0) }
        } else if inet_pton(AF_INET6, host, &ipv6) == 1 {
            address = [0x04] + withUnsafeBytes(of: &ipv6) { Array($0) }
        } else {
            address = [0x03, UInt8(host.utf8.count)] + Array(host.utf8)
        }
        sendUpstream(Data([0x05, 0x01, 0x00] + address + [UInt8(port >> 8), UInt8(port & 0xff)]))
        need(5) { [self] reply in
            guard reply[0] == 0x05 else { return fail(.invalidResponse) }
            guard reply[1] == 0x00 else { return fail(Self.socksFailure(reply[1])) }
            // The bound address the reply carries is of no use here, but has to be read past.
            let length: Int
            switch reply[3] {
            case 0x01: length = 4 + 2 - 1
            case 0x04: length = 16 + 2 - 1
            case 0x03: length = Int(reply[4]) + 2
            default: return fail(.invalidResponse)
            }
            need(length) { _ in complete() }
        }
    }

    private static func socksFailure(_ code: UInt8) -> ProxyRelay.Failure {
        switch code {
        case 0x02: return .refused("代理规则不允许这个连接")
        case 0x03: return .refused("网络不可达")
        case 0x04: return .refused("目标主机不可达")
        case 0x05: return .refused("目标拒绝连接")
        case 0x06: return .timedOut
        case 0x07: return .refused("SOCKS5 代理不支持 CONNECT")
        case 0x08: return .refused("SOCKS5 代理不支持这种地址")
        default: return .refused("SOCKS5 代理内部错误")
        }
    }

    // MARK: The tunnel

    /// The upstream carries the connection from here on. `reply` sends the browser its 200 for a
    /// CONNECT; whatever the upstream already sent past its handshake follows.
    private func established(reply: Bool, alreadyPumpingClient: Bool = false) {
        timer?.cancel()
        tunnelled = true
        guard let upstream else { return }
        var greeting = reply ? Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8) : Data()
        greeting.append(upstreamBuffer)
        upstreamBuffer = Data()
        let early = clientBuffer
        clientBuffer = Data()
        let resume = { [self] in
            pump(from: upstream, to: client, ended: upstreamEnded)
            guard !alreadyPumpingClient else { return }
            if early.isEmpty {
                pump(from: client, to: upstream, ended: clientEnded)
            } else {
                upstream.send(content: early, completion: .contentProcessed { [self] error in
                    guard error == nil else { return close() }
                    pump(from: client, to: upstream, ended: clientEnded)
                })
            }
        }
        guard !greeting.isEmpty else { return resume() }
        client.send(content: greeting, completion: .contentProcessed { [self] error in
            guard active else { return }
            guard error == nil else { return close() }
            resume()
        })
    }

    /// Copies one direction until it ends, then half-closes the other side so the end reaches it too.
    private func pump(from source: NWConnection, to destination: NWConnection, ended: Bool) {
        guard !ended else { return finish(destination) }
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            guard active else { return }
            guard let data, !data.isEmpty else {
                if isComplete { return finish(destination) }
                return error == nil ? pump(from: source, to: destination, ended: false) : close()
            }
            destination.send(content: data, completion: .contentProcessed { [self] sendError in
                guard active else { return }
                guard sendError == nil else { return close() }
                if isComplete { return finish(destination) }
                error == nil ? pump(from: source, to: destination, ended: false) : close()
            })
        }
    }

    private func finish(_ destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            openDirections -= 1
            if openDirections == 0 { close() }
        })
    }

    // MARK: Helpers

    private func sendUpstream(_ data: Data) {
        upstream?.send(content: data, completion: .contentProcessed { [self] error in
            if error != nil, !closed { fail(.unreachable(error!.localizedDescription)) }
        })
    }

    /// Calls `body` with the next `count` bytes from the upstream once they have arrived.
    private func need(_ count: Int, then body: @escaping ([UInt8]) -> Void) {
        guard upstreamBuffer.count >= count else {
            guard !upstreamEnded else { return fail(.invalidResponse) }
            return receiveUpstream { [self] in need(count, then: body) }
        }
        let bytes = Array(upstreamBuffer.prefix(count))
        upstreamBuffer = Data(upstreamBuffer.dropFirst(count))
        body(bytes)
    }

    private func receiveUpstream(_ then: @escaping () -> Void) {
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            guard active else { return }
            if let data { upstreamBuffer.append(data) }
            if isComplete || error != nil { upstreamEnded = true }
            if let error, data?.isEmpty != false { return fail(.unreachable(error.localizedDescription)) }
            then()
        }
    }

    private func fail(_ failure: ProxyRelay.Failure) {
        guard active else { return }
        timer?.cancel()
        // Once the browser has bytes from the upstream, an error status would corrupt them.
        guard !tunnelled else { return close() }
        relay.report(failure, target: target)
        respond(failure.status, failure.message)
    }

    private func respond(_ status: Int, _ message: String) {
        let reasons = [400: "Bad Request", 407: "Proxy Authentication Required", 431: "Request Header Fields Too Large",
                       502: "Bad Gateway", 504: "Gateway Timeout"]
        let body = Data((message + "\n").utf8)
        var response = Data("""
            HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """.utf8)
        response.append(body)
        answered = true
        timer?.cancel()
        upstream?.cancel()
        client.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            close()
        })
    }
}
