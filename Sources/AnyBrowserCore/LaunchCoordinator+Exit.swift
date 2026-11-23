import Foundation

// Before a launch the Profile's proxy exit is compared with its fingerprint: time zone and language
// against where the exit is, and whether other Profiles leave through the same IP. An exit recorded
// through the same proxy up to `exitReviewAge` ago is used as it is; otherwise the exit is looked up
// beside the launch, which never waits for it or fails because of it.
extension LaunchCoordinator {
    /// The facts about other Profiles the editor's consistency hints need for this Profile.
    public func consistencyContext(for id: UUID) -> ConsistencyContext {
        ConsistencyContext(profilesSharingExit: proxyLibrary.profilesSharingExit(with: id).compactMap { profile($0)?.name })
    }

    /// The exit last seen for the Profile through its present proxy and when, kept across launches
    /// of AnyBrowser.
    public func lastExit(for id: UUID) -> (exit: ProxyExit, checkedAt: Date)? {
        proxyLibrary.lastExit(forProfile: id)
    }

    /// The exit warnings for a Profile leaving through `exit`.
    func exitWarnings(for id: UUID, exit: ProxyExit) -> [String] {
        guard let profile = profile(id) else { return [] }
        return profile.consistencyIssues(engineVersion: nil, exit: exit, context: consistencyContext(for: id))
            .filter { Self.exitIssues.contains($0.id) }
            .map { $0.message + "。" }
    }

    private static let exitIssues: Set<String> = ["time-zone", "language", "exit-shared"]

    /// Starts reviewing the exit for a launch of `profile`; nil without a proxy.
    func reviewExit(of profile: BrowserProfile) -> ExitReview? {
        guard let chain = try? profile.proxyChain() else { return nil }
        let id = profile.id
        let spec = profile.proxySpec
        let review = ExitReview()
        if let record = proxyLibrary.lastExit(forProfile: id, proxy: spec), Date().timeIntervalSince(record.checkedAt) < exitReviewAge {
            review.finish(exitWarnings(for: id, exit: record.exit))
            return review
        }
        let key = chain.key
        let lookup = exitLookups[key] ?? Task { [exitLookup] in await exitLookup(spec) }
        exitLookups[key] = lookup
        Task {
            let exit = await lookup.value
            if self.exitLookups[key] == lookup { self.exitLookups[key] = nil }
            // A failed lookup says nothing about the exit.
            guard let exit else { return review.finish([]) }
            try? self.proxyLibrary.recordExit(exit, forProfile: id, proxy: spec)
            review.finish(self.exitWarnings(for: id, exit: exit))
        }
        return review
    }
}

/// The exit warnings of one launch, as they become known.
@MainActor
final class ExitReview {
    private var warnings: [String]?
    private var late: (([String]) -> Void)?
    private var discarded = false

    func finish(_ found: [String]) {
        warnings = found
        if !found.isEmpty, !discarded { late?(found) }
        late = nil
    }

    /// The warnings known now. Ones found later go to `later`.
    func warningsSoFar(later: @escaping ([String]) -> Void) -> [String] {
        if let warnings { return warnings }
        late = later
        return []
    }

    /// For a launch that failed or found its browser running: nothing is reported.
    func discard() {
        discarded = true
        late = nil
    }
}
