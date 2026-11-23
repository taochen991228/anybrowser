import CryptoKit
import Darwin
import Foundation

/// The AnyBrowserRelay helper a Profile's browser goes through, as its receipt records it.
struct RelayReceipt: Codable, Equatable {
    let pid: Int32
    let stamp: ProcessStamp
    let port: Int
    /// The SHA-256 of the upstream's normalized address, credentials included, so a changed proxy
    /// shows as a pending restart without the receipt holding the password; empty when unknown.
    let upstream: String

    static func digest(_ endpoint: ProxyEndpoint) -> String {
        digest(ProxyChain(hops: [endpoint]))
    }

    static func digest(_ chain: ProxyChain) -> String {
        SHA256.hash(data: Data(chain.key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A helper this launch started, until the browser is handed over to it.
final class RelayLaunch {
    let process: Process
    let receipt: RelayReceipt
    private var input: Int32

    init(process: Process, receipt: RelayReceipt, input: Int32) {
        self.process = process
        self.receipt = receipt
        self.input = input
    }

    deinit {
        if input >= 0 { close(input) }
    }

    /// From now on the helper lives as long as the browser `pid`. Closing its input changes nothing
    /// for it; until then it watched AnyBrowser, so that a launch cut short does not leave it behind.
    func hand(over pid: Int32) {
        guard input >= 0 else { return }
        _ = Self.write("watch \(pid)\n", to: input)
        close(input)
        input = -1
    }

    @discardableResult
    static func write(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

extension BrowserRuntime {
    func relayPortFile(_ directory: URL) -> URL {
        directory.appendingPathComponent(RelayHelper.portFileName)
    }

    /// Starts the Profile's relay to `chain` and waits until it listens. Its output joins the
    /// browser's launch log. Fails without leaving a process behind.
    func startRelay(to chain: ProxyChain, directory: URL, output: Pipe, log: LaunchLog) async throws -> RelayLaunch {
        guard let executable = engine.relayExecutable else {
            throw BrowserRuntimeError.message(chain.isChained
                ? "此 AnyBrowser 缺少代理中继组件，无法使用链式代理。请重新安装 AnyBrowser，或清空前置中转代理。"
                : "此 AnyBrowser 缺少代理中继组件，无法使用带账号密码的代理。请重新安装 AnyBrowser，或去掉代理的账号密码。")
        }
        let portFile = relayPortFile(directory)
        unlink(portFile.path)
        let input = Pipe()
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--config", "-", "--port-file", portFile.path, "--watch-pid", String(getpid()),
                            "--follow", directory.path]
        helper.standardInput = input
        helper.standardOutput = FileHandle.nullDevice
        // A copy of the log pipe's write end: Process closes the ends of a Pipe it is given, and the
        // browser still needs this one.
        let errors = fcntl(output.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard errors >= 0 else { throw BrowserRuntimeError.message("代理中继未能启动。") }
        let errorHandle = FileHandle(fileDescriptor: errors, closeOnDealloc: true)
        helper.standardError = errorHandle
        defer { try? errorHandle.close() }
        try helper.run()
        // The child holds its own copy of the read end. Writing to a helper that died must fail,
        // not raise SIGPIPE in AnyBrowser.
        try? input.fileHandleForReading.close()
        let writer = fcntl(input.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        try? input.fileHandleForWriting.close()
        if writer >= 0 { _ = fcntl(writer, F_SETNOSIGPIPE, 1) }
        var configuration: [String: Any] = ["upstream": chain.exit.url, "connectTimeout": 15,
                                            "relaunchGrace": relayRelaunchGrace]
        if chain.isChained {
            configuration["chain"] = chain.hops.map(\.url)
        }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self) + "\n"
        var receipt: RelayReceipt?
        if writer >= 0, RelayLaunch.write(line, to: writer) {
            await waitUntil(seconds: relayStartTimeout) {
                if let port = readPort(portFile), ProcessInspection.hasLoopbackDebugListener(pid: helper.processIdentifier, port: port),
                   let stamp = ProcessStamp.read(helper.processIdentifier) {
                    receipt = RelayReceipt(pid: helper.processIdentifier, stamp: stamp, port: port,
                                           upstream: RelayReceipt.digest(chain))
                }
                return receipt != nil || !helper.isRunning
            }
        }
        if let receipt, helper.isRunning { return RelayLaunch(process: helper, receipt: receipt, input: writer) }
        if writer >= 0 { close(writer) }
        await end(helper)
        await log.waitForEnd(seconds: 0.2)
        var text = "代理中继未能启动。"
        let tail = log.tail(lines: 3)
        if !tail.isEmpty { text += "\n最近的输出：\n" + tail }
        throw BrowserRuntimeError.message(text)
    }

    private func readPort(_ file: URL) -> Int? {
        guard let data = try? PrivateFile.read(file, limit: 16, failure: ""),
              let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        return Int(text.dropLast()).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    /// Whether `relay` is still the helper of this data directory that the receipt names.
    func ownsRelay(_ relay: RelayReceipt, directory: URL) -> Bool {
        guard let executable = engine.relayExecutable, ProcessStamp.read(relay.pid) == relay.stamp,
              let image = ProcessInspection.image(relay.pid),
              image.executablePath == executable.path || ProcessInspection.executable(relay.pid) == executable
                || ProcessInspection.canonicalURL(URL(fileURLWithPath: image.executablePath)) == ProcessInspection.canonicalURL(executable),
              let index = image.arguments.firstIndex(of: "--port-file"), image.arguments.indices.contains(index + 1),
              image.arguments[index + 1] == relayPortFile(directory).path,
              ProcessInspection.hasLoopbackDebugListener(pid: relay.pid, port: relay.port) else { return false }
        return ProcessStamp.read(relay.pid) == relay.stamp
    }

    /// The relay a browser adopted through its SingletonLock goes through: the one `saved` names,
    /// or else the helper of this data directory listening on the port in the browser's arguments.
    /// Found that way its upstream is unknown, so the browser shows as needing a restart.
    func adoptedRelay(arguments: [String], saved: RelayReceipt?, directory: URL) -> RelayReceipt? {
        let prefix = "--proxy-server=http://127.0.0.1:"
        guard let flag = arguments.dropFirst().first(where: { $0.hasPrefix(prefix) }),
              let port = Int(flag.dropFirst(prefix.count)) else { return nil }
        if let saved, saved.port == port, ownsRelay(saved, directory: directory) { return saved }
        guard let holder = ProcessInspection.listener(onPort: port), let stamp = ProcessStamp.read(holder.pid) else { return nil }
        let found = RelayReceipt(pid: holder.pid, stamp: stamp, port: port, upstream: "")
        return ownsRelay(found, directory: directory) ? found : nil
    }

    /// Ends the Profile's relay once its browser is gone. It would exit by itself, but it waits a
    /// while for a browser that relaunched itself, and a stopped browser does not come back.
    func endRelay(_ relay: RelayReceipt?, directory: URL) async {
        guard let relay, ownsRelay(relay, directory: directory) else { return }
        kill(relay.pid, SIGTERM)
        await waitUntil(seconds: terminationGrace) { ProcessStamp.read(relay.pid) != relay.stamp }
        if ownsRelay(relay, directory: directory) {
            kill(relay.pid, SIGKILL)
        }
    }

    /// Ends a helper this launch started.
    func end(_ helper: Process) async {
        guard helper.isRunning else { return }
        helper.terminate()
        await waitUntil(seconds: terminationGrace) { !helper.isRunning }
        if helper.isRunning {
            kill(helper.processIdentifier, SIGKILL)
            await waitUntil(seconds: 2) { !helper.isRunning }
        }
    }
}
