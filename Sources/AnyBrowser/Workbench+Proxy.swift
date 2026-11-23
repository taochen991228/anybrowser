import AnyBrowserCore
import Combine
import Foundation

/// Proxy reachability and exit information per Profile.
@MainActor
final class ProxyCenter: ObservableObject {
    enum Check: Equatable {
        case checking
        case succeeded(ProxyExit)
        case failed(String)
    }

    /// The latest check of each Profile, with the proxy address it was made through.
    @Published private(set) var checks: [UUID: (proxy: String, check: Check)] = [:]

    /// The latest successful exit lookup made through `proxy`, if any.
    func exit(for id: UUID, proxy: String) -> ProxyExit? {
        if case .succeeded(let exit) = check(for: id, proxy: proxy) { return exit }
        return nil
    }

    /// The check made through `proxy`, ignoring one made through an address since edited.
    func check(for id: UUID, proxy: String) -> Check? {
        guard let entry = checks[id], entry.proxy == Self.normalized(proxy) else { return nil }
        return entry.check
    }

    /// Drops a result that no longer describes the Profile's proxy address.
    func proxyChanged(_ id: UUID, to proxy: String) {
        if let entry = checks[id], entry.proxy != Self.normalized(proxy) { checks[id] = nil }
    }

    /// Looks up an exit without recording it against a Profile, for a Profile being created.
    func lookup(_ proxy: String) async -> ProxyExit? {
        let proxy = Self.normalized(proxy)
        guard !proxy.isEmpty, let chain = try? ProxyChain.parse(spec: proxy) else { return nil }
        return try? await ProxyProbe.lookupExit(through: chain)
    }

    /// Looks up where the Profile's traffic leaves, through the proxy (or chain) it is given (saved or not).
    @discardableResult
    func check(_ profile: BrowserProfile) async -> ProxyExit? {
        let spec = Self.normalized(profile.proxySpec)
        let id = profile.id
        guard checks[id]?.check != .checking else { return nil }
        checks[id] = (spec, .checking)
        let result: Check
        do {
            let chain = try profile.proxyChain()
            result = .succeeded(try await ProxyProbe.lookupExit(through: chain))
        } catch {
            result = .failed(error.localizedDescription)
        }
        // A newer address replaced this one while the lookup ran.
        guard checks[id]?.proxy == spec else { return nil }
        checks[id] = (spec, result)
        if case .succeeded(let exit) = result { return exit }
        return nil
    }

    private static func normalized(_ proxy: String) -> String {
        proxy.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
