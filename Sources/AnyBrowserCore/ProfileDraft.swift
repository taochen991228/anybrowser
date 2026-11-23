import Foundation

/// A Profile as the editor holds it. The port, seed and CPU count stay as typed until saving
/// checks them, so a half-typed number is never lost or silently corrected.
public struct ProfileDraft: Equatable, Sendable {
    public var profile: BrowserProfile
    public var portText: String
    public var seedText: String
    public var cpuText: String
    /// Set by "整套重新生成": saving deletes the old identity's site data. Discarding the draft
    /// discards this too, and nothing is deleted.
    public var resetsSiteData = false

    public init(_ profile: BrowserProfile) {
        self.profile = profile
        portText = String(profile.port)
        seedText = String(profile.fingerprint.seed)
        cpuText = profile.fingerprint.cpuCount.map(String.init) ?? ""
    }

    public func validated() throws -> BrowserProfile {
        var value = profile
        value.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.platformVersion = value.fingerprint.platformVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.brandVersion = value.fingerprint.brandVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.language = value.fingerprint.language.trimmingCharacters(in: .whitespacesAndNewlines)
        value.fingerprint.timeZone = value.fingerprint.timeZone.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.name.isEmpty else { throw ProfileError.invalid("请输入 Profile 名称。") }
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else {
            throw ProfileError.invalid("调试端口必须为 1024–65535 之间的整数。")
        }
        guard let seed = Int(seedText.trimmingCharacters(in: .whitespaces)), (1...Int(Int32.max)).contains(seed) else {
            throw ProfileError.invalid("指纹种子必须为 1–2147483647 之间的整数。")
        }
        value.port = port
        value.fingerprint.seed = seed
        value.fingerprint.followSeed()
        let cpu = cpuText.trimmingCharacters(in: .whitespaces)
        if cpu.isEmpty {
            value.fingerprint.cpuCount = nil
        } else {
            guard let count = Int(cpu), (1...256).contains(count) else {
                throw ProfileError.invalid("逻辑 CPU 数必须为 1–256 之间的整数。")
            }
            value.fingerprint.cpuCount = count
        }
        return value
    }

    /// The seed as typed, when it is a valid one; the saved seed otherwise.
    public var effectiveSeed: Int {
        guard let seed = Int(seedText.trimmingCharacters(in: .whitespaces)), (1...Int(Int32.max)).contains(seed) else {
            return profile.fingerprint.seed
        }
        return seed
    }

    /// The Profile with the typed seed and CPU count, where they are valid, so that hints and the
    /// summary follow typing instead of waiting for a save.
    public var preview: BrowserProfile {
        var value = profile
        value.fingerprint.seed = effectiveSeed
        value.fingerprint.followSeed()
        let cpu = cpuText.trimmingCharacters(in: .whitespaces)
        if cpu.isEmpty {
            value.fingerprint.cpuCount = nil
        } else if let count = Int(cpu), (1...256).contains(count) {
            value.fingerprint.cpuCount = count
        }
        return value
    }
}

extension FingerprintSettings {
    /// A recorded memory value follows the seed, as the engine reports it.
    fileprivate mutating func followSeed() {
        if deviceMemory != nil { deviceMemory = EngineHardwareTable.bundled.deviceMemory(seed: seed) }
    }
}

// MARK: Edits against changes made elsewhere

extension ProfileDraft {
    /// The parts of a Profile that are edited, and changed elsewhere (the automation API, batch
    /// actions), independently of each other.
    public enum Field: String, CaseIterable, Sendable {
        case name, port, fingerprint, proxy, group, notes, passkeyBox, launch, tags, accountStatus

        public var title: String {
            switch self {
            case .name: return "名称"
            case .port: return "调试端口"
            case .fingerprint: return "指纹"
            case .proxy: return "代理"
            case .group: return "分组"
            case .notes: return "备注"
            case .passkeyBox: return "Passkey Box 账号"
            case .launch: return "启动选项"
            case .tags: return "标签"
            case .accountStatus: return "账号状态"
            }
        }
    }

    /// The fields in which this draft and `other` differ, as the editor shows them.
    public func changedFields(from other: ProfileDraft) -> Set<Field> {
        Set(Field.allCases.filter { !agrees(with: other, in: $0) })
    }

    private func agrees(with other: ProfileDraft, in field: Field) -> Bool {
        switch field {
        case .name: return profile.name == other.profile.name
        // The editor edits the text; `profile.port` is what the draft started from.
        case .port: return portText == other.portText
        case .fingerprint:
            return profile.fingerprint == other.profile.fingerprint && seedText == other.seedText
                && cpuText == other.cpuText && resetsSiteData == other.resetsSiteData
                && profile.deviceIdentity == other.profile.deviceIdentity
        case .proxy: return profile.proxy == other.profile.proxy && profile.transitProxy == other.profile.transitProxy
        case .group: return profile.group == other.profile.group
        case .notes: return profile.notes == other.profile.notes
        case .passkeyBox: return profile.passkeyBox == other.profile.passkeyBox
        case .launch: return profile.launch == other.profile.launch
        case .tags: return profile.tags == other.profile.tags
        case .accountStatus: return profile.accountStatus == other.profile.accountStatus
        }
    }

    private mutating func take(_ field: Field, from other: ProfileDraft) {
        switch field {
        case .name: profile.name = other.profile.name
        case .port: portText = other.portText
        case .fingerprint:
            profile.fingerprint = other.profile.fingerprint
            profile.deviceIdentity = other.profile.deviceIdentity
            seedText = other.seedText
            cpuText = other.cpuText
            resetsSiteData = other.resetsSiteData
        case .proxy:
            profile.proxy = other.profile.proxy
            profile.transitProxy = other.profile.transitProxy
        case .group: profile.group = other.profile.group
        case .notes: profile.notes = other.profile.notes
        case .passkeyBox: profile.passkeyBox = other.profile.passkeyBox
        case .launch: profile.launch = other.profile.launch
        case .tags: profile.tags = other.profile.tags
        case .accountStatus: profile.accountStatus = other.profile.accountStatus
        }
    }

    /// This draft, which started from `origin`, moved onto `incoming`, the Profile as saved now:
    /// the fields edited since `origin` keep their edits, the others take `incoming`'s values.
    public func rebased(from origin: ProfileDraft, onto incoming: BrowserProfile) -> DraftRebase {
        let target = ProfileDraft(incoming)
        let edited = changedFields(from: origin)
        let elsewhere = origin.changedFields(from: target)
        var merged = target
        for field in edited { merged.take(field, from: self) }
        return DraftRebase(merged: merged, edited: edited, changedElsewhere: elsewhere,
                           unseen: elsewhere.intersection(changedFields(from: target)))
    }
}

/// A draft moved onto the Profile as it is saved now.
public struct DraftRebase: Equatable, Sendable {
    /// The saved Profile with the draft's edits on top.
    public var merged: ProfileDraft
    /// Fields edited in the draft.
    public var edited: Set<ProfileDraft.Field>
    /// Fields saved with other values since the draft started.
    public var changedElsewhere: Set<ProfileDraft.Field>
    /// Fields changed elsewhere whose saved value the draft does not show: ones it did not edit,
    /// and ones it edited to something else.
    public var unseen: Set<ProfileDraft.Field>
}

/// What the draft in the editor started from: a saved Profile as loaded, or a new Profile as
/// generated. Edits are told apart from changes saved elsewhere by comparing with it.
public struct DraftOrigin: Equatable, Sendable {
    public var draft: ProfileDraft
    /// False for a Profile that has never been saved.
    public var isSaved: Bool

    public init(new draft: ProfileDraft) {
        self.draft = draft
        isSaved = false
    }

    public init(saved profile: BrowserProfile) {
        draft = ProfileDraft(profile)
        isSaved = true
    }

    public var id: UUID { draft.profile.id }

    /// Whether `draft` holds edits: compared with the store's copy of a saved Profile, or with
    /// the generated draft for a new one, which is not an edit until the user changes it.
    public func hasChanges(_ draft: ProfileDraft, saved: BrowserProfile?) -> Bool {
        if let saved { return ProfileDraft(saved) != draft }
        return draft != self.draft
    }

    /// How the draft follows `saved`, the Profile as now stored, when that changed elsewhere.
    public func sync(_ draft: ProfileDraft, with saved: BrowserProfile) -> DraftSync {
        let rebase = draft.rebased(from: self.draft, onto: saved)
        if rebase.changedElsewhere.isEmpty { return .unchanged }
        if rebase.edited.isEmpty { return .refreshed(rebase.merged) }
        // Edits plus changes the draft already shows, such as a group set from the batch bar.
        if rebase.unseen.isEmpty { return .absorbed(rebase.merged) }
        return .conflict(keepingEdits: rebase.merged, unseen: rebase.unseen)
    }
}

/// What to do with the draft after the Profile it edits was saved elsewhere. Every case except
/// `unchanged` moves the origin to the saved Profile once applied.
public enum DraftSync: Equatable, Sendable {
    /// Nothing the draft started from was changed.
    case unchanged
    /// The draft had no edits: it becomes the saved Profile.
    case refreshed(ProfileDraft)
    /// The draft's edits already include every change made elsewhere.
    case absorbed(ProfileDraft)
    /// The draft has edits, and changes made elsewhere it does not show: the user decides.
    /// `keepingEdits` is the saved Profile with the draft's edits on top.
    case conflict(keepingEdits: ProfileDraft, unseen: Set<ProfileDraft.Field>)
}
