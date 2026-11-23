import CoreFoundation
import Foundation

// The routes of the automation API under /api/v1. A handler returns its answer or throws a
// `Failure` holding it; any other error answers 500 with its message.
extension AutomationHTTP {
    /// An answer other than success.
    struct Failure: Error {
        var response: Response

        init(_ status: Int, _ code: String, _ message: String, headers: [String] = []) {
            response = .error(status, code, message, headers: headers)
        }

        init(_ response: Response) {
            self.response = response
        }

        static func invalid(_ message: String) -> Failure { Failure(400, "invalid", message) }
    }

    static let notFound = Response.error(404, "not_found", "没有这个接口或 Profile。")
    static let busy = Response.error(409, "busy", "该 Profile 正在执行另一个操作，请稍后重试。")
    static let notJSON = Response.error(400, "invalid_json", "请求体须为 JSON 对象。")

    /// A request taken apart: the path below /api/v1, the query and the body.
    struct Call {
        var method: String
        /// Segments after /api/v1, e.g. ["profiles", "<id>", "start"].
        var path: [String]
        var query: [(name: String, value: String)]
        var body: Data

        init?(_ request: Request) {
            let parts = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let segments = parts[0].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard segments.count >= 4, segments[0].isEmpty, segments[1] == "api", segments[2] == "v1" else { return nil }
            method = request.method
            path = Array(segments.dropFirst(3))
            body = request.body
            // "+" stays a plus sign: tags and names may contain one, and clients encode spaces as %20.
            query = parts.count < 2 ? [] : parts[1].split(separator: "&").map { pair in
                let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let decode = { (text: Substring) in text.removingPercentEncoding ?? String(text) }
                return (decode(field[0]), field.count == 2 ? decode(field[1]) : "")
            }
        }

        func values(_ name: String) -> [String] { query.filter { $0.name == name }.map(\.value) }

        func value(_ name: String) -> String? { values(name).last }

        /// A yes/no query parameter: absent, 0 or false is no; 1 or true is yes.
        func flag(_ name: String) throws -> Bool {
            guard let value = value(name) else { return false }
            switch value.lowercased() {
            case "1", "true": return true
            case "0", "false", "": return false
            default: throw Failure.invalid("参数 \(name) 须为 1 或 0。")
            }
        }

        func allow(_ methods: String...) throws {
            guard !methods.contains(method) else { return }
            throw Failure(405, "method_not_allowed", "此接口只支持 \(methods.joined(separator: "、"))。",
                          headers: ["Allow: \(methods.joined(separator: ", "))"])
        }

        /// The body as a JSON object; an empty body is an empty object.
        func object() throws -> [String: Any] {
            guard !body.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) else { return [:] }
            guard let value = try? JSONSerialization.jsonObject(with: body), let object = value as? [String: Any] else {
                throw Failure(AutomationHTTP.notJSON)
            }
            return object
        }
    }

    // MARK: Field reads

    // JSON null reads as an absent field. Booleans are NSNumbers too, so types are checked through
    // CoreFoundation rather than with `as?`, which would take 1 for true.

    private static func isBoolean(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    static func boolean(_ value: Any?, _ name: String) throws -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        guard isBoolean(value), let flag = value as? Bool else { throw Failure.invalid("字段 \(name) 须为 true 或 false。") }
        return flag
    }

    static func integer(_ value: Any?, _ name: String) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard !isBoolean(value), let number = value as? NSNumber, let integer = Int(exactly: number.doubleValue) else {
            throw Failure.invalid("字段 \(name) 须为整数。")
        }
        return integer
    }

    static func string(_ value: Any?, _ name: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw Failure.invalid("字段 \(name) 须为字符串。") }
        return text
    }

    static func strings(_ value: Any?, _ name: String) throws -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
            throw Failure.invalid("字段 \(name) 须为字符串数组。")
        }
        return list.compactMap { $0 as? String }
    }

    static func ids(_ value: Any?, _ name: String) throws -> [UUID]? {
        try strings(value, name)?.map { text in
            guard let id = UUID(uuidString: text) else { throw Failure.invalid("字段 \(name) 中的 \(text.prefix(40)) 不是 id。") }
            return id
        }
    }

    /// Refuses fields other than `keys`, so a misspelled option is not silently ignored.
    static func only(_ keys: Set<String>, in body: [String: Any]) throws {
        let unknown = body.keys.filter { !keys.contains($0) }.sorted()
        guard unknown.isEmpty else { throw Failure.invalid("无法识别的字段：\(unknown.joined(separator: "、"))") }
    }

    // MARK: Profile configurations

    /// `profile` with `patch` merged into its configuration (RFC 7386: objects merge, null removes a
    /// field, anything else replaces it). Fields this version does not know, or whose values it
    /// cannot read, are refused rather than dropped.
    static func merged(_ patch: [String: Any], into profile: BrowserProfile) throws -> BrowserProfile {
        guard !patch.isEmpty else { return profile }
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any] ?? [:]
        let document = mergePatch(current, patch) as? [String: Any] ?? [:]
        let value: BrowserProfile
        do {
            value = try JSONDecoder().decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: document))
        } catch let newer as NewerValue {
            throw Failure.invalid("无法识别的取值：\(newer.value.prefix(64))")
        } catch {
            throw Failure.invalid(ProfileStore.readFailure(error))
        }
        let known = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
        let unknown = unknownKeys(document, known: known)
        guard unknown.isEmpty else { throw Failure.invalid("无法识别的字段或取值：\(unknown.joined(separator: "、"))") }
        return value
    }

    static func mergePatch(_ target: Any?, _ patch: Any) -> Any {
        guard let patch = patch as? [String: Any] else { return patch }
        var result = target as? [String: Any] ?? [:]
        for (key, value) in patch {
            result[key] = value is NSNull ? nil : mergePatch(result[key], value)
        }
        return result
    }

    /// Dotted paths of the fields in `given` that `known` (the same document decoded and encoded
    /// again) lost.
    static func unknownKeys(_ given: [String: Any], known: [String: Any], prefix: String = "") -> [String] {
        given.keys.sorted().flatMap { key -> [String] in
            guard let kept = known[key] else { return [prefix + key] }
            guard let object = given[key] as? [String: Any], let keptObject = kept as? [String: Any] else { return [] }
            return unknownKeys(object, known: keptObject, prefix: prefix + key + ".")
        }
    }

    /// What GET returns as `config`: the whole configuration, without proxy credentials and the
    /// Profile's own Passkey Box account unless `secrets`.
    static func config(_ profile: BrowserProfile, secrets: Bool) -> BrowserProfile {
        secrets ? profile : ProfileLibrary.withoutSecrets(profile)
    }

    // MARK: Response objects

    struct ProfileObject: Encodable {
        var id: UUID
        var name: String
        var group: String
        var port: Int
        var status: String
        var debugReady: Bool
        var tags: [String]
        var accountStatus: AccountStatus?
        var pendingRestart: Bool
        /// Set for Profiles in the recycle bin.
        var deletedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id, name, group, port, status, debugReady, tags, accountStatus, pendingRestart, deletedAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(group, forKey: .group)
            try container.encode(port, forKey: .port)
            try container.encode(status, forKey: .status)
            try container.encode(debugReady, forKey: .debugReady)
            try container.encode(tags, forKey: .tags)
            // Written as null when unset, so every Profile has the same fields.
            try container.encode(accountStatus, forKey: .accountStatus)
            try container.encode(pendingRestart, forKey: .pendingRestart)
            try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        }
    }

    struct DebugAddress: Encodable {
        var http: String
        var webSocket: String
    }

    struct ProxyObject: Encodable {
        var id: UUID
        var url: String
        var hasCredentials: Bool
        var label: String
        var tags: [String]
        var note: String
        var createdAt: Date
        var lastExit: ProxyExit?
        var lastCheckedAt: Date?
        /// Profiles using this proxy, those in the recycle bin included.
        var profiles: [UUID]

        private enum CodingKeys: String, CodingKey {
            case id, url, hasCredentials, label, tags, note, createdAt, lastExit, lastCheckedAt, profiles
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encode(hasCredentials, forKey: .hasCredentials)
            try container.encode(label, forKey: .label)
            try container.encode(tags, forKey: .tags)
            try container.encode(note, forKey: .note)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(lastExit, forKey: .lastExit)
            try container.encode(lastCheckedAt, forKey: .lastCheckedAt)
            try container.encode(profiles, forKey: .profiles)
        }
    }

    struct WindowObject: Encodable {
        var id: UUID
        var frame: WindowArrangement.Frame?
        var error: String?

        private enum CodingKeys: String, CodingKey { case id, frame, error }
        private enum FrameKeys: String, CodingKey { case left, top, width, height }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            if let frame {
                var bounds = container.nestedContainer(keyedBy: FrameKeys.self, forKey: .frame)
                try bounds.encode(frame.left, forKey: .left)
                try bounds.encode(frame.top, forKey: .top)
                try bounds.encode(frame.width, forKey: .width)
                try bounds.encode(frame.height, forKey: .height)
            } else {
                try container.encodeNil(forKey: .frame)
            }
            try container.encode(error, forKey: .error)
        }
    }

    /// A JSON object of named values; nil values are written as null.
    struct Body: Encodable {
        private let fields: [(key: String, value: any Encodable)]

        init(_ fields: KeyValuePairs<String, any Encodable>) {
            self.fields = fields.map { ($0.key, $0.value) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for field in fields { try container.encode(field.value, forKey: Key(stringValue: field.key)) }
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// Any value read by JSONSerialization, to embed JSON produced elsewhere, such as a cookie export.
    enum JSONValue: Encodable {
        case null, bool(Bool), integer(Int64), number(Double), string(String)
        case array([JSONValue]), object([String: JSONValue])

        init(_ value: Any) {
            switch value {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                self = .bool(number.boolValue)
            case let number as NSNumber:
                self = CFNumberIsFloatType(number) ? .number(number.doubleValue) : .integer(number.int64Value)
            case let text as String:
                self = .string(text)
            case let list as [Any]:
                self = .array(list.map(JSONValue.init))
            case let object as [String: Any]:
                self = .object(object.mapValues(JSONValue.init))
            default:
                self = .null
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
}

@MainActor
extension AutomationHTTP {
    /// Profiles the API started without windows to move cookies and will stop again; other API
    /// calls treat them as busy meanwhile, so nobody is handed a browser about to close. By backend.
    private static var temporaryRuns: [ObjectIdentifier: Set<UUID>] = [:]

    static func isBusy(_ id: UUID, _ backend: AutomationBackend) -> Bool {
        backend.isBusy(id) || temporaryRuns[ObjectIdentifier(backend)]?.contains(id) == true
    }

    /// Creations waiting for the one in progress, by backend; an entry, even an empty one, means a
    /// creation is in progress. A creation picks its port, seed and unused proxy before the exit
    /// lookup awaits and holds them only once saved, so two at a time would pick the same ones.
    private static var creationQueues: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    /// Runs `body` once no other creation on `backend` is running, in the order the requests came.
    private static func oneCreationAtATime<Value>(_ backend: AutomationBackend,
                                                  _ body: () async throws -> Value) async throws -> Value {
        let key = ObjectIdentifier(backend)
        if creationQueues[key] == nil {
            creationQueues[key] = []
        } else {
            await withCheckedContinuation { creationQueues[key, default: []].append($0) }
        }
        defer {
            if let next = creationQueues[key]?.first {
                creationQueues[key]?.removeFirst()
                next.resume()
            } else {
                creationQueues[key] = nil
            }
        }
        return try await body()
    }

    /// Refuses a change before any of it is done when a newer AnyBrowser wrote the database.
    private static func requireWritable(_ backend: AutomationBackend) throws {
        do {
            try backend.store.requireWritable()
        } catch {
            throw Failure(409, "read_only", error.localizedDescription)
        }
    }

    static func route(_ request: Request, backend: AutomationBackend) async -> Response {
        guard let call = Call(request) else { return notFound }
        do {
            return try await dispatch(call, backend)
        } catch let failure as Failure {
            return failure.response
        } catch {
            return .error(500, "failed", error.localizedDescription)
        }
    }

    private static func dispatch(_ call: Call, _ backend: AutomationBackend) async throws -> Response {
        let path = call.path
        switch (path.first, path.count) {
        case ("profiles", 1):
            try call.allow("GET", "POST")
            guard call.method == "POST" else { return try list(call, backend) }
            try requireWritable(backend)
            return try await oneCreationAtATime(backend) { try await create(call, backend) }
        case ("profiles", 2) where path[1] == "batch":
            try call.allow("POST")
            try requireWritable(backend)
            return try await oneCreationAtATime(backend) { try await createBatch(call, backend) }
        case ("profiles", 2):
            try call.allow("GET", "PATCH", "DELETE")
            switch call.method {
            case "GET": return try show(try saved(path[1], backend), call, backend)
            case "PATCH": return try update(try saved(path[1], backend), call, backend)
            default: return try await delete(path[1], call, backend)
            }
        case ("profiles", 3):
            return try await profileAction(path[2], id: path[1], call, backend)
        case ("trash", 1):
            try call.allow("GET")
            return .json(200, Body(["profiles": backend.store.trashed.map { entry -> ProfileObject in
                var item = object(entry.profile, backend: backend)
                item.deletedAt = entry.deletedAt
                return item
            }]))
        case ("proxies", 1):
            try call.allow("GET", "POST")
            return call.method == "GET" ? try listProxies(call, backend) : try addProxies(call, backend)
        case ("proxies", 2) where path[1] == "check":
            try call.allow("POST")
            return try await checkProxies(call, backend)
        case ("proxies", 2):
            try call.allow("GET", "PATCH", "DELETE")
            let entry = try proxyEntry(path[1], backend)
            switch call.method {
            case "GET":
                return .json(200, Body(["proxy": proxyObject(entry, secrets: try call.flag("secrets"), users: proxyUsers(backend))]))
            case "PATCH": return try updateProxy(entry, call, backend)
            default:
                try requireWritable(backend)
                try backend.proxyLibrary.remove([entry.id])
                return .json(200, Body(["id": entry.id, "removed": true]))
            }
        case ("windows", 2) where path[1] == "arrange":
            try call.allow("POST")
            return try await arrange(call, backend)
        default:
            return notFound
        }
    }

    private static func profileAction(_ action: String, id: String, _ call: Call, _ backend: AutomationBackend) async throws -> Response {
        switch action {
        case "start", "restart":
            try call.allow("POST")
            return try await start(try saved(id, backend), call, backend, restarting: action == "restart")
        case "stop":
            try call.allow("POST")
            return try await stop(try saved(id, backend), call, backend)
        case "clone":
            try call.allow("POST")
            _ = try saved(id, backend)
            try requireWritable(backend)
            // The original is read again once it is this clone's turn.
            return try await oneCreationAtATime(backend) { try clone(try saved(id, backend), call, backend) }
        case "restore":
            try call.allow("POST")
            guard let uuid = UUID(uuidString: id), backend.store.trashed.contains(where: { $0.id == uuid }) else {
                throw Failure(404, "not_found", "回收站中没有这个 Profile。")
            }
            try requireWritable(backend)
            // A purge deletes the browser data before the record; restoring meanwhile would bring
            // the Profile back without it.
            guard !isBusy(uuid, backend) else { throw Failure(busy) }
            try backend.restore(uuid)
            return try show(try saved(id, backend), call, backend)
        case "log":
            try call.allow("GET")
            let profile = try saved(id, backend)
            return .json(200, Body(["log": backend.launchLog(for: profile.id)]))
        case "cookies":
            try call.allow("GET", "POST")
            let profile = try saved(id, backend)
            return call.method == "GET" ? try await exportCookies(profile, call, backend)
                : try await importCookies(profile, call, backend)
        case "selfcheck":
            try call.allow("GET")
            return try await selfCheck(try saved(id, backend), backend)
        default:
            return notFound
        }
    }

    private static func saved(_ id: String, _ backend: AutomationBackend) throws -> BrowserProfile {
        guard let id = UUID(uuidString: id), let profile = backend.profiles.first(where: { $0.id == id }) else {
            throw Failure(notFound)
        }
        return profile
    }

    static func object(_ profile: BrowserProfile, backend: AutomationBackend) -> ProfileObject {
        var object = ProfileObject(id: profile.id, name: profile.name, group: profile.group, port: profile.port,
                                   status: "stopped", debugReady: false, tags: profile.tags,
                                   accountStatus: profile.accountStatus, pendingRestart: false)
        switch backend.state(for: profile.id) {
        case .stopped: object.status = "stopped"
        case .starting: object.status = "starting"
        case .stopping: object.status = "stopping"
        case .failed: object.status = "failed"
        case let .running(_, port, ready):
            // A running browser keeps the port it was started with until it restarts.
            object.status = "running"
            object.port = port
            object.debugReady = ready
            object.pendingRestart = backend.hasPendingRestart(profile.id)
        }
        return object
    }

    private static let runStates: Set<String> = ["stopped", "starting", "stopping", "running", "failed"]

    // MARK: Profiles

    /// `q` is a sidebar search (`tag:`, `status:` and `group:` terms included). `group` matches the
    /// whole group name (empty for ungrouped), `tag` a whole tag and may repeat (all must match),
    /// `status` the browser state and `accountStatus` the recorded account state (`none` for unset).
    private static func list(_ call: Call, _ backend: AutomationBackend) throws -> Response {
        let search = call.value("q").map(ProfileLibrary.Query.init)
        let groups = call.values("group").map { $0.trimmingCharacters(in: .whitespaces) }
        let tags = call.values("tag")
        let states = call.values("status")
        if let unknown = states.first(where: { !runStates.contains($0) }) {
            throw Failure.invalid("参数 status 须为 \(runStates.sorted().joined(separator: "、")) 之一：\(unknown.prefix(40))")
        }
        let accounts = call.values("accountStatus")
        if let unknown = accounts.first(where: { $0 != "none" && AccountStatus(rawValue: $0) == nil }) {
            let known = AccountStatus.allCases.map(\.rawValue) + ["none"]
            throw Failure.invalid("参数 accountStatus 须为 \(known.joined(separator: "、")) 之一：\(unknown.prefix(40))")
        }
        let objects = backend.profiles.filter { profile in
            (search?.matches(profile) ?? true)
                && (groups.isEmpty || groups.contains(profile.group))
                && tags.allSatisfy { tag in profile.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
                && (accounts.isEmpty || accounts.contains(profile.accountStatus?.rawValue ?? "none"))
        }.map { object($0, backend: backend) }.filter { states.isEmpty || states.contains($0.status) }
        return .json(200, Body(["profiles": objects]))
    }

    private static func show(_ profile: BrowserProfile, _ call: Call, _ backend: AutomationBackend) throws -> Response {
        .json(200, Body(["profile": object(profile, backend: backend),
                         "config": config(profile, secrets: try call.flag("secrets"))]))
    }

    /// The options of a create request that are not Profile fields.
    private struct Creation {
        enum Library {
            case entries([UUID])
            case unused
        }

        var preset: IdentityPreset?
        var library: Library?
        var localeFromExit = true

        /// Takes the options out of `fields`, leaving the Profile fields.
        init(taking fields: inout [String: Any], batch: Bool) throws {
            if let id = try string(fields.removeValue(forKey: "preset"), "preset") {
                guard let preset = IdentityPreset.all.first(where: { $0.id == id }) else {
                    throw Failure.invalid("没有这个身份模板：\(id.prefix(40))。可用的有 \(IdentityPreset.all.map(\.id).joined(separator: "、"))。")
                }
                self.preset = preset
            }
            localeFromExit = try boolean(fields.removeValue(forKey: "localeFromExit"), "localeFromExit") ?? true
            let usage = batch ? "字段 proxyFromLibrary 须为 \"unused\"、代理库条目的 id 或 id 数组。"
                : "字段 proxyFromLibrary 须为 \"unused\" 或代理库条目的 id。"
            if let value = fields.removeValue(forKey: "proxyFromLibrary"), !(value is NSNull) {
                if let text = value as? String {
                    if text == "unused" {
                        library = .unused
                    } else if let id = UUID(uuidString: text) {
                        library = .entries([id])
                    } else {
                        throw Failure.invalid(usage)
                    }
                } else if batch, let list = try? ids(value, "proxyFromLibrary"), !list.isEmpty {
                    library = .entries(list)
                } else {
                    throw Failure.invalid(usage)
                }
            }
            if library != nil, fields["proxy"] != nil {
                throw Failure.invalid("proxy 和 proxyFromLibrary 只能填一个。")
            }
        }

        /// One proxy address per new Profile from the library.
        @MainActor
        func proxies(count: Int, _ backend: AutomationBackend) throws -> [String]? {
            let entries = backend.proxyLibrary.entries
            switch library {
            case nil:
                return nil
            case .entries(let ids):
                guard ids.count == 1 || ids.count == count else {
                    throw Failure.invalid("proxyFromLibrary 须为一个 id，或与 count 数量相同的 id。")
                }
                let urls = try ids.map { id in
                    guard let entry = entries.first(where: { $0.id == id }) else {
                        throw Failure.invalid("代理库中没有 \(id.uuidString)。")
                    }
                    return entry.url
                }
                return ids.count == 1 ? Array(repeating: urls[0], count: count) : urls
            case .unused:
                let used = proxyUsers(backend)
                let free = entries.filter { used[$0.url] == nil }
                guard free.count >= count else {
                    throw Failure(409, "conflict", "代理库中只有 \(free.count) 条没有 Profile 使用的代理，不够 \(count) 个。")
                }
                return free.prefix(count).map(\.url)
            }
        }
    }

    /// The saved and trashed Profiles using each proxy, by normalized address, in store order.
    private static func proxyUsers(_ backend: AutomationBackend) -> [String: [UUID]] {
        ProxyAssignment.users(of: backend.store.profiles + backend.store.trashed.map(\.profile))
    }

    /// Whether `fields` sets the language or time zone itself, so the exit need not be looked up.
    private static func setsLocale(_ fields: [String: Any]) -> Bool {
        guard let fingerprint = fields["fingerprint"] as? [String: Any] else { return false }
        return ["language", "timeZone", "languages"].contains { fingerprint[$0] != nil }
    }

    /// Language and time zone for each proxy, from its exit (looked up once per address, all at the
    /// same time), or from this Mac without a proxy; nil when the lookup failed.
    private static func locales(for proxies: [String], _ backend: AutomationBackend) async
        -> [String: (hint: IdentitySampler.LocaleHint?, exit: ProxyExit?)] {
        var results: [String: (hint: IdentitySampler.LocaleHint?, exit: ProxyExit?)] = [:]
        var lookups: [String] = []
        for proxy in proxies where results[proxy] == nil && !lookups.contains(proxy) {
            if proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results[proxy] = (.host, nil)
            } else {
                lookups.append(proxy)
            }
        }
        await withTaskGroup(of: (String, ProxyExit?).self) { group in
            for proxy in lookups {
                group.addTask { @MainActor in (proxy, await backend.lookUpExit(through: proxy)) }
            }
            for await (proxy, exit) in group {
                results[proxy] = (exit.flatMap(IdentitySampler.LocaleHint.init(exit:)), exit)
            }
        }
        return results
    }

    /// Applies the exit's locale to each new Profile, returning a warning per proxy it failed for.
    private static func alignLocales(_ profiles: inout [BrowserProfile], _ backend: AutomationBackend)
        async -> (exits: [UUID: ProxyExit], warnings: [String]) {
        let found = await locales(for: profiles.map(\.proxySpec), backend)
        var exits: [UUID: ProxyExit] = [:]
        var warnings: [String] = []
        for index in profiles.indices {
            let proxy = profiles[index].proxySpec
            guard let result = found[proxy] else { continue }
            if let hint = result.hint { profiles[index].fingerprint.apply(hint) }
            if let exit = result.exit { exits[profiles[index].id] = exit }
            if result.hint == nil {
                let server = (try? ProxyChain.parse(spec: proxy)).flatMap { $0 }?.summary ?? proxy
                let warning = "代理 \(server) 的出口检测失败，语言和时区保持随机。"
                if !warnings.contains(warning) { warnings.append(warning) }
            }
        }
        return (exits, warnings)
    }

    /// Validates and saves new or changed Profiles in one transaction. A port or seed another
    /// Profile holds answers 409.
    private static func save(_ profiles: [BrowserProfile], _ backend: AutomationBackend) throws -> [BrowserProfile] {
        let store = backend.store
        let checked: [BrowserProfile]
        do {
            checked = try profiles.map { profile in
                // Spaces around these are dropped, as the editor drops them, rather than refused.
                var value = profile
                for field in [\FingerprintSettings.language, \.timeZone, \.platformVersion, \.brandVersion] {
                    let text = value.fingerprint[keyPath: field]
                    value.fingerprint[keyPath: field] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // A new seed is a new device; the id would otherwise keep pointing at the old one.
                if let existing = store.profiles.first(where: { $0.id == value.id }),
                   existing.fingerprint.seed != value.fingerprint.seed {
                    value.deviceIdentity = nil
                }
                return try value.validated()
            }
        } catch {
            throw Failure.invalid(error.localizedDescription)
        }
        do {
            return try store.saveAll(checked)
        } catch {
            let others = store.profiles + store.trashed.map(\.profile)
            let collides = checked.contains { profile in
                others.contains { $0.id != profile.id && ($0.port == profile.port || $0.fingerprint.seed == profile.fingerprint.seed) }
                    || store.unreadableRows.contains { $0.port == profile.port || $0.seed == profile.fingerprint.seed }
            }
            throw Failure(collides ? 409 : 500, collides ? "conflict" : "save_failed", error.localizedDescription)
        }
    }

    /// Records the exits found for new Profiles, so their first launch need not look them up again.
    private static func record(_ exits: [UUID: ProxyExit], _ backend: AutomationBackend) {
        for (id, exit) in exits { try? backend.proxyLibrary.recordExit(exit, forProfile: id) }
    }

    /// A new Profile: name, port and identity as the window's "新建 Profile" picks them, with the
    /// language and time zone of its proxy's exit, then the fields given.
    private static func create(_ call: Call, _ backend: AutomationBackend) async throws -> Response {
        var fields = try call.object()
        let creation = try Creation(taking: &fields, batch: false)
        guard fields["id"] == nil else { throw Failure.invalid("新建 Profile 时不能指定 id。") }
        var draft = try backend.store.makeDraft()
        if let preset = creation.preset {
            draft.fingerprint = IdentitySampler.sample(seed: draft.fingerprint.seed, constraints: .init(preset: preset))
        }
        if let proxy = try creation.proxies(count: 1, backend)?.first { draft.proxy = proxy }
        var profiles = [try merged(fields, into: draft)]
        var aligned: (exits: [UUID: ProxyExit], warnings: [String]) = ([:], [])
        if creation.localeFromExit, !setsLocale(fields) {
            aligned = await alignLocales(&profiles, backend)
        }
        let profile = try save(profiles, backend)[0]
        record(aligned.exits, backend)
        return .json(201, Body(["profile": object(profile, backend: backend),
                                "config": config(profile, secrets: try call.flag("secrets")),
                                "warnings": aligned.warnings]))
    }

    /// Up to `ProfileLibrary.maxBatch` new Profiles named `<prefix> <n>`, each with its own identity;
    /// every other Profile field given applies to all of them. Saved all or none.
    private static func createBatch(_ call: Call, _ backend: AutomationBackend) async throws -> Response {
        var fields = try call.object()
        let creation = try Creation(taking: &fields, batch: true)
        guard let count = try integer(fields.removeValue(forKey: "count"), "count") else {
            throw Failure.invalid("缺少字段 count。")
        }
        let prefix = try string(fields.removeValue(forKey: "prefix"), "prefix") ?? "Profile"
        for key in ["id", "name", "port"] where fields[key] != nil {
            throw Failure.invalid("批量新建时不能指定 \(key)，它们按序号分配。")
        }
        if (fields["fingerprint"] as? [String: Any])?["seed"] != nil {
            throw Failure.invalid("批量新建时不能指定 fingerprint.seed，每个 Profile 使用自己的种子。")
        }
        let store = backend.store
        var profiles: [BrowserProfile]
        do {
            profiles = try ProfileLibrary.batch(
                ProfileLibrary.BatchRequest(count: count, prefix: prefix, preset: creation.preset, proxy: ""),
                existingNames: Set(store.profiles.map(\.name)), takenPorts: store.takenPorts, takenSeeds: store.takenSeeds)
        } catch {
            throw Failure.invalid(error.localizedDescription)
        }
        let proxies = try creation.proxies(count: count, backend)
        for index in profiles.indices {
            profiles[index].proxy = proxies?[index] ?? BrowserProfile.defaultProxy
            profiles[index] = try merged(fields, into: profiles[index])
        }
        var aligned: (exits: [UUID: ProxyExit], warnings: [String]) = ([:], [])
        if creation.localeFromExit, !setsLocale(fields) {
            aligned = await alignLocales(&profiles, backend)
        }
        let saved = try save(profiles, backend)
        record(aligned.exits, backend)
        return .json(201, Body(["profiles": saved.map { object($0, backend: backend) }, "warnings": aligned.warnings]))
    }

    /// A copy with a new id, name, port and seed, and the fields given; browser data is not copied.
    private static func clone(_ original: BrowserProfile, _ call: Call, _ backend: AutomationBackend) throws -> Response {
        let fields = try call.object()
        guard fields["id"] == nil else { throw Failure.invalid("复制 Profile 时不能指定 id。") }
        let store = backend.store
        let copy = try ProfileLibrary.clone(original, existingNames: Set(store.profiles.map(\.name)),
                                            takenPorts: store.takenPorts, takenSeeds: store.takenSeeds)
        let profile = try save([try merged(fields, into: copy)], backend)[0]
        return .json(201, Body(["profile": object(profile, backend: backend),
                                "config": config(profile, secrets: try call.flag("secrets"))]))
    }

    /// Merges the body into the saved configuration; a running browser keeps what it started with
    /// until it restarts, which `pendingRestart` reports.
    private static func update(_ profile: BrowserProfile, _ call: Call, _ backend: AutomationBackend) throws -> Response {
        let id = profile.id
        try requireWritable(backend)
        guard !isBusy(id, backend) else { throw Failure(busy) }
        var patch = try call.object()
        if let given = patch["id"] {
            guard (given as? String).flatMap(UUID.init(uuidString:)) == id else { throw Failure.invalid("Profile 的 id 不能修改。") }
        }
        // A configuration read without secrets and sent back whole names the proxy without its
        // credentials; that keeps the saved address rather than signing out of the proxy.
        let redacted = ProfileLibrary.withoutSecrets(profile)
        if let proxy = patch["proxy"] as? String, proxy == redacted.proxy {
            patch["proxy"] = nil
        }
        if let transit = patch["transitProxy"] as? String, transit == redacted.transitProxy {
            patch["transitProxy"] = nil
        }
        var updated = try merged(patch, into: profile)
        updated.id = id
        let saved = try save([updated], backend)[0]
        return .json(200, Body(["profile": object(saved, backend: backend),
                                "config": config(saved, secrets: try call.flag("secrets")),
                                "pendingRestart": backend.hasPendingRestart(id)]))
    }

    /// Moves a stopped Profile to the recycle bin. With `purge=1` it removes the record for good,
    /// from the recycle bin too, and with `deleteData=1` its browser data as well.
    private static func delete(_ id: String, _ call: Call, _ backend: AutomationBackend) async throws -> Response {
        let purge = try call.flag("purge")
        let deleteData = try call.flag("deleteData")
        guard purge || !deleteData else { throw Failure.invalid("deleteData=1 须与 purge=1 一起使用；回收站中的 Profile 保留浏览器资料。") }
        guard let uuid = UUID(uuidString: id) else { throw Failure(notFound) }
        let saved = backend.profiles.contains { $0.id == uuid }
        guard saved || backend.store.trashed.contains(where: { $0.id == uuid }) else { throw Failure(notFound) }
        try requireWritable(backend)
        guard !isBusy(uuid, backend) else { throw Failure(busy) }
        if let blocker = backend.removalBlocker(uuid) {
            // Only a running browser is for the caller to stop; a batch in progress is another operation.
            let running = ProfileLibrary.removalBlocker(state: backend.state(for: uuid), busy: false, batchRunning: false)
            throw Failure(409, blocker == running ? "running" : "busy", blocker)
        }
        guard purge else {
            guard saved else { throw Failure(409, "trashed", "该 Profile 已在回收站中；永久删除请加 purge=1。") }
            try backend.trash(uuid)
            let deletedAt = backend.store.trashed.first { $0.id == uuid }?.deletedAt
            return .json(200, Body(["id": uuid, "result": "trashed", "deletedAt": deletedAt, "dataDeleted": false,
                                    "warnings": [String]()]))
        }
        let problem: String?
        do {
            problem = try await backend.remove(uuid, deletingBrowserData: deleteData, recordRemoved: {})
        } catch {
            throw Failure(500, "remove_failed", error.localizedDescription)
        }
        return .json(200, Body(["id": uuid, "result": "removed", "deletedAt": Date?.none, "dataDeleted": deleteData,
                                "warnings": problem.map { [$0] } ?? []]))
    }

    // MARK: Launches

    /// `{headless, urls, args}` from the body, checked the way the launch will check them.
    private static func overrides(_ call: Call) throws -> LaunchOverrides {
        let body = try call.object()
        try only(["headless", "urls", "args"], in: body)
        var overrides = LaunchOverrides(headless: try boolean(body["headless"], "headless") ?? false)
        if let urls = try strings(body["urls"], "urls") {
            do {
                _ = try LaunchOptions(startURLs: urls).validated()
            } catch {
                throw Failure.invalid(error.localizedDescription)
            }
            overrides.urls = urls
        }
        if let arguments = try strings(body["args"], "args") {
            do {
                overrides.arguments = try BrowserRuntime.checkedArguments(arguments)
            } catch {
                throw Failure.invalid(error.localizedDescription)
            }
        }
        return overrides
    }

    private static func start(_ profile: BrowserProfile, _ call: Call, _ backend: AutomationBackend,
                              restarting: Bool) async throws -> Response {
        let id = profile.id
        let overrides = try overrides(call)
        guard !isBusy(id, backend) else { throw Failure(busy) }
        var endpoint: URL?
        var outcome = LaunchOutcome(startedFresh: false)
        if !restarting, case .running = backend.state(for: id) {
            // Already running: report it, never start it again over its current configuration. The
            // state may be stale (the window refreshes it), so re-read it before giving up.
            endpoint = await backend.devToolsEndpoint(for: id)
            if endpoint == nil {
                await backend.refresh(id)
                if case .running = backend.state(for: id) {
                    throw Failure(503, "unavailable", "浏览器正在运行，但调试端口尚未就绪，请稍后重试。")
                }
            } else if overrides != LaunchOverrides() {
                outcome.warnings.append("浏览器已在运行，本次的启动参数没有生效；需要时用 restart。")
            }
        }
        if endpoint == nil {
            guard !isBusy(id, backend) else { throw Failure(busy) }
            do {
                if restarting {
                    outcome = try await backend.restart(id, overrides: overrides, fingerprintChange: .warn)
                } else {
                    outcome = try await backend.start(id, overrides: overrides, fingerprintChange: .warn)
                }
            } catch {
                throw Failure(500, "start_failed", error.localizedDescription)
            }
            endpoint = await backend.devToolsEndpoint(for: id)
        }
        guard let endpoint, let address = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = address.host, let port = address.port else {
            throw Failure(500, "start_failed", "浏览器已启动，但无法确认调试地址。")
        }
        let current = backend.profiles.first { $0.id == id } ?? profile
        return .json(200, Body(["profile": object(current, backend: backend),
                                "debug": DebugAddress(http: "http://\(host):\(port)", webSocket: endpoint.absoluteString),
                                "startedFresh": outcome.startedFresh, "warnings": outcome.warnings]))
    }

    private static func stop(_ profile: BrowserProfile, _ call: Call, _ backend: AutomationBackend) async throws -> Response {
        let force = try call.flag("force")
        guard !isBusy(profile.id, backend) else { throw Failure(busy) }
        do {
            try await backend.stop(profile.id, force: force)
        } catch {
            throw Failure(500, "stop_failed", error.localizedDescription)
        }
        let current = backend.profiles.first { $0.id == profile.id } ?? profile
        return .json(200, Body(["profile": object(current, backend: backend)]))
    }

    /// Runs `body` with the DevTools endpoint of the Profile's browser. A stopped Profile is started
    /// without windows for it and stopped again afterwards.
    private static func withBrowser<Value>(_ profile: BrowserProfile, _ backend: AutomationBackend, failure code: String,
                                           _ body: (URL) async throws -> Value) async throws
        -> (value: Value, startedHeadless: Bool, warnings: [String]) {
        let id = profile.id
        guard !isBusy(id, backend) else { throw Failure(busy) }
        if case .running = backend.state(for: id) {
            if let endpoint = await backend.devToolsEndpoint(for: id) { return (try await run(body, endpoint, code), false, []) }
            // The state may be stale; a browser that is gone is started below.
            await backend.refresh(id)
            if case .running = backend.state(for: id) {
                throw Failure(503, "unavailable", "浏览器正在运行，但调试端口尚未就绪，请稍后重试。")
            }
            guard !isBusy(id, backend) else { throw Failure(busy) }
        }
        let key = ObjectIdentifier(backend)
        temporaryRuns[key, default: []].insert(id)
        defer {
            temporaryRuns[key]?.remove(id)
            if temporaryRuns[key]?.isEmpty == true { temporaryRuns[key] = nil }
        }
        let outcome: LaunchOutcome
        do {
            // Start pages would only slow the transfer down.
            outcome = try await backend.start(id, overrides: LaunchOverrides(headless: true, urls: []), fingerprintChange: .warn)
        } catch {
            throw Failure(500, "start_failed", error.localizedDescription)
        }
        guard let endpoint = await backend.devToolsEndpoint(for: id) else {
            if outcome.startedFresh { try? await backend.stop(id, force: false) }
            throw Failure(500, "start_failed", "浏览器已启动，但无法确认调试地址。")
        }
        // Found running after all (started from the window meanwhile): it is not ours to stop.
        guard outcome.startedFresh else { return (try await run(body, endpoint, code), false, outcome.warnings) }
        var warnings = outcome.warnings
        let value: Value
        do {
            value = try await run(body, endpoint, code)
        } catch {
            try? await backend.stop(id, force: false)
            throw error
        }
        do {
            try await backend.stop(id, force: false)
        } catch {
            warnings.append("操作已完成，但未能停止临时启动的浏览器：\(error.localizedDescription)")
        }
        return (value, true, warnings)
    }

    private static func run<Value>(_ body: (URL) async throws -> Value, _ endpoint: URL, _ code: String) async throws -> Value {
        do {
            return try await body(endpoint)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(500, code, error.localizedDescription)
        }
    }

    private static func exportCookies(_ profile: BrowserProfile, _ call: Call, _ backend: AutomationBackend) async throws -> Response {
        let name = call.value("format") ?? CookieTransfer.Format.cookieEditor.rawValue
        guard let format = CookieTransfer.Format(rawValue: name) else {
            let known = CookieTransfer.Format.allCases.map(\.rawValue).joined(separator: "、")
            throw Failure.invalid("参数 format 须为 \(known) 之一。")
        }
        let transfer = try await withBrowser(profile, backend, failure: "cookies_failed") { endpoint in
            try await CookieTransfer.exportCookies(from: endpoint, format: format)
        }
        let export = transfer.value
        let cookies = JSONValue((try? JSONSerialization.jsonObject(with: export.data)) ?? [Any]())
        return .json(200, Body(["format": format.rawValue, "count": export.count, "skipped": export.skipped,
                                "cookies": cookies, "startedHeadless": transfer.startedHeadless, "warnings": transfer.warnings]))
    }

    /// The body is a cookie file in any format the window imports: JSON (Cookie-Editor,
    /// EditThisCookie, DevTools, Playwright) or Netscape cookies.txt.
    private static func importCookies(_ profile: BrowserProfile, _ call: Call, _ backend: AutomationBackend) async throws -> Response {
        do {
            _ = try CookieTransfer.decode(call.body, now: Date())
        } catch {
            throw Failure.invalid(error.localizedDescription)
        }
        let file = call.body
        let transfer = try await withBrowser(profile, backend, failure: "cookies_failed") { endpoint in
            try await CookieTransfer.importCookies(file, into: endpoint)
        }
        let result = transfer.value
        return .json(200, Body(["imported": result.imported, "skipped": result.skipped, "evicted": result.evicted,
                                "displaced": result.displaced, "summary": result.summary,
                                "startedHeadless": transfer.startedHeadless, "warnings": transfer.warnings]))
    }

    /// The runtime self-check of a running Profile, compared with its saved configuration and last exit.
    private static func selfCheck(_ profile: BrowserProfile, _ backend: AutomationBackend) async throws -> Response {
        let id = profile.id
        guard !isBusy(id, backend) else { throw Failure(busy) }
        guard let endpoint = await backend.devToolsEndpoint(for: id) else {
            // The state may be stale, so it is read again before answering.
            await backend.refresh(id)
            if case .running = backend.state(for: id) {
                throw Failure(503, "unavailable", "浏览器正在运行，但调试端口尚未就绪，请稍后重试。")
            }
            throw Failure(409, "not_running", "自检需要 Profile 正在运行，请先启动它。")
        }
        do {
            return .json(200, try await SelfCheck.run(endpoint: endpoint, profile: profile, exit: backend.lastExit(for: id)?.exit))
        } catch {
            throw Failure(500, "selfcheck_failed", error.localizedDescription)
        }
    }

    /// Tiles the windows of `ids` (default: every running Profile) in `columns` columns.
    private static func arrange(_ call: Call, _ backend: AutomationBackend) async throws -> Response {
        let body = try call.object()
        try only(["ids", "columns"], in: body)
        let columns = try integer(body["columns"], "columns")
        if let columns, columns < 1 { throw Failure.invalid("字段 columns 须为正整数。") }
        let ids: [UUID]
        if let given = try AutomationHTTP.ids(body["ids"], "ids") {
            guard !given.isEmpty else { throw Failure.invalid("字段 ids 不能为空。") }
            if let unknown = given.first(where: { id in !backend.profiles.contains { $0.id == id } }) {
                throw Failure(404, "not_found", "没有这个 Profile：\(unknown.uuidString)")
            }
            ids = given
        } else {
            ids = backend.profiles.map(\.id).filter { id in
                if case .running = backend.state(for: id) { return true }
                return false
            }
        }
        let outcomes: [WindowArrangement.Outcome]
        do {
            outcomes = try await backend.arrangeWindows(ids, columns: columns)
        } catch {
            throw Failure(500, "arrange_failed", error.localizedDescription)
        }
        return .json(200, Body(["windows": outcomes.map { WindowObject(id: $0.id, frame: $0.frame, error: $0.failure) }]))
    }

    // MARK: Proxy library

    private static func proxyEntry(_ id: String, _ backend: AutomationBackend) throws -> ProxyEntry {
        guard let id = UUID(uuidString: id), let entry = backend.proxyLibrary.entries.first(where: { $0.id == id }) else {
            throw Failure(404, "not_found", "代理库中没有这条代理。")
        }
        return entry
    }

    private static func proxyObject(_ entry: ProxyEntry, secrets: Bool, users: [String: [UUID]]) -> ProxyObject {
        ProxyObject(id: entry.id, url: secrets ? entry.url : entry.endpoint?.server ?? "",
                           hasCredentials: entry.endpoint?.hasCredentials ?? false, label: entry.label, tags: entry.tags,
                           note: entry.note, createdAt: entry.createdAt, lastExit: entry.lastExit,
                           lastCheckedAt: entry.lastCheckedAt, profiles: users[entry.url] ?? [])
    }

    private static func listProxies(_ call: Call, _ backend: AutomationBackend) throws -> Response {
        let secrets = try call.flag("secrets")
        let users = proxyUsers(backend)
        return .json(200, Body(["proxies": backend.proxyLibrary.entries.map { proxyObject($0, secrets: secrets, users: users) }]))
    }

    /// Adds `{text}` (one address per line, as pasted in the window) or `{urls}`, with an optional
    /// `label`. Addresses already in the library are counted as duplicates.
    private static func addProxies(_ call: Call, _ backend: AutomationBackend) throws -> Response {
        try requireWritable(backend)
        let body = try call.object()
        try only(["text", "urls", "label"], in: body)
        let text = try string(body["text"], "text")
        let listed = try strings(body["urls"], "urls")
        guard (text == nil) != (listed == nil) else { throw Failure.invalid("请填写 text 或 urls 其中一个。") }
        var urls: [String] = []
        var rejected: [String] = []
        if let text {
            (urls, rejected) = ProxyLibrary.parseList(text)
        } else {
            for address in listed ?? [] {
                if let endpoint = (try? ProxyEndpoint.parse(address)).flatMap({ $0 }) {
                    if !urls.contains(endpoint.url) { urls.append(endpoint.url) }
                } else {
                    rejected.append(address)
                }
            }
        }
        let added: [ProxyEntry]
        do {
            added = try backend.proxyLibrary.add(urls, label: try string(body["label"], "label") ?? "")
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalid(error.localizedDescription)
        }
        let users = proxyUsers(backend)
        return .json(added.isEmpty ? 200 : 201, Body(["added": added.map { proxyObject($0, secrets: false, users: users) },
                                                       "duplicates": urls.count - added.count, "rejected": rejected]))
    }

    private static func updateProxy(_ entry: ProxyEntry, _ call: Call, _ backend: AutomationBackend) throws -> Response {
        try requireWritable(backend)
        let body = try call.object()
        try only(["url", "label", "tags", "note"], in: body)
        var value = entry
        // As for Profiles: the address as listed without credentials keeps the saved one.
        if let url = try string(body["url"], "url"), url != entry.endpoint?.server {
            guard let endpoint = (try? ProxyEndpoint.parse(url)).flatMap({ $0 }) else {
                throw Failure.invalid("代理地址无效：\(url.prefix(80))")
            }
            if backend.proxyLibrary.entries.contains(where: { $0.id != entry.id && $0.url == endpoint.url }) {
                throw Failure(409, "conflict", "代理库中已有这个代理地址。")
            }
            value.url = endpoint.url
        }
        value.label = try string(body["label"], "label") ?? value.label
        value.tags = try strings(body["tags"], "tags") ?? value.tags
        value.note = try string(body["note"], "note") ?? value.note
        do {
            try backend.proxyLibrary.update(value)
        } catch {
            throw Failure.invalid(error.localizedDescription)
        }
        let saved = backend.proxyLibrary.entries.first { $0.id == entry.id } ?? value
        return .json(200, Body(["proxy": proxyObject(saved, secrets: try call.flag("secrets"), users: proxyUsers(backend))]))
    }

    /// Looks up the exit of each proxy in `ids` (default: all), eight at a time, and records it.
    private static func checkProxies(_ call: Call, _ backend: AutomationBackend) async throws -> Response {
        let body = try call.object()
        try only(["ids"], in: body)
        let library = backend.proxyLibrary
        var entries = library.entries
        if let ids = try ids(body["ids"], "ids") {
            entries = try ids.map { id in
                guard let entry = library.entries.first(where: { $0.id == id }) else {
                    throw Failure(404, "not_found", "代理库中没有 \(id.uuidString)。")
                }
                return entry
            }
        }
        var outcomes: [UUID: Result<ProxyExit, Error>] = [:]
        await withTaskGroup(of: (UUID, Result<ProxyExit, Error>).self) { group in
            var next = 0
            func enqueue() {
                guard next < entries.count else { return }
                let entry = entries[next]
                next += 1
                group.addTask { @MainActor in
                    do {
                        return (entry.id, .success(try await backend.checkProxy(entry)))
                    } catch {
                        return (entry.id, .failure(error))
                    }
                }
            }
            for _ in 0..<8 { enqueue() }
            for await (id, outcome) in group {
                outcomes[id] = outcome
                enqueue()
            }
        }
        let users = proxyUsers(backend)
        var results: [Body] = []
        for entry in entries {
            var error: String?
            switch outcomes[entry.id] {
            case .success(let exit)?:
                try? library.recordCheck(entry.id, exit: exit)
            case .failure(let failure)?:
                try? library.recordCheck(entry.id, exit: nil)
                error = failure.localizedDescription
            case nil:
                error = "未能检测。"
            }
            let current = library.entries.first { $0.id == entry.id } ?? entry
            results.append(Body(["proxy": proxyObject(current, secrets: false, users: users), "error": error]))
        }
        return .json(200, Body(["results": results]))
    }
}
