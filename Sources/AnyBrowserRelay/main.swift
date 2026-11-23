import AnyBrowserCore
import Darwin
import Foundation

// Runs one Profile's proxy relay as its own process, so the browser keeps its network when the app
// quits. The upstream address, credentials included, never appears in the arguments: it is read from
// a file only this user can read, or from the first line of standard input.
//
//   AnyBrowserRelay --config <file|-> --port-file <file> [--watch-pid <pid>] [--follow <data directory>]
//
// The configuration is a JSON object:
//   {"upstream": "socks5://user:pass@host:port", "connectTimeout": 15, "relaunchGrace": 10}
// Once listening, the relay writes its port and a newline to the port file, atomically. It exits when
// the watched process does, or on SIGTERM or SIGINT, removing the port file. Each line `watch <pid>`
// on standard input replaces the watched process: the app watches itself while it starts the browser,
// then hands over the browser's pid. Standard input closing changes nothing.
//
// With --follow, the relay outlives the watched process by up to `relaunchGrace` seconds, for the
// browser that holds that data directory next with this relay as its proxy: Chromium relaunches
// itself as a new process (chrome://restart), and a browser started just before the app quit was
// never handed over.

/// sysexits.h
enum Exit: Int32 {
    case usage = 64, noInput = 66, unavailable = 69, cannotCreate = 73, config = 78
}

/// One line on standard error. Once the app has quit nobody may read it, and a failed write must not end the
/// relay: FileHandle would raise an exception for it.
func log(_ line: String) {
    let bytes = Array("AnyBrowserRelay: \(line)\n".utf8)
    _ = write(STDERR_FILENO, bytes, bytes.count)
}

func fail(_ code: Exit, _ message: String) -> Never {
    log(message)
    exit(code.rawValue)
}

struct Configuration: Decodable {
    var upstream: String?
    var chain: [String]?
    var connectTimeout: TimeInterval?
    var relaunchGrace: TimeInterval?
}

let usage = "用法：AnyBrowserRelay --config <文件|-> --port-file <文件> [--watch-pid <pid>] [--follow <资料目录>]"
var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let name = arguments.popFirst() {
    guard ["--config", "--port-file", "--watch-pid", "--follow"].contains(name), options[name] == nil,
          let value = arguments.popFirst() else { fail(.usage, usage) }
    options[name] = value
}
guard let configPath = options["--config"], let portPath = options["--port-file"] else { fail(.usage, usage) }
var initialPID: pid_t?
if let text = options["--watch-pid"] {
    guard let pid = pid_t(text), pid > 0 else { fail(.usage, usage) }
    initialPID = pid
}

/// Up to the first newline of standard input, read without buffering so later lines stay unread.
func readStandardInputLine(limit: Int) -> Data {
    var line = Data()
    var byte: UInt8 = 0
    while line.count <= limit, read(STDIN_FILENO, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
        line.append(byte)
    }
    return line
}

/// The file's contents when it is a regular file of this user that nobody else can read or write.
func readPrivateFile(_ path: String, limit: Int) -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { fail(.noInput, "无法读取配置文件 \(path)。") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var details = stat()
    guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_uid == getuid(),
          details.st_mode & 0o077 == 0 else {
        fail(.config, "配置文件必须是当前用户的普通文件，且只有当前用户可读写（0600）。")
    }
    do {
        return try file.read(upToCount: limit + 1) ?? Data()
    } catch {
        fail(.noInput, "无法读取配置文件 \(path)。")
    }
}

let limit = 65_536
let configData = configPath == "-" ? readStandardInputLine(limit: limit) : readPrivateFile(configPath, limit: limit)
guard configData.count <= limit, let configuration = try? JSONDecoder().decode(Configuration.self, from: configData) else {
    fail(.config, "配置无法识别，应为 {\"upstream\": \"代理地址\"}。")
}
let hops: [ProxyEndpoint]
do {
    if let rawChain = configuration.chain, !rawChain.isEmpty {
        var parsed: [ProxyEndpoint] = []
        for (index, item) in rawChain.enumerated() {
            guard let endpoint = try ProxyEndpoint.parse(item, allowingSOCKSCredentials: true) else {
                fail(.config, "代理链包含空地址。")
            }
            if index > 0, endpoint.scheme == "https" {
                fail(.config, "链式代理的后续节点暂不支持 HTTPS 代理。")
            }
            parsed.append(endpoint)
        }
        hops = parsed
    } else if let rawUpstream = configuration.upstream,
              let endpoint = try ProxyEndpoint.parse(rawUpstream, allowingSOCKSCredentials: true) {
        hops = [endpoint]
    } else {
        fail(.config, "配置里没有上游代理地址。")
    }
} catch {
    fail(.config, error.localizedDescription)
}
let timeout = configuration.connectTimeout ?? 15
guard timeout.isFinite, (1...300).contains(timeout) else { fail(.config, "connectTimeout 须为 1–300 秒。") }
let relaunchGrace = configuration.relaunchGrace ?? RelayHelper.defaultRelaunchGrace
guard relaunchGrace.isFinite, (0...300).contains(relaunchGrace) else { fail(.config, "relaunchGrace 须为 0–300 秒。") }
let followed = options["--follow"].map { URL(fileURLWithPath: $0, isDirectory: true) }
let relay: ProxyRelay
do {
    relay = try ProxyRelay(chain: hops, connectTimeout: timeout)
} catch {
    fail(.config, error.localizedDescription)
}

// A browser that loses a connection logs nothing useful; the relay says why, once per repeat.
final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func record(_ failure: ProxyRelay.Failure, target: String) {
        let line = "\(target.isEmpty ? "" : "\(target) ")\(failure.message)"
        lock.lock()
        defer { lock.unlock() }
        guard line != last else { return }
        last = line
        log(line)
    }
}
let failures = FailureLog()
relay.failureHandler = { failures.record($0, target: $1) }

// Writes to a log pipe the app no longer reads must not end the process.
signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

let portFile = URL(fileURLWithPath: portPath)
var listening: Int?

@Sendable func shutDown(_ status: Int32 = 0) -> Never {
    relay.stop()
    // Only our own record goes; a newer relay may have taken the file over.
    if let listening, let text = try? String(contentsOf: portFile, encoding: .utf8), text == "\(listening)\n" {
        unlink(portFile.path)
    }
    exit(status)
}

var stopSignals: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { shutDown() }
    source.resume()
    stopSignals.append(source)
}

var watched: (pid: pid_t, source: DispatchSourceProcess)?

/// Exits once `pid` does, or follows the browser that holds the data directory next; replaces
/// any process watched before.
func watch(_ pid: pid_t) {
    watched?.source.cancel()
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source.setEventHandler { ended(pid) }
    source.resume()
    watched = (pid, source)
    // A process that is already gone never reports its exit.
    if kill(pid, 0) != 0, errno == ESRCH { ended(pid) }
}

@Sendable func ended(_ pid: pid_t) {
    guard watched?.pid == pid else { return }
    watched?.source.cancel()
    watched = nil
    guard let followed, let listening else { shutDown() }
    let deadline = ProcessInfo.processInfo.systemUptime + relaunchGrace
    func look() {
        // A `watch` command may have arrived meanwhile.
        guard watched == nil else { return }
        if let next = RelayHelper.browser(holding: followed, through: listening), next != pid { return watch(next) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { shutDown() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { look() }
    }
    look()
}

func writePortFile(_ port: Int) {
    let staging = portFile.deletingLastPathComponent()
        .appendingPathComponent(".\(portFile.lastPathComponent)-\(UUID().uuidString)")
    let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { fail(.cannotCreate, "无法写入端口文件 \(portFile.path)。") }
    let bytes = Array("\(port)\n".utf8)
    let written = write(fd, bytes, bytes.count)
    close(fd)
    guard written == bytes.count, rename(staging.path, portFile.path) == 0 else {
        unlink(staging.path)
        fail(.cannotCreate, "无法写入端口文件 \(portFile.path)。")
    }
}

Task {
    let port: Int
    do {
        port = try await relay.start()
    } catch {
        fail(.unavailable, error.localizedDescription)
    }
    DispatchQueue.main.async {
        writePortFile(port)
        listening = port
        if let initialPID { watch(initialPID) }
        Thread.detachNewThread {
            while let line = readLine() {
                let words = line.split(separator: " ")
                guard words.count == 2, words[0] == "watch", let pid = pid_t(words[1]), pid > 0 else {
                    log("无法识别的命令：\(line.prefix(80))")
                    continue
                }
                DispatchQueue.main.async { watch(pid) }
            }
        }
    }
}

dispatchMain()
