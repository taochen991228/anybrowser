@testable import AnyBrowserCore
import Darwin
import Foundation
import Network
import Testing

@Suite("Proxy relay")
struct RelayTests {
    /// Origins the upstream stubs route to by host name: echo.test and page.test.
    private struct Origins {
        let echo: EchoStub
        let page: OriginStub

        init() throws {
            echo = try EchoStub()
            page = try OriginStub()
        }

        var route: @Sendable (String) -> Int? {
            let (echo, page) = (echo.port, page.port)
            return { host in
                switch host.split(separator: ":").first.map(String.init) ?? host {
                case "echo.test", "127.0.0.1": return echo
                case "page.test": return page
                default: return nil
                }
            }
        }

        func stop() {
            echo.stop()
            page.stop()
        }
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(ProxyRelay.Failure, String)] = []

        var all: [(ProxyRelay.Failure, String)] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func record(_ failure: ProxyRelay.Failure, _ target: String) {
            lock.lock()
            defer { lock.unlock() }
            seen.append((failure, target))
        }
    }

    private func relay(_ upstream: String, timeout: TimeInterval = 5) async throws -> (ProxyRelay, Int) {
        let relay = try ProxyRelay(upstream: try #require(try ProxyEndpoint.parse(upstream, allowingSOCKSCredentials: true)),
                                   connectTimeout: timeout)
        return (relay, try await relay.start())
    }

    @Test("Tunnels and plain requests reach the origin through an HTTP proxy that requires sign-in")
    func signsInToAnHTTPUpstream() async throws {
        let origins = try Origins()
        defer { origins.stop() }
        let upstream = try UpstreamHTTPStub(credentials: "alice:s3cr@t", route: origins.route)
        defer { upstream.stop() }
        let (relay, port) = try await relay("http://alice:s3cr%40t@127.0.0.1:\(upstream.port)")
        defer { relay.stop() }
        #expect(relay.server == "http://127.0.0.1:\(port)")

        // The end of the request reaches the echo origin only if the half-close passes both hops.
        let tunnel = try #require(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("hello".utf8)))
        #expect(tunnel.head == "HTTP/1.1 200 Connection established")
        #expect(tunnel.text == "echo:hello")
        let connect = try #require(upstream.requests.first)
        #expect(connect.method == "CONNECT" && connect.target == "echo.test:7")
        #expect(connect.authorization == upstream.signIn)
        // The browser's own headers still reach the upstream, as they would without the relay.
        #expect(connect.head.contains("User-Agent: relay-test"))

        // Whatever sign-in the browser sends is replaced, and the request goes out on its own connection.
        let reply = try #require(await RelayClient.exchange(port, """
            GET http://page.test/hello?x=1 HTTP/1.1\r
            Host: page.test\r
            Proxy-Authorization: Basic Zm9vOmJhcg==\r
            Proxy-Connection: keep-alive\r
            Connection: keep-alive\r
            \r

            """))
        #expect(reply.status == 200)
        #expect(reply.text.contains("<title>origin page.test</title><p id=path>/hello?x=1</p>"))
        let forwarded = try #require(upstream.requests.last)
        #expect(forwarded.method == "GET" && forwarded.target == "http://page.test/hello?x=1")
        #expect(forwarded.authorization == upstream.signIn)
        #expect(!forwarded.head.contains("Zm9vOmJhcg=="))
        #expect(forwarded.head.contains("Connection: close") && !forwarded.head.contains("keep-alive"))
        #expect(relay.lastFailure == nil)
    }

    @Test("Rejected or missing credentials end in a 407 without a challenge")
    func reportsSignInFailures() async throws {
        let origins = try Origins()
        defer { origins.stop() }
        let upstream = try UpstreamHTTPStub(credentials: "alice:secret", route: origins.route)
        defer { upstream.stop() }
        let failures = Failures()

        let (wrong, wrongPort) = try await relay("http://alice:wrong@127.0.0.1:\(upstream.port)")
        defer { wrong.stop() }
        wrong.failureHandler = { failures.record($0, $1) }
        let refused = try #require(await RelayClient.tunnel(wrongPort, to: "echo.test:7", payload: Data()))
        // A challenge would make the browser ask for a password that could only reach the relay.
        #expect(refused.status == 407 && !refused.head.lowercased().contains("proxy-authenticate"))
        #expect(refused.text == "上游代理拒绝了用户名或密码。\n")
        let page = try #require(await RelayClient.exchange(wrongPort, "GET http://page.test/ HTTP/1.1\r\nHost: page.test\r\n\r\n"))
        #expect(page.status == 407 && !page.head.lowercased().contains("proxy-authenticate"))
        #expect(wrong.lastFailure == .credentialsRejected)
        #expect(failures.all.map(\.1) == ["echo.test:7", "http://page.test/"])

        let (none, nonePort) = try await relay("http://127.0.0.1:\(upstream.port)")
        defer { none.stop() }
        let missing = try #require(await RelayClient.tunnel(nonePort, to: "echo.test:7", payload: Data()))
        #expect(missing.status == 407)
        #expect(none.lastFailure == .credentialsRequired)
        #expect(upstream.requests.allSatisfy { $0.authorization == nil || $0.authorization != upstream.signIn })
    }

    @Test("SOCKS5 upstreams get RFC 1929 sign-in and host names to resolve")
    func signsInToASOCKSUpstream() async throws {
        let origins = try Origins()
        defer { origins.stop() }
        let upstream = try UpstreamSOCKSStub(username: "bob", password: "p@ss:w", route: origins.route)
        defer { upstream.stop() }
        let (relay, port) = try await relay("socks5h://bob:p%40ss%3Aw@127.0.0.1:\(upstream.port)")
        defer { relay.stop() }

        let tunnel = try #require(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("hi".utf8)))
        #expect(tunnel.status == 200)
        #expect(tunnel.text == "echo:hi")
        let first = try #require(upstream.requests.first)
        #expect(first.methods.contains(2) && first.username == "bob" && first.password == "p@ss:w")
        // The name goes to the proxy (ATYP 3), so DNS happens there.
        #expect(first.addressType == 3 && first.host == "echo.test" && first.port == 7)

        let page = try #require(await RelayClient.exchange(port, "GET http://page.test:8080/a?b HTTP/1.1\r\nHost: page.test:8080\r\n\r\n"))
        #expect(page.status == 200)
        #expect(page.text.contains("<p id=path>/a?b</p>"))
        #expect(upstream.requests.last?.host == "page.test" && upstream.requests.last?.port == 8080)

        let literal = try #require(await RelayClient.tunnel(port, to: "127.0.0.1:9", payload: Data("x".utf8)))
        #expect(literal.text == "echo:x")
        #expect(upstream.requests.last?.addressType == 1 && upstream.requests.last?.host == "127.0.0.1")

        let unknown = try #require(await RelayClient.tunnel(port, to: "nowhere.test:443", payload: Data()))
        #expect(unknown.status == 502)
        #expect(relay.lastFailure == .refused("目标拒绝连接"))

        let (wrong, wrongPort) = try await self.relay("socks5://bob:nope@127.0.0.1:\(upstream.port)")
        defer { wrong.stop() }
        #expect(await RelayClient.tunnel(wrongPort, to: "echo.test:7", payload: Data())?.status == 407)
        #expect(wrong.lastFailure == .credentialsRejected)

        let (anonymous, anonymousPort) = try await self.relay("socks5://127.0.0.1:\(upstream.port)")
        defer { anonymous.stop() }
        #expect(await RelayClient.tunnel(anonymousPort, to: "echo.test:7", payload: Data())?.status == 407)
        #expect(anonymous.lastFailure == .credentialsRequired)
        #expect(upstream.requests.last?.methods == [0])
    }

    @Test("A missing or silent upstream fails with 502 or 504 instead of hanging")
    func reportsUnavailableUpstreams() async throws {
        let closed = try SilentStub()
        let closedPort = closed.port
        closed.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        let (gone, gonePort) = try await relay("http://127.0.0.1:\(closedPort)")
        defer { gone.stop() }
        let refused = await RelayClient.tunnel(gonePort, to: "echo.test:7", payload: Data())
        #expect(refused?.status == 502, "\(String(describing: refused))")
        guard case .unreachable? = gone.lastFailure else {
            Issue.record("Expected an unreachable upstream, got \(String(describing: gone.lastFailure))")
            return
        }

        let silent = try SilentStub()
        defer { silent.stop() }
        for upstream in ["http", "socks5"] {
            let (slow, slowPort) = try await relay("\(upstream)://127.0.0.1:\(silent.port)", timeout: 1)
            defer { slow.stop() }
            let started = Date()
            #expect(await RelayClient.tunnel(slowPort, to: "echo.test:7", payload: Data())?.status == 504)
            #expect(Date().timeIntervalSince(started) < 3)
            #expect(slow.lastFailure == .timedOut)
        }

        let (relay, port) = try await relay("http://127.0.0.1:\(closedPort)")
        defer { relay.stop() }
        for request in ["nonsense\r\n\r\n", "GET https://page.test/ HTTP/1.1\r\n\r\n", "CONNECT page.test HTTP/1.1\r\n\r\n"] {
            #expect(await RelayClient.exchange(port, request)?.status == 400, "\(request)")
        }
        #expect(throws: ProfileError.self) {
            try ProxyRelay(upstream: ProxyEndpoint(scheme: "ftp", host: "127.0.0.1", port: 21))
        }
    }

    @Test("Many tunnels run at once, each with its own data, and close when they end")
    func carriesConcurrentTunnels() async throws {
        let origins = try Origins()
        defer { origins.stop() }
        let upstream = try UpstreamHTTPStub(credentials: "u:p", route: origins.route)
        defer { upstream.stop() }
        let (relay, port) = try await relay("http://u:p@127.0.0.1:\(upstream.port)")
        defer { relay.stop() }

        let replies = await withTaskGroup(of: (Int, String?).self) { group in
            for index in 0..<16 {
                group.addTask {
                    // Large enough for back-pressure on the larger ones.
                    let payload = String(repeating: "\(index)-", count: index * 20_000 + 1)
                    let reply = await RelayClient.tunnel(port, to: "echo.test:7", payload: Data(payload.utf8))
                    return (index, reply.map { $0.text == "echo:" + payload ? "ok" : "mismatch \($0.body.count) of \(payload.utf8.count + 5), prefix \(("echo:" + payload).hasPrefix($0.text)), head \($0.head)" })
                }
            }
            var results: [Int: String?] = [:]
            for await (index, result) in group { results[index] = result }
            return results
        }
        #expect(replies.count == 16)
        #expect(replies.values.allSatisfy { $0 == "ok" }, "\(replies)")
        for _ in 0..<50 where relay.openSessions > 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(relay.openSessions == 0)
    }

    @Test("Stopping closes the port and the tunnels still open")
    func stops() async throws {
        let silent = try SilentStub()
        defer { silent.stop() }
        let (relay, port) = try await relay("http://127.0.0.1:\(silent.port)")
        let waiting = Task { await RelayClient.tunnel(port, to: "echo.test:7", payload: Data()) }
        for _ in 0..<50 where relay.openSessions == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(relay.openSessions == 1)
        relay.stop()
        #expect(await waiting.value == nil)
        #expect(relay.openSessions == 0)
        // The listener closes on its own queue shortly after.
        var refused = false
        for _ in 0..<50 where !refused {
            let fd = await onThread { Sockets.connect(to: port, timeout: 1) }
            refused = fd < 0
            if !refused {
                close(fd)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        #expect(refused)
    }

    @Test("A start that fails leaves the relay free to start again")
    func startsAgainAfterFailing() async throws {
        let (holder, taken) = try await relay("http://127.0.0.1:9")
        defer { holder.stop() }
        let relay = try ProxyRelay(upstream: try #require(try ProxyEndpoint.parse("http://127.0.0.1:9")))
        await #expect(throws: ProfileError.self) { try await relay.start(port: taken) }
        #expect(relay.port == nil)
        let port = try await relay.start()
        defer { relay.stop() }
        #expect(port != taken && relay.port == port)
    }

    @Test("HTTPS upstreams get TLS with certificate checks")
    func speaksTLSToTheUpstream() async throws {
        guard #available(macOS 15, *) else { return }
        let origins = try Origins()
        defer { origins.stop() }
        let upstream = try UpstreamHTTPStub(credentials: "tls:user", route: origins.route)
        defer { upstream.stop() }
        let front = try await TLSFront.start(forwardingTo: upstream.port)
        defer { front.stop() }

        // The self-signed certificate is not trusted by the system.
        let (strict, strictPort) = try await relay("https://tls:user@127.0.0.1:\(front.port)")
        defer { strict.stop() }
        #expect(await RelayClient.tunnel(strictPort, to: "echo.test:7", payload: Data())?.status == 502)
        guard case .unreachable? = strict.lastFailure else {
            Issue.record("Expected a TLS failure, got \(String(describing: strict.lastFailure))")
            return
        }
        #expect(upstream.requests.isEmpty)

        let relay = try ProxyRelay(upstream: try #require(try ProxyEndpoint.parse("https://tls:user@127.0.0.1:\(front.port)")))
        let expected = SecCertificateCopyData(front.certificate) as Data
        relay.verifyUpstream = { trust in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            return chain?.first.map { SecCertificateCopyData($0) as Data } == expected
        }
        let port = try await relay.start()
        defer { relay.stop() }
        // The test front cannot send after it received a TLS close, so this request does not half-close.
        let tunnel = try #require(await RelayClient.tunnel(port, to: "page.test:80", payload: Data("GET /tls HTTP/1.1\r\nHost: page.test\r\n\r\n".utf8), halfClose: false))
        #expect(tunnel.text.contains("<title>origin page.test</title><p id=path>/tls</p>"), "\(tunnel.head) \(tunnel.text)")
        #expect(upstream.requests.last?.authorization == upstream.signIn)
    }

    @Test("Multi-hop proxy chains tunnel through transit then exit with independent credentials")
    func chainsHTTPAndSOCKSUpstreams() async throws {
        let origins = try Origins()
        defer { origins.stop() }
        // Hop 2 (exit): SOCKS5 with its own credentials, routing to the real origins.
        let exitSOCKS = try UpstreamSOCKSStub(username: "exit-u", password: "exit-p", route: origins.route)
        defer { exitSOCKS.stop() }
        // Hop 1 (transit): HTTP proxy with its own credentials, routing only to Hop 2.
        let exitPort = exitSOCKS.port
        let transitHTTP = try UpstreamHTTPStub(credentials: "hop1:secret1", route: { host in
            host == "exit-hop.test:\(exitPort)" || host == "127.0.0.1:\(exitPort)" ? exitPort : nil
        })
        defer { transitHTTP.stop() }

        let hop1 = try #require(try ProxyEndpoint.parse("http://hop1:secret1@127.0.0.1:\(transitHTTP.port)"))
        let hop2 = try #require(try ProxyEndpoint.parse("socks5://exit-u:exit-p@exit-hop.test:\(exitPort)"))
        let relay = try ProxyRelay(chain: [hop1, hop2], connectTimeout: 5)
        let port = try await relay.start()
        defer { relay.stop() }

        let tunnel = try #require(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("chained".utf8)))
        #expect(tunnel.status == 200)
        #expect(tunnel.text == "echo:chained")
        #expect(transitHTTP.requests.first?.method == "CONNECT")
        #expect(transitHTTP.requests.first?.target == "exit-hop.test:\(exitPort)")
        #expect(transitHTTP.requests.first?.authorization == transitHTTP.signIn)
        #expect(exitSOCKS.requests.first?.username == "exit-u" && exitSOCKS.requests.first?.password == "exit-p")
        #expect(exitSOCKS.requests.first?.host == "echo.test" && exitSOCKS.requests.first?.port == 7)

        // Plain HTTP forward over the 2-hop chain works too.
        let page = try #require(await RelayClient.exchange(port, "GET http://page.test/chain HTTP/1.1\r\nHost: page.test\r\n\r\n"))
        #expect(page.status == 200)
        #expect(page.text.contains("<p id=path>/chain</p>"))
    }

    @Test("SOCKS5 transit chaining into an HTTP exit proxy fails closed when exit is down or rejects auth")
    func chainsSOCKSToHTTPAndFailsClosed() async throws {
        let origins = try Origins()
        defer { origins.stop() }
        let exitHTTP = try UpstreamHTTPStub(credentials: "u2:p2", route: origins.route)
        defer { exitHTTP.stop() }
        let exitPort = exitHTTP.port
        let transitSOCKS = try UpstreamSOCKSStub(username: "u1", password: "p1", route: { host in
            host == "exit-http.test" ? exitPort : nil
        })
        defer { transitSOCKS.stop() }

        let hop1 = try #require(try ProxyEndpoint.parse("socks5://u1:p1@127.0.0.1:\(transitSOCKS.port)"))
        let hop2 = try #require(try ProxyEndpoint.parse("http://u2:p2@exit-http.test:\(exitPort)"))
        let relay = try ProxyRelay(chain: [hop1, hop2], connectTimeout: 5)
        let port = try await relay.start()
        defer { relay.stop() }

        let ok = try #require(await RelayClient.tunnel(port, to: "echo.test:7", payload: Data("ok".utf8)))
        #expect(ok.status == 200 && ok.text == "echo:ok")
        #expect(transitSOCKS.requests.first?.host == "exit-http.test" && transitSOCKS.requests.first?.port == exitPort)
        #expect(exitHTTP.requests.first?.target == "echo.test:7")

        // Wrong exit credentials fail closed with 407 instead of bypassing Hop 2.
        let badHop2 = try #require(try ProxyEndpoint.parse("http://u2:wrong@exit-http.test:\(exitPort)"))
        let badRelay = try ProxyRelay(chain: [hop1, badHop2], connectTimeout: 5)
        let badPort = try await badRelay.start()
        defer { badRelay.stop() }
        #expect(await RelayClient.tunnel(badPort, to: "echo.test:7", payload: Data())?.status == 407)
        #expect(badRelay.lastFailure == .credentialsRejected)

        // Unreachable exit through working transit fails closed with 502 instead of falling back to transit/direct.
        let deadHop2 = try #require(try ProxyEndpoint.parse("http://dead-exit.test:8080"))
        let deadRelay = try ProxyRelay(chain: [hop1, deadHop2], connectTimeout: 5)
        let deadPort = try await deadRelay.start()
        defer { deadRelay.stop() }
        #expect(await RelayClient.tunnel(deadPort, to: "echo.test:7", payload: Data())?.status == 502)
        guard case .refused? = deadRelay.lastFailure else {
            Issue.record("Expected refused when exit hop is unreachable, got \(String(describing: deadRelay.lastFailure))")
            return
        }
    }
}
