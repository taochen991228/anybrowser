import Foundation

// "整套重新生成": a new identity goes into the editor first and deletes nothing. Saving it records
// that the old identity's site data must go; that mark stays in the database until the data is
// gone, whether right away (stopped), at the restart (running) or at the next launch after
// AnyBrowser quit. A running browser is never cleared over DevTools: its open pages would write
// the old identity back before the restart.
extension LaunchCoordinator {
    /// A new identity for `profile` (saved or not), with language and time zone from its proxy's
    /// exit, or from this Mac without a proxy. Nothing is saved or deleted. The Profile counts as
    /// busy meanwhile, so the editor and launches wait for the exit lookup.
    public func generateIdentity(for profile: BrowserProfile) async throws -> (profile: BrowserProfile, exitLookupFailed: Bool) {
        let id = profile.id
        guard !isBusy(id) else { throw ProfileError.invalid("「\(profile.name)」正在执行另一个操作。") }
        regenerating.insert(id)
        defer { regenerating.remove(id) }
        let proxy = profile.proxySpec
        var locale: IdentitySampler.LocaleHint?
        var lookupFailed = false
        if proxy.isEmpty {
            locale = .host
        } else if let exit = await exitLookup(proxy) {
            locale = IdentitySampler.LocaleHint(exit: exit)
        } else {
            lookupFailed = true
        }
        return (try store.regenerateIdentity(profile, locale: locale), lookupFailed)
    }

    /// Saves `profile` with the identity `generateIdentity` gave it and marks the old identity's
    /// site data for deletion. The Profile is saved first: should the mark fail to save, its next
    /// launch still asks what to do with the old data, because the seed changed.
    public func saveNewIdentity(_ profile: BrowserProfile) throws {
        guard !isBusy(profile.id) else { throw ProfileError.invalid("「\(profile.name)」正在执行另一个操作。") }
        var value = profile
        // The identity reset clears the stored session, so restoring it would bring back nothing.
        value.launch.restoreSession = false
        try store.save(value)
        do {
            try store.setPendingIdentityReset(profile.id, true)
        } catch {
            throw ProfileError.invalid("新身份已保存，但未能记下要清除的旧网站数据（\(error.localizedDescription)）。")
        }
    }

    /// Deletes the site data a pending identity reset is waiting for, then clears the mark, while
    /// the Profile's browser is stopped. Returns false without deleting anything when it runs: the
    /// restart clears it. When the deletion fails the mark stays, and the next launch tries again.
    @discardableResult
    public func clearPendingSiteData(_ id: UUID) async throws -> Bool {
        guard store.pendingIdentityReset(id) else { return true }
        guard !isBusy(id) else { throw ProfileError.invalid("该 Profile 正在执行另一个操作。") }
        switch runtime.status(for: id) {
        case .running, .starting, .stopping:
            return false
        case .stopped, .failed:
            break
        }
        regenerating.insert(id)
        defer { regenerating.remove(id) }
        // Checked just above with nothing in between, so this is the on-disk clearing.
        try await runtime.clearSiteData(for: id)
        try store.setPendingIdentityReset(id, false)
        // The site data now belongs to the new fingerprint, so its next launch has nothing to ask.
        if let fingerprint = store.profiles.first(where: { $0.id == id })?.fingerprint {
            store.recordLaunchFingerprint(id, fingerprint)
        }
        return true
    }
}
