import Combine
import Foundation

/// What a launch does with the site data of an earlier identity when the fingerprint's seed or
/// platform changed since the Profile last launched, and no identity reset is pending.
public enum FingerprintChangeHandling: Sendable {
    /// Keeps the data and says so in the launch's warnings; the API and batch launches never wait
    /// for a decision.
    case warn
    /// Deletes the site data right before the browser starts, as an identity reset does.
    case clearSiteData
    /// Keeps the data without a warning: the user chose to.
    case keepSiteData
}

/// Starts, stops and tracks the Profiles' browsers for every caller: the window, batch actions and
/// the automation API. It owns the rules a launch follows (busy Profiles, the Passkey Box account,
/// the proxy check, launch slots, pending identity resets) and what the running browsers were
/// started with. Messages for the user come back as values; it shows nothing itself.
@MainActor
public final class LaunchCoordinator: ObservableObject {
    public let store: ProfileStore
    public let runtime: BrowserRuntime
    /// The automation API's settings and server, answered by this coordinator.
    public let automation: AutomationHost
    /// The proxy library and the last exit seen for each Profile.
    public let proxyLibrary: ProxyLibrary
    /// Warnings found after a launch went ahead without them, such as an exit lookup that took
    /// longer than the launch: for a notice, since the caller has its outcome already.
    public let lateWarnings = PassthroughSubject<(profile: UUID, warnings: [String]), Never>()

    /// Profiles being started, stopped or restarted here, including those waiting for a launch slot.
    @Published public private(set) var launches: Set<UUID> = [] {
        didSet { updateActivity() }
    }
    /// The part of `launches` waiting for one of the `maximumConcurrentLaunches` slots.
    @Published public private(set) var queued: Set<UUID> = []
    /// Profiles whose files are being deleted.
    @Published public internal(set) var removing: Set<UUID> = []
    /// Profiles getting a new identity, or having the old identity's site data deleted.
    @Published public internal(set) var regenerating: Set<UUID> = []
    /// The batch action in progress, if any.
    @Published public internal(set) var batch: BatchProgress?
    /// Profiles a full backup is reading; they cannot be started, stopped or changed meanwhile.
    @Published public internal(set) var archiving: Set<UUID> = []
    /// The Profiles that existed when a restore began; every Profile it adds is busy until it ends.
    @Published public internal(set) var restoreBaseline: Set<UUID>?

    /// How many browsers start at the same time, whoever asked; the others wait in turn. Each
    /// launch's readiness timeout only begins once it has a slot.
    public var maximumConcurrentLaunches = 3

    /// How old a Profile's recorded exit may be before a launch looks it up again.
    public var exitReviewAge: TimeInterval = 30 * 60

    // Tests replace these.
    var proxyPreflight: (String) async -> String? = { await ProxyProbe.preflight($0) }
    var exitLookup: (String) async -> ProxyExit? = { proxy in
        guard let chain = try? ProxyChain.parse(spec: proxy) else { return nil }
        return try? await ProxyProbe.lookupExit(through: chain)
    }
    /// How long after a browser exits it is still polled for, in case it relaunched itself.
    var relaunchWindow: TimeInterval = 30
    /// Exit lookups in flight, by proxy address: launches through the same proxy share one.
    var exitLookups: [String: Task<ProxyExit?, Never>] = [:]

    /// What each running browser was started with here, by pid. One adopted after AnyBrowser
    /// restarted, or relaunched by the browser itself, has no entry.
    private var launched: [UUID: (pid: Int32, profile: BrowserProfile)] = [:]
    private var activeLaunches = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    /// Profiles polled at least once since AnyBrowser started.
    private var observed: Set<UUID> = []
    /// When a browser was last seen exiting, as system uptime.
    private var exits: [UUID: TimeInterval] = [:]
    private var monitor: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []

    public init(store: ProfileStore, runtime: BrowserRuntime) {
        self.store = store
        self.runtime = runtime
        proxyLibrary = ProxyLibrary(store: store)
        automation = AutomationHost(store: store)
        automation.backend = self
        runtime.$states.sink { [weak self] states in self?.statesChanging(to: states) }
            .store(in: &subscriptions)
        automation.$status.sink { [weak self] status in self?.updateActivity(automation: status) }
            .store(in: &subscriptions)
    }

    deinit {
        monitor?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    public var profiles: [BrowserProfile] { store.profiles }

    public func state(for id: UUID) -> BrowserRunState { runtime.status(for: id) }

    public func isBusy(_ id: UUID) -> Bool {
        if launches.contains(id) || removing.contains(id) || regenerating.contains(id) || archiving.contains(id) {
            return true
        }
        if let restoreBaseline, !restoreBaseline.contains(id) { return true }
        let state = runtime.status(for: id)
        return state == .starting || state == .stopping
    }

    /// The account the Profile's Passkey Box signs in with: its own, or else the global one.
    public func effectiveAccount(for profile: BrowserProfile) -> PasskeyBoxAccount? {
        profile.passkeyBox ?? store.passkeyBoxAccount
    }

    // MARK: Pending restart

    /// Whether the running browser was started with a configuration the saved Profile no longer
    /// has. The name, the start pages (opened over DevTools) and one-off launch overrides do not count.
    public func hasPendingRestart(_ id: UUID) -> Bool {
        guard case let .running(pid, port, _) = runtime.status(for: id),
              let stored = profile(id) else { return false }
        if stored.port != port || store.pendingIdentityReset(id) { return true }
        if let started = launched[id], started.pid == pid {
            return Self.needsRestart(started.profile, toRun: stored, account: effectiveAccount(for: stored))
        }
        // Adopted after AnyBrowser restarted, or relaunched by the browser itself: only its command
        // line tells. Its window name is the name it started with.
        var expected = stored
        if let name = ProcessInspection.arguments(pid)?.last(where: { $0.hasPrefix(Self.windowNameSwitch) }) {
            expected.name = String(name.dropFirst(Self.windowNameSwitch.count))
        }
        return runtime.matchesRunningConfiguration(expected) != true
    }

    private static let windowNameSwitch = "--window-name="

    /// Whether a browser started with `launched` (which carries the account it signed in with)
    /// must restart to run `stored`.
    static func needsRestart(_ launched: BrowserProfile, toRun stored: BrowserProfile, account: PasskeyBoxAccount?) -> Bool {
        var startedOptions = launched.launch
        var storedOptions = stored.launch
        startedOptions.startURLs = []
        storedOptions.startURLs = []
        if launched.fingerprint != stored.fingerprint || launched.proxy != stored.proxy
            || launched.transitProxy != stored.transitProxy || startedOptions != storedOptions {
            return true
        }
        // A different account takes effect on restart; clearing the account does not sign the extension
        // out, and without Passkey Box no account matters.
        guard stored.launch.loadPasskeyBox, let account else { return false }
        return launched.passkeyBox != account
    }

    // MARK: Fingerprint changes

    /// Whether the saved fingerprint's seed or platform differ from the Profile's last launch while
    /// no identity reset is pending: the browser still holds site data the old identity left.
    /// False before the first recorded launch.
    public func fingerprintChangedSinceLastLaunch(_ id: UUID) -> Bool {
        profile(id).map(fingerprintChanged) ?? false
    }

    private func fingerprintChanged(_ profile: BrowserProfile) -> Bool {
        guard !store.pendingIdentityReset(profile.id), let last = store.lastLaunchFingerprint(profile.id) else { return false }
        return last.seed != profile.fingerprint.seed || last.platform != profile.fingerprint.platform
    }

    // MARK: Start and stop

    /// Starts the saved Profile's browser, or reports the one already running (`startedFresh`
    /// false). A pending identity reset deletes the old site data first and is cleared once the
    /// browser is up. Problems that do not stop the launch come back as `warnings`.
    @discardableResult
    public func start(_ id: UUID, overrides: LaunchOverrides = LaunchOverrides(),
                      fingerprintChange: FingerprintChangeHandling = .warn) async throws -> LaunchOutcome {
        try await launch(id, restarting: false, overrides: overrides, fingerprintChange: fingerprintChange, preflight: nil)
    }

    /// Stops the Profile's browser and starts it again with the saved configuration, as `start` does.
    @discardableResult
    public func restart(_ id: UUID, overrides: LaunchOverrides = LaunchOverrides(),
                        fingerprintChange: FingerprintChangeHandling = .warn) async throws -> LaunchOutcome {
        try await launch(id, restarting: true, overrides: overrides, fingerprintChange: fingerprintChange, preflight: nil)
    }

    func launch(_ id: UUID, restarting: Bool, overrides: LaunchOverrides, fingerprintChange: FingerprintChangeHandling,
                preflight: PreflightCache?) async throws -> LaunchOutcome {
        guard let requested = profile(id) else { throw ProfileError.invalid("找不到这个 Profile。") }
        guard !isBusy(id) else { throw ProfileError.invalid("「\(requested.name)」正在执行另一个操作。") }
        // A newer version's database cannot record that the old identity's data is gone, so every
        // launch would delete it again, including what the new identity stored since.
        guard !(store.isReadOnly && store.pendingIdentityReset(id)) else {
            throw ProfileError.invalid("「\(requested.name)」换了新身份，启动前要清除旧身份的网站数据，但当前数据库由更新版本的 AnyBrowser 写入，无法记下已经清除。请用那个版本启动它。")
        }
        launches.insert(id)
        defer { launches.remove(id) }
        // Runs beside the launch and never holds it up.
        let exitReview = reviewExit(of: requested)
        let proxyWarning = await (preflight ?? PreflightCache()).warning(for: requested.proxySpec, check: proxyPreflight)
        if restarting {
            try await runtime.stop(id)
            forgetLaunch(id)
        }
        queued.insert(id)
        await acquireLaunchSlot()
        queued.remove(id)
        defer { releaseLaunchSlot() }

        // Waiting may have taken a while; launch what is saved now.
        guard let profile = self.profile(id) else { throw ProfileError.invalid("「\(requested.name)」已被移除。") }
        var overrides = overrides
        var warnings: [String] = []
        let resetPending = store.pendingIdentityReset(id)
        if resetPending {
            overrides.resetSiteData = true
        } else if fingerprintChanged(profile) {
            switch fingerprintChange {
            case .warn:
                warnings.append("指纹种子或平台自上次启动后已改变，浏览器里仍是旧身份留下的网站数据；需要彻底换身份时用「整套重新生成」。")
            case .clearSiteData:
                overrides.resetSiteData = true
            case .keepSiteData:
                break
            }
        }
        var started = profile
        started.passkeyBox = effectiveAccount(for: profile)
        let outcome: LaunchOutcome
        do {
            outcome = try await runtime.start(profile, passkeyBox: started.passkeyBox, overrides: overrides)
        } catch {
            exitReview?.discard()
            throw error
        }
        // A browser that was already running keeps whatever configuration it was started with.
        guard outcome.startedFresh else {
            exitReview?.discard()
            return LaunchOutcome(startedFresh: false, warnings: outcome.warnings)
        }
        if case let .running(pid, _, _) = runtime.status(for: id) { launched[id] = (pid, started) }
        store.recordLaunch(id)
        store.recordLaunchFingerprint(id, profile.fingerprint)
        if resetPending {
            do {
                try store.setPendingIdentityReset(id, false)
            } catch {
                warnings.append("旧网站数据已清除，但未能更新记录（\(error.localizedDescription)），下次启动时会再清除一次。")
            }
        }
        // Whatever the exit review has not found by now is published when it does.
        warnings += exitReview?.warningsSoFar { [weak self] late in self?.lateWarnings.send((id, late)) } ?? []
        return LaunchOutcome(startedFresh: true, warnings: (proxyWarning.map { [$0] } ?? []) + warnings + outcome.warnings)
    }

    /// Stops the Profile's browser. `force` kills it, for one that did not quit within the timeout.
    public func stop(_ id: UUID, force: Bool) async throws {
        guard !isBusy(id) else { throw ProfileError.invalid("该 Profile 正在执行另一个操作。") }
        launches.insert(id)
        defer { launches.remove(id) }
        try await runtime.stop(id, force: force)
        forgetLaunch(id)
    }

    public func stop(_ id: UUID) async throws {
        try await stop(id, force: false)
    }

    /// Brings the Profile's browser windows to the front.
    @discardableResult
    public func activate(_ id: UUID) -> Bool { runtime.activate(id) }

    /// The running Profile's launch output, for showing after a failure.
    public func launchLog(for id: UUID) -> String? { runtime.launchLog(for: id) }

    private func forgetLaunch(_ id: UUID) {
        launched[id] = nil
        // Stopped here: it will not relaunch itself.
        exits[id] = nil
    }

    func profile(_ id: UUID) -> BrowserProfile? { store.profiles.first { $0.id == id } }

    private func acquireLaunchSlot() async {
        if activeLaunches < max(1, maximumConcurrentLaunches) {
            activeLaunches += 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    /// Hands the slot to the next launch in line, or frees it.
    private func releaseLaunchSlot() {
        if slotWaiters.isEmpty {
            activeLaunches -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: Status

    /// Polls the browsers' state every `interval` seconds for as long as AnyBrowser runs, with or
    /// without a window. Calling it again changes nothing.
    public func startMonitoring(every interval: TimeInterval = 3) {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshRunning()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    var isMonitoring: Bool { monitor != nil }
    /// How many polling rounds ran, for tests.
    private(set) var refreshes = 0

    /// Re-reads the state of the Profiles that need it: running or failed ones, ones not looked at
    /// since AnyBrowser started, and ones that exited a moment ago and may have relaunched
    /// themselves (chrome://restart). The others only change through a launch here, whose child
    /// reports its exit, or an adopted browser, whose exit is watched. Returns the ids it polled.
    @discardableResult
    func refreshRunning() async -> [UUID] {
        refreshes += 1
        let now = ProcessInfo.processInfo.systemUptime
        let targets = store.profiles.filter { profile in
            let id = profile.id
            if !observed.contains(id) || runtime.status(for: id) != .stopped { return true }
            return exits[id].map { now - $0 < relaunchWindow } ?? false
        }
        guard !targets.isEmpty else { return [] }
        await runtime.refresh(targets)
        observed.formUnion(targets.map(\.id))
        return targets.map(\.id)
    }

    private func statesChanging(to states: [UUID: BrowserRunState]) {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, state) in states where state == .stopped {
            if case .running = runtime.status(for: id) { exits[id] = now }
        }
        updateActivity(states: states)
    }

    // MARK: App Nap

    /// Whether AnyBrowser keeps App Nap away, as it does while the automation API listens, a
    /// browser runs or a launch is in progress: a napping app answers the API and notices exits late.
    var holdsActivity: Bool { activity != nil }

    private func updateActivity(states: [UUID: BrowserRunState]? = nil, automation status: AutomationHost.Status? = nil) {
        let status = status ?? automation.status
        let serving: Bool
        switch status {
        case .starting, .listening: serving = true
        case .stopped, .failed: serving = false
        }
        let browsing = (states ?? runtime.states).values.contains { state in
            switch state {
            case .running, .starting, .stopping: return true
            case .stopped, .failed: return false
            }
        }
        let needed = serving || browsing || !launches.isEmpty
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "AnyBrowser 正在管理运行中的浏览器或自动化接口")
        } else if !needed, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}

// MARK: AutomationBackend

extension LaunchCoordinator: AutomationBackend {
    public func devToolsEndpoint(for id: UUID) async -> URL? {
        await runtime.devToolsEndpoint(for: id)
    }

    public func refresh(_ id: UUID) async {
        guard let profile = profile(id) else { return }
        await runtime.refresh([profile])
        observed.insert(id)
    }
}

/// One proxy check per proxy for a group of launches, such as a batch: Profiles created together
/// usually share their proxy, and one that is down would otherwise make each wait. The check signs
/// in, so Profiles on the same server with different credentials are checked apart.
@MainActor
final class PreflightCache {
    private var checks: [String: Task<String?, Never>] = [:]

    func warning(for proxy: String, check: @escaping (String) async -> String?) async -> String? {
        guard let endpoint = try? ProxyEndpoint.parse(proxy) else { return nil }
        if let running = checks[endpoint.url] { return await running.value }
        let task = Task { await check(proxy) }
        checks[endpoint.url] = task
        return await task.value
    }
}
