import AnyBrowserCore
import AppKit
import Combine
import SwiftUI

/// The window's state: the draft being edited, notices, navigation and dialogs. Starting, stopping
/// and tracking browsers belongs to the `LaunchCoordinator`.
@MainActor
final class Workbench: ObservableObject {
    enum Destination {
        case new, profile(UUID)
        /// A copy of the selected Profile as saved.
        case clone
    }

    struct Notice {
        var text: String
        var isError = false
        /// A follow-up the banner offers.
        var action: NoticeAction? = nil
    }

    enum NoticeAction: Equatable {
        case showLaunchLog(UUID)
    }

    /// The selected Profile was saved elsewhere, in ways the draft does not show, while it holds edits.
    struct ExternalChange: Equatable {
        var id: UUID
        var fields: Set<ProfileDraft.Field>
    }

    /// The Profile a sheet or confirmation is about.
    struct ProfileSheet: Identifiable, Equatable {
        var id: UUID
    }

    /// The self-check sheet: running, done or failed.
    struct SelfCheckRun: Identifiable {
        enum Phase {
            case running
            case finished(SelfCheckReport)
            case failed(String)
        }

        var id: UUID
        var name: String
        var phase: Phase
        /// The browser runs an older configuration than the saved one the report compares with.
        var pendingRestart: Bool
    }

    /// A launch waiting for the user to decide what happens to the site data the old fingerprint left.
    struct FingerprintLaunch: Identifiable {
        var id: UUID
        var name: String
        var restart: Bool
    }

    let store: ProfileStore?
    let runtime: BrowserRuntime?
    /// Starts, stops and tracks the browsers; nil without the database or the built-in engine.
    let coordinator: LaunchCoordinator?
    let engineVersion: String?
    let engineError: String?
    @Published var draft: ProfileDraft? {
        didSet {
            // Another Profile, a clone or a new one: edits are now measured against it.
            if draft?.profile.id != oldValue?.profile.id { resetDraftOrigin() }
        }
    }
    /// What the draft started from; see `hasChanges`.
    @Published private(set) var draftOrigin: DraftOrigin?
    /// Set while the user decides between the draft's edits and changes saved elsewhere.
    @Published private(set) var externalChange: ExternalChange?
    @Published var notice: Notice?
    /// Running browsers, by pid, that did not quit when asked: they can be force-stopped.
    @Published private(set) var stopTimeouts: [UUID: Int32] = [:]
    @Published var pendingForceStop: ProfileSheet?
    @Published var pendingCancelNew = false
    @Published var launchLog: ProfileSheet?
    @Published var selfCheck: SelfCheckRun?
    @Published var showingSharedExtensions = false
    @Published var pendingDestination: Destination?
    @Published var pendingFingerprintLaunch: FingerprintLaunch?
    @Published var showingPasskeyBox = false
    @Published var showingAutomation = false
    @Published var showingBatchCreate = false
    let proxyCenter = ProxyCenter()
    let library = LibraryModel()
    let extensionShelf: ExtensionShelf
    let engineFreshness = EngineFreshness()
    /// The Profile selected before "新建 Profile", to go back to when the new one is cancelled.
    private var selectionBeforeNew: UUID?
    /// Keeps this process the only AnyBrowser on the data directory for as long as it runs.
    private let instanceLock: InstanceLock?
    private var activationObserver: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []

    /// `instance` is this process's claim on the data directory; when another AnyBrowser holds
    /// it, the database stays closed.
    init(instance: SingleInstance.Claim?) {
        let openedStore: ProfileStore?
        var problems: [String] = []
        instanceLock = instance?.lock
        if let failure = instance?.failure {
            openedStore = nil
            problems.append(failure)
        } else {
            do {
                openedStore = try ProfileStore(directory: ProfileStore.defaultDirectory())
            } catch {
                openedStore = nil
                problems.append(error.localizedDescription)
            }
        }

        let engineResult = Result { try BrowserEngine.bundled() }
        let engine = try? engineResult.get()
        store = openedStore
        if let engine, let openedStore {
            let runtime = BrowserRuntime(engine: engine, storage: openedStore.directory)
            self.runtime = runtime
            coordinator = LaunchCoordinator(store: openedStore, runtime: runtime)
        } else {
            runtime = nil
            coordinator = nil
        }
        engineVersion = engine?.version
        if case .failure(let error) = engineResult {
            engineError = error.localizedDescription
        } else {
            engineError = nil
        }

        extensionShelf = ExtensionShelf(storage: openedStore?.directory)
        draft = openedStore?.profiles.first.map(ProfileDraft.init)
        draftOrigin = draft.map { DraftOrigin(saved: $0.profile) }
        if let openedStore {
            if openedStore.isReadOnly {
                problems.append("本机 Profile 数据库由更新版本的 AnyBrowser 写入（数据库版本 \(openedStore.openedSchemaVersion)），"
                    + "当前版本只能查看，不能修改。请升级 AnyBrowser。")
            }
            if let failure = openedStore.backupFailure {
                problems.append("本机 Profile 数据库的自动备份失败：\(failure)")
            }
            if openedStore.unreadableProfiles > 0 {
                problems.append("有 \(openedStore.unreadableProfiles) 份 Profile 配置无法读取，已跳过。")
            }
        }
        if !problems.isEmpty {
            notice = Notice(text: problems.joined(separator: "\n"), isError: true)
        }

        var models = [proxyCenter.objectWillChange, library.objectWillChange, extensionShelf.objectWillChange,
                      engineFreshness.objectWillChange]
        if let openedStore { models.append(openedStore.objectWillChange) }
        if let coordinator {
            models += [coordinator.objectWillChange, coordinator.runtime.objectWillChange,
                       coordinator.automation.objectWillChange, coordinator.proxyLibrary.objectWillChange]
        }
        for model in models {
            model.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        // `profiles` publishes before it changes; look once the change is in.
        openedStore?.$profiles.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.followSavedChanges() }
            .store(in: &subscriptions)
        AppDelegate.workbench = self
        Task { [weak self] in await self?.extensionShelf.reload() }
        // Asked once at launch; the hourly look only sends a request once the day-long answer, or
        // the hour after a failure, has run out.
        Task { [weak self] in
            while let freshness = self?.engineFreshness {
                await freshness.refresh()
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
        library.coordinator = coordinator
        if let instance, instance.lock != nil {
            activationObserver = SingleInstance.listen(instance.directory)
        }
        guard let coordinator else { return }
        coordinator.lateWarnings.sink { [weak self] late in self?.showLate(late.warnings, for: late.profile) }
            .store(in: &subscriptions)
        // For as long as AnyBrowser runs, not only while its window is open.
        coordinator.startMonitoring()
        Task { await coordinator.automation.load() }
        Task { await coordinator.performLaunchMaintenance() }
    }

    static let storeUnavailable = "本机 Profile 数据库不可用。"

    var profiles: [BrowserProfile] { store?.profiles ?? [] }
    var selectedID: UUID? { draft?.profile.id }
    var saved: BrowserProfile? { profiles.first { $0.id == selectedID } }
    var automation: AutomationHost? { coordinator?.automation }

    /// Whether the draft holds edits: a saved Profile's against what the store holds, a new one's
    /// against the draft as generated, which by itself is no edit.
    var hasChanges: Bool {
        guard let draft else { return false }
        guard let origin = draftOrigin, origin.id == draft.profile.id else {
            return saved.map(ProfileDraft.init) != draft
        }
        return origin.hasChanges(draft, saved: saved)
    }

    var isNewDraft: Bool { draft != nil && saved == nil }

    private func resetDraftOrigin() {
        externalChange = nil
        guard let draft else {
            draftOrigin = nil
            return
        }
        draftOrigin = saved.map { DraftOrigin(saved: $0) } ?? DraftOrigin(new: draft)
    }

    // MARK: Revert and changes saved elsewhere

    /// Puts the saved configuration back into the editor; a new Profile is cancelled instead.
    func revertDraft() {
        guard let saved else { return requestCancelNew() }
        draft = ProfileDraft(saved)
        draftOrigin = DraftOrigin(saved: saved)
        externalChange = nil
        notice = Notice(text: "已还原为保存的配置。")
    }

    /// Asks first when the new Profile holds edits.
    func requestCancelNew() {
        guard isNewDraft else { return }
        if hasChanges {
            pendingCancelNew = true
        } else {
            cancelNewDraft()
        }
    }

    /// Drops the new Profile and goes back to the one selected before.
    func cancelNewDraft() {
        pendingCancelNew = false
        guard isNewDraft else { return }
        let back = selectionBeforeNew.flatMap { id in profiles.first { $0.id == id } } ?? profiles.first
        draft = back.map(ProfileDraft.init)
        notice = nil
    }

    /// Keeps the editor in step when the selected Profile is saved elsewhere: by the automation
    /// API, a batch action or a restore. Without edits the editor shows the new configuration;
    /// with edits that do not already show the change, the user decides (`externalChange`).
    private func followSavedChanges() {
        guard let draft, let origin = draftOrigin, origin.id == draft.profile.id, origin.isSaved else { return }
        guard let saved else {
            // Moved to the recycle bin or removed, here or through the automation API. A removal
            // here that picked another Profile itself never gets this far.
            let edited = origin.hasChanges(draft, saved: nil)
            let name = origin.draft.profile.name
            self.draft = profiles.first.map(ProfileDraft.init)
            notice = Notice(text: edited ? "「\(name)」已被移除，未保存的修改已丢弃。" : "「\(name)」已被移除。",
                            isError: edited)
            return
        }
        switch origin.sync(draft, with: saved) {
        case .unchanged:
            break
        case .refreshed(let next), .absorbed(let next):
            if next != draft { self.draft = next }
            draftOrigin = DraftOrigin(saved: saved)
            externalChange = nil
        case .conflict(_, let unseen):
            externalChange = ExternalChange(id: saved.id, fields: unseen)
        }
    }

    /// "载入外部修改" replaces the draft with the saved Profile; "保留我的修改" keeps the edits on
    /// top of it, taking the changes made elsewhere in the fields the draft did not edit.
    func resolveExternalChange(loadingExternal: Bool) {
        defer { externalChange = nil }
        guard let draft, let origin = draftOrigin, let saved else { return }
        self.draft = loadingExternal ? ProfileDraft(saved) : draft.rebased(from: origin.draft, onto: saved).merged
        draftOrigin = DraftOrigin(saved: saved)
        if loadingExternal { notice = Notice(text: "已载入外部修改。") }
    }

    func state(for id: UUID) -> BrowserRunState {
        coordinator?.state(for: id) ?? .stopped
    }

    func isBusy(_ id: UUID) -> Bool {
        coordinator?.isBusy(id) ?? false
    }

    func isRegenerating(_ id: UUID) -> Bool {
        coordinator?.regenerating.contains(id) ?? false
    }

    func hasPendingRestart(_ id: UUID) -> Bool {
        coordinator?.hasPendingRestart(id) ?? false
    }

    func request(_ destination: Destination) {
        if case .profile(let id) = destination, id == selectedID { return }
        if hasChanges {
            pendingDestination = destination
        } else {
            navigate(destination)
        }
    }

    func resolveNavigation(_ destination: Destination, saveChanges: Bool) {
        pendingDestination = nil
        if saveChanges, !save() { return }
        navigate(destination)
    }

    /// Saves the draft. A new identity is saved together with the mark that its old site data must
    /// go: a stopped Profile's is deleted right away, unless `clearingSiteData` is false because a
    /// launch follows and deletes it before the browser starts; a running one's at the restart.
    @discardableResult
    func save(clearingSiteData: Bool = true) -> Bool {
        // Saving over a change made elsewhere keeps the edits and what they did not touch.
        if externalChange != nil { resolveExternalChange(loadingExternal: false) }
        guard let draft, let store else { return false }
        do {
            let value = try draft.validated()
            if draft.resetsSiteData {
                guard let coordinator else { throw ProfileError.invalid("内置浏览器不可用，无法清除旧网站数据。") }
                try coordinator.saveNewIdentity(value)
            } else {
                try store.save(value)
            }
            let stored = store.profiles.first(where: { $0.id == value.id }) ?? value
            self.draft = ProfileDraft(stored)
            draftOrigin = DraftOrigin(saved: stored)
            extensionShelf.check(stored)
            if !draft.resetsSiteData {
                notice = Notice(text: hasPendingRestart(value.id) ? "配置已保存，重启后应用。" : "配置已保存。")
            } else if state(for: value.id).isRunning {
                notice = Notice(text: "新身份已保存。重启浏览器时先清除此 Profile 的网站数据，再使用新身份。")
            } else if clearingSiteData {
                clearOldSiteData(value.id)
            }
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func clearOldSiteData(_ id: UUID) {
        guard let coordinator else { return }
        notice = Notice(text: "新身份已保存，正在清除旧网站数据…")
        Task {
            do {
                try await coordinator.clearPendingSiteData(id)
                notice = Notice(text: "新身份已保存，旧网站数据已清除。")
            } catch {
                notice = Notice(text: "新身份已保存，但旧网站数据未能清除：\(error.localizedDescription)下次启动前会再清除。",
                                isError: true)
            }
        }
    }

    /// Removes only the record; used when the built-in engine is unavailable.
    func remove(_ id: UUID) {
        guard let store, !isBusy(id), !state(for: id).isRunning else { return }
        do {
            try store.remove(id)
            if selectedID == id { draft = store.profiles.first.map(ProfileDraft.init) }
            notice = Notice(text: "已移除 Profile。")
        } catch {
            show(error)
        }
    }

    /// Puts a whole new device identity into the editor. Nothing is deleted or saved here: saving
    /// deletes the old identity's site data (FingerprintCard asks first), discarding keeps it all.
    func regenerateIdentity() async {
        guard let draft, let coordinator else { return }
        let id = draft.profile.id
        let isSaved = saved != nil
        notice = Notice(text: "正在检测代理出口并生成新身份…")
        do {
            let identity = try await coordinator.generateIdentity(for: draft.profile)
            // The user may have moved to another Profile while the exit lookup ran.
            guard var current = self.draft, current.profile.id == id else { return }
            current.profile = identity.profile
            current.seedText = String(identity.profile.fingerprint.seed)
            current.cpuText = identity.profile.fingerprint.cpuCount.map(String.init) ?? ""
            // A Profile that was never saved has no site data.
            if isSaved { current.resetsSiteData = true }
            self.draft = current
            let warning = identity.exitLookupFailed ? "代理出口检测失败，语言/时区保持随机。" : ""
            if isSaved {
                let action = state(for: id).isRunning ? "点击「保存并重启」后" : "保存后"
                notice = Notice(text: "已生成新身份。\(action)清除此 Profile 的网站数据并使用新身份；放弃修改则不删除任何数据。\(warning)")
            } else {
                notice = Notice(text: "已生成新身份。\(warning)")
            }
        } catch {
            show(error)
        }
    }

    /// A new Profile starts with a random locale; align it with the proxy exit as soon as
    /// the lookup returns, without overwriting edits the user made in the meantime.
    private func alignNewProfileWithProxy() {
        guard let draft else { return }
        let id = draft.profile.id
        let proxy = draft.profile.proxy
        let trimmed = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let hint = IdentitySampler.LocaleHint.host { apply(hint, to: id, proxy: proxy) }
            return
        }
        Task { @MainActor in
            guard let exit = await self.proxyCenter.lookup(trimmed) else {
                if self.draft?.profile.id == id {
                    self.notice = Notice(text: "代理出口检测失败，语言/时区保持随机；可稍后点「检测」重新对齐。")
                }
                return
            }
            guard let hint = IdentitySampler.LocaleHint(exit: exit) else { return }
            self.apply(hint, to: id, proxy: proxy, country: exit.countryCode)
        }
    }

    private func apply(_ hint: IdentitySampler.LocaleHint, to id: UUID, proxy: String, country: String? = nil) {
        guard var current = draft, current.profile.id == id,
              current.profile.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
                == proxy.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        current.profile.fingerprint.apply(hint)
        self.draft = current
        // Filled in for a Profile being created: not an edit of the user's.
        if var origin = draftOrigin, !origin.isSaved, origin.id == id {
            origin.draft.profile.fingerprint.apply(hint)
            draftOrigin = origin
        }
        if let country, !country.isEmpty {
            notice = Notice(text: "已按代理出口（\(country)）填写语言/时区。")
        }
    }

    func randomize(_ fields: Set<FingerprintField>) -> Bool {
        guard var draft, let store else { return false }
        do {
            var profile = draft.profile
            if let seed = Int(draft.seedText.trimmingCharacters(in: .whitespaces)) {
                profile.fingerprint.seed = seed
            }
            profile.fingerprint = try store.randomize(profile, fields: fields).fingerprint
            draft.profile = profile
            if fields.contains(.seed) { draft.seedText = String(profile.fingerprint.seed) }
            if fields.contains(.cpuCount) {
                draft.cpuText = profile.fingerprint.cpuCount.map(String.init) ?? ""
            }
            self.draft = draft
            notice = Notice(text: "已生成预览，保存后应用。")
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// Saves pending edits, then starts or restarts the selected Profile. When its seed or platform
    /// changed since the last launch without a new identity, the user first decides what happens
    /// to the old site data (`pendingFingerprintLaunch`).
    func launch(restart: Bool = false) async {
        guard let coordinator, let id = selectedID, !isBusy(id) else { return }
        // The launch deletes a new identity's old site data itself, before the browser starts.
        if hasChanges, !save(clearingSiteData: false) { return }
        guard let profile = saved else { return }
        if coordinator.fingerprintChangedSinceLastLaunch(id) {
            pendingFingerprintLaunch = FingerprintLaunch(id: id, name: profile.name, restart: restart)
            return
        }
        await launch(id, restart: restart, fingerprintChange: .keepSiteData)
    }

    func resolveFingerprintLaunch(_ pending: FingerprintLaunch, clearingSiteData: Bool) async {
        pendingFingerprintLaunch = nil
        await launch(pending.id, restart: pending.restart,
                     fingerprintChange: clearingSiteData ? .clearSiteData : .keepSiteData)
    }

    private func launch(_ id: UUID, restart: Bool, fingerprintChange: FingerprintChangeHandling) async {
        guard let coordinator else { return }
        notice = nil
        stopTimeouts[id] = nil
        let earlierLog = coordinator.launchLog(for: id)
        do {
            let outcome = restart
                ? try await coordinator.restart(id, fingerprintChange: fingerprintChange)
                : try await coordinator.start(id, fingerprintChange: fingerprintChange)
            if !outcome.warnings.isEmpty {
                notice = Notice(text: outcome.warnings.joined(separator: "\n"), isError: true)
            }
        } catch {
            // A launch refused before the browser started leaves the previous launch's log in place.
            let log = coordinator.launchLog(for: id)
            notice = Notice(text: error.localizedDescription, isError: true,
                            action: log == nil || log == earlierLog ? nil : .showLaunchLog(id))
        }
        if let profile = profiles.first(where: { $0.id == id }) { extensionShelf.check(profile) }
    }

    /// Warnings that arrived after the launch went ahead, such as an exit lookup that took longer.
    private func showLate(_ warnings: [String], for id: UUID) {
        guard let name = profiles.first(where: { $0.id == id })?.name else { return }
        notice = Notice(text: "「\(name)」：" + warnings.joined(separator: "\n"), isError: true)
    }

    /// `force` kills a browser that did not quit within the timeout. A browser still there after
    /// a stop failed can be force-stopped from then on.
    func stop(_ id: UUID, force: Bool = false) async {
        guard let coordinator, !isBusy(id) else { return }
        notice = nil
        let pid = runningPID(id)
        do {
            try await coordinator.stop(id, force: force)
            stopTimeouts[id] = nil
        } catch {
            guard !force, let pid, runningPID(id) == pid else { return show(error) }
            stopTimeouts[id] = pid
            notice = Notice(text: error.localizedDescription + "浏览器没有响应时，可以点击「强制停止」。", isError: true)
        }
    }

    /// Whether the running browser already failed to stop when asked.
    func canForceStop(_ id: UUID) -> Bool {
        guard let pid = runningPID(id) else { return false }
        return stopTimeouts[id] == pid
    }

    private func runningPID(_ id: UUID) -> Int32? {
        if case .running(let pid, _, _) = state(for: id) { return pid }
        return nil
    }

    func showLaunchLog(_ id: UUID) {
        launchLog = ProfileSheet(id: id)
    }

    /// The browser output of the Profile's latest launch from this AnyBrowser.
    func launchLogText(_ id: UUID) -> String? {
        coordinator?.launchLog(for: id)
    }

    // MARK: Self-check

    /// Runs the self-check in the Profile's browser and shows the report in a sheet.
    func runSelfCheck(_ id: UUID) async {
        guard let coordinator, let profile = profiles.first(where: { $0.id == id }), state(for: id).isRunning else { return }
        selfCheck = SelfCheckRun(id: id, name: profile.name, phase: .running, pendingRestart: hasPendingRestart(id))
        let phase: SelfCheckRun.Phase
        if let endpoint = await coordinator.devToolsEndpoint(for: id) {
            do {
                phase = .finished(try await SelfCheck.run(endpoint: endpoint, profile: profile,
                                                          exit: coordinator.lastExit(for: id)?.exit))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        } else {
            phase = .failed("浏览器调试端口尚未就绪，请稍后重试。")
        }
        // Closed meanwhile, or another check started.
        guard selfCheck?.id == id, case .running = selfCheck?.phase else { return }
        selfCheck?.phase = phase
    }

    // MARK: Consistency

    /// The facts about other Profiles and the engine the consistency hints use.
    func consistencyContext(for id: UUID) -> ConsistencyContext {
        var context = coordinator?.consistencyContext(for: id) ?? ConsistencyContext()
        context.engineMajorsBehindStable = engineMajorsBehind
        return context
    }

    /// How far the bundled engine is behind Chrome stable for Mac, once VersionHistory answered.
    var engineMajorsBehind: Int? {
        engineFreshness.majorsBehind(engine: engineMajor)
    }

    var engineMajor: Int {
        engineVersion.flatMap { $0.split(separator: ".").first.flatMap { Int($0) } } ?? BundledVersions.engineMajor
    }

    /// The exit the draft's proxy leads to: checked in the editor, or else recorded for the saved
    /// Profile while the draft keeps its proxy.
    func knownExit(for draft: ProfileDraft) -> ProxyExit? {
        let profile = draft.profile
        if let exit = proxyCenter.exit(for: profile.id, proxy: profile.proxySpec) { return exit }
        guard let saved = profiles.first(where: { $0.id == profile.id }),
              Self.sameProxy(saved.proxySpec, profile.proxySpec) else { return nil }
        return coordinator?.lastExit(for: profile.id)?.exit
    }

    static func sameProxy(_ one: String, _ other: String) -> Bool {
        one.trimmingCharacters(in: .whitespacesAndNewlines) == other.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Brings the Profile's browser windows to the front.
    func showWindows(_ id: UUID) {
        guard coordinator?.activate(id) == true else {
            notice = Notice(text: state(for: id).isRunning
                ? "macOS 没有把此 Profile 的浏览器窗口切到前面，可以在程序坞或 ⌘-Tab 中切换。"
                : "此 Profile 没有在运行。", isError: true)
            return
        }
    }

    var passkeyBoxAccount: PasskeyBoxAccount? { store?.passkeyBoxAccount }

    /// Verifies the account with the server, then saves it. Returns an error message on failure.
    func savePasskeyBox(_ account: PasskeyBoxAccount) async -> String? {
        guard let store else { return Self.storeUnavailable }
        do {
            let value = try account.validated()
            try await value.verify()
            // Cancelled from the sheet while the server answered: nothing is saved.
            try Task.checkCancellation()
            try store.savePasskeyBoxAccount(value)
            notice = Notice(text: profiles.contains { state(for: $0.id).isRunning }
                ? "Passkey Box 账号已保存，正在运行的 Profile 重启后生效。"
                : "Passkey Box 账号已保存，启动 Profile 后自动登录。")
            return nil
        } catch {
            return Task.isCancelled ? nil : error.localizedDescription
        }
    }

    func clearPasskeyBox() -> String? {
        do {
            try store?.savePasskeyBoxAccount(nil)
            notice = Notice(text: "已移除 Passkey Box 账号。之后新建的 Profile 不再自动登录；已登录过的 Profile 仍保留扩展里的账号，需要时在扩展里退出。")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func copyAddress(_ port: Int) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString("http://127.0.0.1:\(port)", forType: .string) {
            notice = Notice(text: "调试地址已复制。")
        }
    }

    private func navigate(_ destination: Destination) {
        notice = nil
        do {
            switch destination {
            case .new:
                if saved != nil { selectionBeforeNew = selectedID }
                draft = try store.map { try ProfileDraft($0.makeDraft()) }
                alignNewProfileWithProxy()
            case .profile(let id):
                draft = profiles.first { $0.id == id }.map(ProfileDraft.init)
            case .clone:
                cloneSaved()
            }
        } catch {
            show(error)
        }
    }

    func show(_ error: Error) {
        notice = Notice(text: error.localizedDescription, isError: true)
    }
}
