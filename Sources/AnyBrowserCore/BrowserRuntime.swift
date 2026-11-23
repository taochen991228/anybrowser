import AppKit
import Combine
import Darwin
import Foundation

public struct BrowserEngine: Sendable {
    public let version: String
    let executable: URL
    let passkeyBoxDirectory: URL
    /// The AnyBrowserRelay helper beside the app, which a proxy with credentials needs; app
    /// bundles from before 0.5 have none.
    var relayExecutable: URL?

    public static func bundled(in bundleURL: URL = Bundle.main.bundleURL) throws -> BrowserEngine {
        guard let root = ProcessInspection.canonicalURL(bundleURL, isDirectory: true) else {
            throw BrowserRuntimeError.message("无法定位 AnyBrowser 应用。")
        }
        let engineURL = root.appendingPathComponent("Contents/Frameworks/Chromium.app", isDirectory: true)
        guard ProcessInspection.canonicalURL(engineURL, isDirectory: true)?.path == engineURL.path,
              let bundle = Bundle(url: engineURL),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty, let entry = bundle.executableURL,
              let executable = ProcessInspection.canonicalURL(entry),
              executable.path.hasPrefix(engineURL.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BrowserRuntimeError.message("内置 Chromium 不可用，请重新安装 AnyBrowser。")
        }
        let extensionURL = root.appendingPathComponent("Contents/Resources/Extensions/PasskeyBox", isDirectory: true)
        let manifest = extensionURL.appendingPathComponent("manifest.json")
        guard ProcessInspection.canonicalURL(extensionURL, isDirectory: true)?.path == extensionURL.path,
              ProcessInspection.canonicalURL(manifest)?.path == manifest.path,
              FileManager.default.isReadableFile(atPath: manifest.path) else {
            throw BrowserRuntimeError.message("内置 Passkey Box 不可用，请重新安装 AnyBrowser。")
        }
        // Chromium parses --load-extension as a comma-separated list.
        guard !extensionURL.path.contains(",") else {
            throw BrowserRuntimeError.message("请将 AnyBrowser 移到路径不含逗号的目录。")
        }
        let relayURL = root.appendingPathComponent("Contents/MacOS/\(RelayHelper.executableName)")
        let relay = ProcessInspection.canonicalURL(relayURL).flatMap {
            $0.path == relayURL.path && FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
        }
        return BrowserEngine(version: version, executable: executable, passkeyBoxDirectory: extensionURL,
                             relayExecutable: relay)
    }
}

enum BrowserRuntimeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): return text
        }
    }
}

/// Keeps every request at the address it was sent to, so neither credentials nor a loopback-only
/// request ever follow a redirect elsewhere.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension URLSessionConfiguration {
    /// For a browser's debug port on this Mac: no proxies, cookies or stored credentials.
    public static var loopback: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}

/// One-off choices for a single launch; none of them is saved with the Profile.
public struct LaunchOverrides: Equatable, Sendable {
    /// Runs the browser without windows (`--headless=new`).
    public var headless: Bool
    /// Pages to open instead of the Profile's start pages; nil keeps the start pages.
    public var urls: [String]?
    /// Extra Chromium switches for this launch only, appended after the Profile's own. Only
    /// `--` switches are accepted, and none that decides which process is the Profile's browser
    /// (`--user-data-dir`, `--remote-debugging-*`).
    public var arguments: [String]
    /// Deletes the Profile's site data on disk, as `clearSiteData` does for a stopped Profile,
    /// right before the browser starts (identity reset). A browser that is already running is
    /// left alone and the launch fails.
    public var resetSiteData: Bool

    public init(headless: Bool = false, urls: [String]? = nil, arguments: [String] = [], resetSiteData: Bool = false) {
        self.headless = headless
        self.urls = urls
        self.arguments = arguments
        self.resetSiteData = resetSiteData
    }
}

/// What `BrowserRuntime.start` did.
public struct LaunchOutcome: Equatable, Sendable {
    /// False when the Profile's browser was already running and was adopted as it was.
    public var startedFresh: Bool
    /// Problems that did not stop the launch, shown to the user and returned by the API.
    public var warnings: [String]

    public init(startedFresh: Bool, warnings: [String] = []) {
        self.startedFresh = startedFresh
        self.warnings = warnings
    }
}

@MainActor
public final class BrowserRuntime: ObservableObject {
    @Published public private(set) var states: [UUID: BrowserRunState] = [:]

    struct Receipt: Codable, Equatable {
        let pid: Int32
        let stamp: ProcessStamp
        let port: Int
        let device: Int32
        let inode: UInt64
        /// The relay the browser goes through, when its proxy has credentials.
        var relay: RelayReceipt? = nil
    }

    let engine: BrowserEngine
    let storage: URL
    /// Chromium keeps the HTTP and code caches of a data directory inside `applicationSupport`
    /// under `caches`, at the same relative path; elsewhere they stay in the data directory.
    let applicationSupport: URL?
    let caches: URL?
    private let localSession: URLSession
    private var children: [UUID: Process] = [:]
    /// Exit sources for running browsers that are not children of this process: adopted after
    /// AnyBrowser restarted, or relaunched by the browser itself (chrome://restart).
    private var watchers: [UUID: (pid: Int32, source: DispatchSourceProcess)] = [:]
    private var logs: [UUID: LaunchLog] = [:]

    /// Appended to every launch. Tests use it for switches other parts of AnyBrowser add.
    var additionalArguments: [String] = []
    // Tests shorten these.
    var readinessTimeout: TimeInterval = 20
    var stopTimeout: TimeInterval = 8
    var terminationGrace: TimeInterval = 3
    var startPageBudget: TimeInterval = 5
    var relayStartTimeout: TimeInterval = 5
    var relayRelaunchGrace: TimeInterval = RelayHelper.defaultRelaunchGrace

    /// `applicationSupport` and `caches` default to this user's folders; tests pass stand-ins.
    public init(engine: BrowserEngine, storage: URL, applicationSupport: URL? = nil, caches: URL? = nil) {
        self.engine = engine
        let path = storage.standardizedFileURL
        self.storage = ProcessInspection.canonicalURL(path, isDirectory: true)
            ?? ProcessInspection.canonicalURL(path.deletingLastPathComponent(), isDirectory: true)?
                .appendingPathComponent(path.lastPathComponent, isDirectory: true)
            ?? path
        let folders = FileManager.default
        let support = applicationSupport ?? folders.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let cache = caches ?? folders.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.applicationSupport = support.map { ProcessInspection.canonicalURL($0, isDirectory: true) ?? $0.standardizedFileURL }
        self.caches = cache.map { ProcessInspection.canonicalURL($0, isDirectory: true) ?? $0.standardizedFileURL }
        let configuration = URLSessionConfiguration.loopback
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        localSession = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    deinit {
        localSession.invalidateAndCancel()
        for watcher in watchers.values { watcher.source.cancel() }
    }

    public func dataDirectory(for id: UUID) -> URL {
        storage.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// The root of the Profile's HTTP and code caches as Chromium places them: with the data
    /// directory in ~/Library/Application Support, the same relative path under ~/Library/Caches
    /// (`~/Library/Caches/AnyBrowser/Profiles/<uuid>`); otherwise the data directory itself.
    public func cacheDirectory(for id: UUID) -> URL {
        separateCacheDirectory(for: id) ?? dataDirectory(for: id)
    }

    /// `cacheDirectory(for:)` when it is not the data directory.
    func separateCacheDirectory(for id: UUID) -> URL? {
        separateCacheLocation(of: dataDirectory(for: id))
    }

    func separateCacheLocation(of directory: URL) -> URL? {
        guard let applicationSupport, let caches, directory.path.hasPrefix(applicationSupport.path + "/") else { return nil }
        let relative = String(directory.path.dropFirst(applicationSupport.path.count + 1))
        return caches.appendingPathComponent(relative, isDirectory: true)
    }

    public func status(for id: UUID) -> BrowserRunState { states[id] ?? .stopped }

    /// The browser's stdout and stderr of the Profile's latest launch by this runtime, up to the
    /// last 64 KB; nil when this runtime has not launched it.
    public func launchLog(for id: UUID) -> String? { logs[id]?.text }

    /// Brings the Profile's browser windows to the front. False when it is not running as this
    /// Profile's verified browser, or macOS did not activate it.
    @discardableResult
    public func activate(_ id: UUID) -> Bool {
        guard case let .running(pid, port, _) = status(for: id) else { return false }
        let directory = dataDirectory(for: id)
        guard let receipt = readReceipt(directory), receipt.pid == pid, receipt.port == port,
              owns(receipt, directory: directory),
              let application = NSRunningApplication(processIdentifier: pid) else { return false }
        if application.isHidden { application.unhide() }
        if #available(macOS 14, *) {
            // Since macOS 14 an app comes forward at once when the active app yields to it; from
            // the background, as through the automation API, it is only a request.
            NSApp?.yieldActivation(to: application)
            if application.activate(from: NSRunningApplication.current, options: [.activateAllWindows]) { return true }
            return application.activate(options: [.activateAllWindows])
        }
        return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    public func matchesRunningConfiguration(_ profile: BrowserProfile) -> Bool? {
        guard case let .running(pid, _, _) = status(for: profile.id) else { return nil }
        let directory = dataDirectory(for: profile.id)
        guard let receipt = readReceipt(directory), receipt.pid == pid, owns(receipt, directory: directory),
              let arguments = ProcessInspection.arguments(pid), ProcessStamp.read(pid) == receipt.stamp else { return nil }
        // The relay listens on a new port at every launch; what counts is that it still runs and
        // goes to the proxy the Profile names now.
        var relayPort: Int?
        if let relay = receipt.relay {
            guard ownsRelay(relay, directory: directory),
                  let chain = try? ProxyChain.parse(proxy: profile.proxy, transitProxy: profile.transitProxy),
                  chain.needsRelay, relay.upstream == RelayReceipt.digest(chain) else { return false }
            relayPort = relay.port
        }
        return arguments.dropFirst().elementsEqual(launchArguments(profile, directory: directory, relayPort: relayPort))
    }

    /// Starts the Profile's browser. Passkey Box signs in with `passkeyBox` when it is set.
    /// `startedFresh` is false when it found the Profile's browser already running and left it as it was.
    /// Start pages open once the browser is ready; problems with them come back as `warnings`.
    @discardableResult
    public func start(_ profile: BrowserProfile, passkeyBox: PasskeyBoxAccount? = nil,
                      overrides: LaunchOverrides = LaunchOverrides()) async throws -> LaunchOutcome {
        let profile = try profile.validated()
        let id = profile.id
        guard status(for: id) != .starting && status(for: id) != .stopping else { return LaunchOutcome(startedFresh: false) }
        let startURLs = try overrides.urls.map { try LaunchOptions(startURLs: $0).validated().startURLs }
            ?? profile.launch.startURLs
        let extraArguments = try Self.checkedArguments(overrides.arguments)
        let directory = dataDirectory(for: id)
        states[id] = .starting
        do {
            try PrivateDirectory.ensure(storage)
            try PrivateDirectory.ensure(directory.deletingLastPathComponent())
            try PrivateDirectory.ensure(directory)
            let lock = try lockDirectory(directory)
            defer { close(lock) }
            let saved = readReceipt(directory)
            if let running = await runningBrowser(directory, receipt: saved, ports: [saved?.port, profile.port]) {
                states[id] = .running(pid: running.receipt.pid, port: running.receipt.port, debugReady: running.ready)
                watchExit(of: running.receipt.pid, for: id)
                if overrides.resetSiteData {
                    throw BrowserRuntimeError.message("浏览器正在运行，无法在启动前清理站点数据，请先停止它。")
                }
                if !running.ready {
                    throw BrowserRuntimeError.message("浏览器正在运行，但本机调试端口 \(running.receipt.port) 尚未就绪。")
                }
                return LaunchOutcome(startedFresh: false, warnings: running.warnings)
            }
            guard !profileInUse(directory) else {
                throw BrowserRuntimeError.message("此 Profile 的资料目录正在使用，请先在浏览器中退出。")
            }
            guard ProcessInspection.portAvailable(profile.port) else {
                throw portConflict(profile.port, for: id)
            }
            try profile.launch.checkExtensionDirectories()
            try ProfileExtensions.check(for: profile, in: storage)
            try PasskeyBoxInstall.prepare(bundled: engine.passkeyBoxDirectory, in: storage, for: id, account: passkeyBox,
                                          enabled: profile.launch.loadPasskeyBox)
            if IdentityShim.isNeeded(for: engine.version, profile: profile) {
                try IdentityShim.prepare(for: profile, in: storage)
            }
            ProfileExtensions.removeLegacyProxySignIn(in: storage, for: id)
            if overrides.resetSiteData {
                // Under the directory lock and before the browser exists, so nothing writes the old data back.
                try await removeSiteData(for: id)
            }
            // The bundled engine blocks third-party cookies by default; a stock Chrome does not, and
            // Stripe's `.m.stripe.com` anchor only exists while they are allowed.
            try? ThirdPartyCookiePosture.apply(in: directory)
            stopWatching(id)
            let log = LaunchLog()
            logs[id] = log
            // Read continuously: a pipe nobody reads blocks Chromium once its buffer fills.
            let output = Pipe()
            log.read(from: output.fileHandleForReading)
            // The relay has to listen before the browser starts, since its port goes into the arguments.
            var relay: RelayLaunch?
            if let chain = try ProxyChain.parse(proxy: profile.proxy, transitProxy: profile.transitProxy), chain.needsRelay {
                do {
                    relay = try await startRelay(to: chain, directory: directory, output: output, log: log)
                } catch {
                    output.fileHandleForReading.readabilityHandler = nil
                    throw error
                }
            }
            let arguments = launchArguments(profile, directory: directory, relayPort: relay?.receipt.port)
                + (overrides.headless ? ["--headless=new"] : []) + extraArguments
            let child = Process()
            child.executableURL = engine.executable
            child.arguments = arguments
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = output
            child.terminationHandler = { [weak self] process in
                let pid = process.processIdentifier
                let exit = ExitStatus(process)
                Task { @MainActor [weak self] in self?.childExited(id: id, pid: pid, exit: exit) }
            }
            do {
                try child.run()
            } catch {
                // Without a child the pipe never reaches its end; the handles close when released.
                output.fileHandleForReading.readabilityHandler = nil
                if let relay { await end(relay.process) }
                throw error
            }
            children[id] = child
            relay?.hand(over: child.processIdentifier)
            var launchReceipt: Receipt?
            do {
                let details = try PrivateDirectory.check(directory)
                guard let stamp = ProcessStamp.read(child.processIdentifier) else {
                    throw await launchFailure("Chromium 在调试端口就绪前退出", child: child, log: log)
                }
                let receipt = Receipt(pid: child.processIdentifier, stamp: stamp, port: profile.port,
                                      device: details.st_dev, inode: details.st_ino, relay: relay?.receipt)
                try JSONEncoder().encode(receipt).write(to: receiptURL(directory), options: .atomic)
                launchReceipt = receipt
                let deadline = ProcessInfo.processInfo.systemUptime + readinessTimeout
                while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    if let endpoint = await verifiedEndpoint(receipt, directory: directory) {
                        let placeholders = Self.placeholderCount(arguments)
                        var warnings: [String] = []
                        // Before the first navigation, so the identity is settled when the page loads.
                        if !startURLs.isEmpty {
                            let seeding = await Self.seedStripeIdentity(profile, startURLs: startURLs,
                                                                        endpoint: endpoint)
                            warnings += seeding
                            if profile.launch.restoreSession,
                               !seeding.contains(where: { $0.contains("未能读取 Cookie") }) {
                                warnings.append("已恢复上次会话：旧标签页可能早于设备 Cookie 写入。")
                            }
                        }
                        if !startURLs.isEmpty || placeholders > 0 || profile.launch.restoreSession {
                            warnings += await Self.openStartPages(startURLs, endpoint: endpoint, placeholders: placeholders,
                                                                 budget: startPageBudget)
                        }
                        guard owns(receipt, directory: directory) else {
                            throw await launchFailure("Chromium 在打开启动网址时退出", child: child, log: log)
                        }
                        states[id] = .running(pid: receipt.pid, port: receipt.port, debugReady: true)
                        return LaunchOutcome(startedFresh: true, warnings: warnings)
                    }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                throw await launchFailure(child.isRunning ? "Chromium 未能在本机端口 \(profile.port) 启用调试"
                                                          : "Chromium 在调试端口就绪前退出",
                                          child: child, log: log)
            } catch {
                let kept = await abandon(child, receipt: launchReceipt, directory: directory, id: id)
                if !kept, let relay { await end(relay.process) }
                throw error
            }
        } catch {
            if status(for: id) == .starting {
                states[id] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Stops the Profile's browser. `force` sends SIGKILL instead of asking it to quit, for a
    /// browser that did not quit within the graceful timeout; ownership is verified right before.
    public func stop(_ id: UUID, force: Bool = false) async throws {
        let oldState = status(for: id)
        guard oldState != .starting && oldState != .stopping else { return }
        let directory = dataDirectory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            states[id] = .stopped
            return
        }
        let lock = try lockDirectory(directory)
        defer { close(lock) }
        let saved = readReceipt(directory)
        var knownPort: Int?
        if case let .running(_, port, _) = oldState { knownPort = port }
        guard let receipt = saved.flatMap({ owns($0, directory: directory) ? $0 : nil })
                ?? adoptLockHolder(directory, ports: [saved?.port, knownPort], relay: saved?.relay) else {
            if profileInUse(directory) {
                throw BrowserRuntimeError.message("无法确认该浏览器进程的归属，请从浏览器窗口退出。")
            }
            // The browser is gone already. Its relay stays: a browser relaunching itself
            // (chrome://restart) holds no lock for a moment and comes back through it. The relay
            // exits by itself when no browser does.
            states[id] = .stopped
            return
        }
        states[id] = .stopping
        do {
            // Revalidate just before signalling. Never signal by name or port.
            guard owns(receipt, directory: directory) else {
                throw BrowserRuntimeError.message("浏览器进程已变化，请刷新状态。")
            }
            if force {
                guard kill(receipt.pid, SIGKILL) == 0 else {
                    throw BrowserRuntimeError.message("无法强制结束此 Profile 的浏览器进程。")
                }
            } else if !askToQuit(receipt) {
                // Without an app to ask, the browser closes itself over its DevTools endpoint; a
                // headless Chromium ignores SIGTERM. What still runs a moment later gets SIGTERM.
                let closing = await closeOverDevTools(receipt, directory: directory)
                if closing {
                    await waitUntil(seconds: min(2, stopTimeout)) { ProcessStamp.read(receipt.pid) != receipt.stamp }
                }
                if ProcessStamp.read(receipt.pid) == receipt.stamp {
                    guard owns(receipt, directory: directory), kill(receipt.pid, SIGTERM) == 0 || closing else {
                        throw BrowserRuntimeError.message("无法关闭此 Profile 的浏览器进程。")
                    }
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + (force ? 5 : stopTimeout)
            while ProcessStamp.read(receipt.pid) == receipt.stamp {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw BrowserRuntimeError.message(force ? "浏览器进程没有响应强制结束，请稍后刷新状态。"
                                                            : "浏览器尚未退出，请在窗口中处理确认提示。")
                }
                try await Task.sleep(nanoseconds: force ? 50_000_000 : 100_000_000)
            }
            try? FileManager.default.removeItem(at: receiptURL(directory))
            await endRelay(receipt.relay, directory: directory)
            stopWatching(id)
            states[id] = .stopped
        } catch {
            states[id] = await runningState(receipt, directory: directory)
            throw error
        }
    }

    /// Asks the browser's app to quit, as its user would, so it saves what it holds; a window may
    /// first ask the user to confirm. False for a headless browser, which is no app to quit.
    private func askToQuit(_ receipt: Receipt) -> Bool {
        let headless = ProcessInspection.arguments(receipt.pid)?.dropFirst().prefix { $0 != "--" }
            .contains { $0 == "--headless" || $0.hasPrefix("--headless=") } == true
        return !headless && NSRunningApplication(processIdentifier: receipt.pid)?.terminate() == true
    }

    /// Sends Browser.close to the browser's verified DevTools endpoint; true once it was sent.
    private func closeOverDevTools(_ receipt: Receipt, directory: URL) async -> Bool {
        guard let endpoint = await verifiedEndpoint(receipt, directory: directory),
              let client = try? DevToolsClient(endpoint: endpoint, timeout: 2) else { return false }
        defer { client.close() }
        do {
            _ = try await client.send("Browser.close")
        } catch is DevToolsCommandError {
            return false
        } catch {
            // The browser may close the connection before it replies.
        }
        return true
    }

    public func refresh(_ profiles: [BrowserProfile]) async {
        for profile in profiles {
            let id = profile.id
            let previous = status(for: id)
            guard previous != .starting && previous != .stopping else { continue }
            let directory = dataDirectory(for: id)
            let saved = readReceipt(directory)
            var receipt = saved
            var adopted = false
            var result: BrowserRunState = .stopped
            if let saved {
                result = await runningState(saved, directory: directory)
            }
            // The browser may have replaced itself, or AnyBrowser quit before writing the receipt.
            if result == .stopped, ProcessInspection.lockHolder(directory) != nil, let lock = try? lockDirectory(directory) {
                if let holder = adoptLockHolder(directory, ports: [saved?.port, profile.port], relay: saved?.relay) {
                    receipt = holder
                    adopted = true
                    result = await runningState(holder, directory: directory)
                }
                close(lock)
            }
            guard let receipt else {
                if case .running = previous { states[id] = .stopped }
                continue
            }
            guard status(for: id) == previous, readReceipt(directory) == receipt else { continue }
            if result == .stopped, case .failed = previous { continue }
            if case let .running(pid, _, _) = result { watchExit(of: pid, for: id) }
            if result != previous { states[id] = result }
            if adopted, case .running(_, _, true) = result {
                // Nobody waits on a refresh; problems go to the launch log, if there is one.
                for warning in await closePlaceholders(receipt, directory: directory) { logs[id]?.note(warning) }
            }
        }
    }

    private func childExited(id: UUID, pid: Int32, exit: ExitStatus) {
        guard children[id]?.processIdentifier == pid else { return }
        children[id] = nil
        logs[id]?.note("Chromium 已退出（\(exit)）")
        if case .running(let runningPID, _, _) = status(for: id), runningPID == pid {
            states[id] = .stopped
        }
    }

    /// Notices when a running browser that is not this process's child exits. Children report
    /// through their termination handler instead.
    private func watchExit(of pid: Int32, for id: UUID) {
        guard children[id]?.processIdentifier != pid, watchers[id]?.pid != pid else { return }
        stopWatching(id)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.watchedProcessExited(id: id, pid: pid) }
        }
        watchers[id] = (pid, source)
        source.resume()
        // A process that exited before the source was armed may never be reported.
        if ProcessStamp.read(pid) == nil { watchedProcessExited(id: id, pid: pid) }
    }

    private func watchedProcessExited(id: UUID, pid: Int32) {
        guard watchers[id]?.pid == pid else { return }
        stopWatching(id)
        if case .running(let runningPID, _, _) = status(for: id), runningPID == pid {
            states[id] = .stopped
        }
    }

    private func stopWatching(_ id: UUID) {
        watchers.removeValue(forKey: id)?.source.cancel()
    }

    private func launchArguments(_ profile: BrowserProfile, directory: URL, relayPort: Int?) -> [String] {
        var extensions = ProfileExtensions.paths(for: profile, in: storage)
        if IdentityShim.isNeeded(for: engine.version, profile: profile) {
            extensions.append(IdentityShim.directory(in: storage, for: profile.id))
        }
        return profile.launchArguments(userDataDirectory: directory, extensions: extensions, relayPort: relayPort)
            + additionalArguments
    }

    /// Switches that decide which process is a Profile's browser, or take its endpoint away.
    private static let ownershipSwitches: Set<String> = [
        "--user-data-dir", "--remote-debugging-port", "--remote-debugging-pipe",
        "--remote-debugging-address", "--remote-debugging-io-pipes",
    ]

    /// Launch-only switches as given, once each is known to be a `--` switch that leaves the
    /// Profile's ownership checks and fingerprint intact. A positional argument would open as a
    /// tab, and a bare `--` would hide every later argument from those checks.
    static func checkedArguments(_ arguments: [String]) throws -> [String] {
        guard arguments.count <= 64 else { throw ProfileError.invalid("单次启动参数最多 64 个。") }
        for argument in arguments {
            let name = String(argument.prefix { $0 != "=" })
            guard argument.hasPrefix("--"), name.count > 2, argument.utf8.count <= 4096,
                  !argument.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProfileError.invalid("启动参数须为以 -- 开头的 Chromium 开关：\(argument.prefix(80))")
            }
            guard !ownershipSwitches.contains(name) else {
                throw ProfileError.invalid("启动参数不能包含 \(name)。")
            }
            // The last value wins in Chromium, and the identity shim is computed from the Profile's seed.
            guard name != "--fingerprint", !name.hasPrefix("--fingerprint-") else {
                throw ProfileError.invalid("启动参数不能包含 \(name)，指纹请在 Profile 里修改。")
            }
        }
        return arguments
    }

    /// The browser-level DevTools WebSocket of a running Profile, verified to belong to it.
    public func devToolsEndpoint(for id: UUID) async -> URL? {
        guard case let .running(pid, port, _) = status(for: id) else { return nil }
        let directory = dataDirectory(for: id)
        guard let receipt = readReceipt(directory), receipt.pid == pid, receipt.port == port else { return nil }
        return await verifiedEndpoint(receipt, directory: directory)
    }

    /// The Profile's running browser: the one its receipt names, or else the one holding the data
    /// directory's SingletonLock once it passes every ownership check.
    private func runningBrowser(_ directory: URL, receipt: Receipt?,
                                ports: [Int?]) async -> (receipt: Receipt, ready: Bool, warnings: [String])? {
        if let receipt, case let .running(_, _, ready) = await runningState(receipt, directory: directory) {
            return (receipt, ready, [])
        }
        guard let adopted = adoptLockHolder(directory, ports: ports, relay: receipt?.relay),
              case let .running(_, _, ready) = await runningState(adopted, directory: directory) else { return nil }
        return (adopted, ready, ready ? await closePlaceholders(adopted, directory: directory) : [])
    }

    /// A browser that relaunched itself brings its `(xx)` placeholder tabs back with the session.
    /// They are closed as at launch, but no start page opens: the user restarted what was open.
    private func closePlaceholders(_ receipt: Receipt, directory: URL) async -> [String] {
        guard let endpoint = await verifiedEndpoint(receipt, directory: directory) else { return [] }
        return await Self.openStartPages([], endpoint: endpoint, placeholders: 0, waitingForTabs: false,
                                         budget: startPageBudget)
    }

    /// Writes a receipt for the process the data directory's SingletonLock names when it is this
    /// engine on exactly this directory and one of `ports`, as after chrome://restart, which gives
    /// the browser a new pid. The caller holds the directory lock. `owns` repeats every check, and
    /// the start time is read once more right before writing, so a pid that exited and was reused
    /// in between is never recorded. The relay the browser goes through is kept: `relay` from the
    /// previous receipt, or the helper listening where the browser's arguments say.
    private func adoptLockHolder(_ directory: URL, ports: [Int?], relay: RelayReceipt?) -> Receipt? {
        guard let pid = ProcessInspection.lockHolder(directory), let stamp = ProcessStamp.read(pid),
              let details = try? PrivateDirectory.check(directory),
              let arguments = ProcessInspection.arguments(pid) else { return nil }
        var seen: Set<Int> = []
        for port in ports.compactMap({ $0 }) where seen.insert(port).inserted
            && ProcessInspection.hasFlag("--remote-debugging-port", value: String(port), arguments: arguments) {
            let receipt = Receipt(pid: pid, stamp: stamp, port: port, device: details.st_dev, inode: details.st_ino,
                                  relay: adoptedRelay(arguments: arguments, saved: relay, directory: directory))
            guard owns(receipt, directory: directory), ProcessStamp.read(pid) == stamp,
                  (try? JSONEncoder().encode(receipt).write(to: receiptURL(directory), options: .atomic)) != nil
            else { return nil }
            return receipt
        }
        return nil
    }

    private func runningState(_ receipt: Receipt, directory: URL) async -> BrowserRunState {
        guard owns(receipt, directory: directory) else { return .stopped }
        let ready = await verifyEndpoint(receipt, directory: directory)
        guard owns(receipt, directory: directory) else { return .stopped }
        return .running(pid: receipt.pid, port: receipt.port, debugReady: ready)
    }

    private func verifyEndpoint(_ receipt: Receipt, directory: URL) async -> Bool {
        await verifiedEndpoint(receipt, directory: directory) != nil
    }

    private func verifiedEndpoint(_ receipt: Receipt, directory: URL) async -> URL? {
        guard owns(receipt, directory: directory),
              ProcessInspection.hasLoopbackDebugListener(pid: receipt.pid, port: receipt.port),
              let url = URL(string: "http://127.0.0.1:\(receipt.port)/json/version"),
              let (data, response) = try? await localSession.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let address = info["webSocketDebuggerUrl"],
              let endpoint = URL(string: address), DevToolsClient.accepts(endpoint),
              endpoint.port == receipt.port else { return nil }
        guard owns(receipt, directory: directory),
              ProcessInspection.hasLoopbackDebugListener(pid: receipt.pid, port: receipt.port) else { return nil }
        return endpoint
    }

    private func owns(_ receipt: Receipt, directory: URL) -> Bool {
        guard ProcessStamp.read(receipt.pid) == receipt.stamp,
              let details = try? PrivateDirectory.check(directory),
              details.st_dev == receipt.device, details.st_ino == receipt.inode,
              let image = ProcessInspection.image(receipt.pid),
              ProcessInspection.hasFlag("--user-data-dir", value: directory.path, arguments: image.arguments),
              ProcessInspection.hasFlag("--remote-debugging-port", value: String(receipt.port), arguments: image.arguments)
        else { return false }

        let child = UUID(uuidString: directory.lastPathComponent).flatMap { children[$0] }
        let trackedChild = child?.processIdentifier == receipt.pid && child?.isRunning == true
        // macOS can report a code-signing clone through proc_pidpath. The initial
        // executable path in the process argument area still identifies the bundle we launched.
        // The recorded path may name it through a link, such as /tmp for /private/tmp.
        let executableConfirmed = trackedChild || image.executablePath == engine.executable.path
            || ProcessInspection.canonicalURL(URL(fileURLWithPath: image.executablePath)) == engine.executable
            || ProcessInspection.executable(receipt.pid) == engine.executable
        return executableConfirmed && ProcessStamp.read(receipt.pid) == receipt.stamp
    }

    func profileInUse(_ directory: URL) -> Bool {
        guard let pid = ProcessInspection.lockHolder(directory) else { return false }
        guard let arguments = ProcessInspection.arguments(pid) else { return true }
        return ProcessInspection.hasFlag("--user-data-dir", value: directory.path, arguments: arguments)
    }

    /// Names what holds the port: one of this runtime's running Profiles, or another program.
    private func portConflict(_ port: Int, for id: UUID) -> Error {
        let takenByProfile = states.contains { other, state in
            guard other != id, case .running(_, let used, _) = state else { return false }
            return used == port
        }
        if takenByProfile {
            return BrowserRuntimeError.message("调试端口 \(port) 已被另一个正在运行的 Profile 占用，请修改此 Profile 的端口。")
        }
        if let holder = ProcessInspection.listener(onPort: port) {
            return BrowserRuntimeError.message("调试端口 \(port) 已被「\(holder.name)」（PID \(holder.pid)）占用，请修改此 Profile 的端口。")
        }
        return BrowserRuntimeError.message("调试端口 \(port) 已占用，请修改此 Profile 的端口。")
    }

    /// The failure message, with how the browser exited and the last lines it printed.
    private func launchFailure(_ reason: String, child: Process, log: LaunchLog) async -> Error {
        var text = reason
        if !child.isRunning || ProcessStamp.read(child.processIdentifier) == nil {
            // The exit status is only readable once Process has seen the exit.
            await waitUntil(seconds: 1) { !child.isRunning }
            if !child.isRunning {
                text += "（\(ExitStatus(child))）"
                await log.waitForEnd(seconds: 0.5)
            }
        }
        text += "。"
        let tail = log.tail(lines: 6)
        if !tail.isEmpty { text += "\n最近的输出：\n" + tail }
        return BrowserRuntimeError.message(text)
    }

    /// Ends a browser this launch started and that will not become ready: SIGTERM, then SIGKILL
    /// once `terminationGrace` has passed. Only this launch's own child is signalled. True when the
    /// browser is still there afterwards, and stays recorded as the Profile's.
    @discardableResult
    private func abandon(_ child: Process, receipt: Receipt?, directory: URL, id: UUID) async -> Bool {
        if child.isRunning { child.terminate() }
        await waitUntil(seconds: terminationGrace) { !child.isRunning }
        if child.isRunning, receipt.map({ ProcessStamp.read(child.processIdentifier) == $0.stamp }) ?? true {
            kill(child.processIdentifier, SIGKILL)
            await waitUntil(seconds: 2) { !child.isRunning }
        }
        guard let receipt else { return false }
        if owns(receipt, directory: directory) {
            states[id] = .running(pid: receipt.pid, port: receipt.port, debugReady: false)
            return true
        }
        try? FileManager.default.removeItem(at: receiptURL(directory))
        return false
    }

    /// Polls `condition` for up to `seconds`. It keeps waiting in a cancelled task, so a cancelled
    /// launch still cleans up after itself.
    func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { continuation.resume() }
            }
        }
    }

    func receiptURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(".anybrowser-runtime.json")
    }

    private func readReceipt(_ directory: URL) -> Receipt? {
        guard (try? PrivateDirectory.check(directory)) != nil else { return nil }
        let fd = open(receiptURL(directory).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, (1...4096).contains(metadata.st_size),
              let data = try? file.read(upToCount: 4096) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    func lockDirectory(_ directory: URL) throws -> Int32 {
        try PrivateDirectory.check(directory)
        let url = directory.appendingPathComponent(".anybrowser-runtime.lock")
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BrowserRuntimeError.message("无法锁定此 Profile 的资料目录。") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw BrowserRuntimeError.message("此 Profile 正在执行另一个操作，请稍后重试。")
        }
        // A process another thread is spawning holds a copy of a lock just released until it
        // execs, which takes milliseconds; a real concurrent operation holds it far longer.
        var waited: useconds_t = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, waited < Self.lockRetryWindow else {
                close(fd)
                throw BrowserRuntimeError.message("此 Profile 正在执行另一个操作，请稍后重试。")
            }
            usleep(10_000)
            waited += 10_000
        }
        return fd
    }

    /// How long `lockDirectory` waits for a lock that is about to be released, in microseconds.
    static let lockRetryWindow: useconds_t = 250_000
}
