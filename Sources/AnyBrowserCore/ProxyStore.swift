import Combine
import CryptoKit
import Foundation
import SQLite3

/// A proxy kept in the library, to be handed to Profiles.
public struct ProxyEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The normalized address (`ProxyEndpoint.url`), credentials included.
    public var url: String
    public var label: String
    public var tags: [String]
    public var note: String
    public var createdAt: Date
    /// The exit seen by the latest check; nil when that check failed or none was made.
    public var lastExit: ProxyExit?
    public var lastCheckedAt: Date?

    public init(id: UUID = UUID(), url: String, label: String = "", tags: [String] = [], note: String = "",
                createdAt: Date = Date(), lastExit: ProxyExit? = nil, lastCheckedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.label = label
        self.tags = tags
        self.note = note
        self.createdAt = createdAt
        self.lastExit = lastExit
        self.lastCheckedAt = lastCheckedAt
    }

    public var endpoint: ProxyEndpoint? { try? ProxyEndpoint.parse(url, allowingSOCKSCredentials: true) }
}

/// The last exit seen for a Profile, kept across launches of the app. It holds only while the
/// Profile keeps the proxy it was seen through.
public struct ProfileExitRecord: Equatable, Sendable {
    public var exit: ProxyExit
    public var checkedAt: Date
    /// `key(for:)` of the proxy the exit was seen through; nil when unknown, which holds for no proxy.
    public var proxy: String?

    public init(exit: ProxyExit, checkedAt: Date, proxy: String? = nil) {
        self.exit = exit
        self.checkedAt = checkedAt
        self.proxy = proxy
    }

    /// Whether the exit was seen through `proxy`, a Profile's proxy address however it is written.
    public func applies(to proxy: String) -> Bool {
        self.proxy != nil && self.proxy == Self.key(for: proxy)
    }

    /// What a record keeps of a proxy address (or chain spec): the SHA-256 of the normalized
    /// address, credentials included since providers pick the exit by user name, without storing
    /// the password again. An empty address (no proxy) has a key too; nil for one that does not parse.
    public static func key(for proxy: String) -> String? {
        guard let address = try? ProxyChain.parse(spec: proxy, allowingSOCKSCredentials: true)?.key ?? "" else { return nil }
        return SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A `profile_exits.exit` value: the exit's JSON, with the key of the proxy it was seen through
/// beside its fields. Rows written before the key was kept read back without one.
private struct StoredExit: Codable {
    var exit: ProxyExit
    var proxy: String?

    private enum Keys: String, CodingKey { case proxy }

    init(exit: ProxyExit, proxy: String?) {
        self.exit = exit
        self.proxy = proxy
    }

    init(from decoder: Decoder) throws {
        exit = try ProxyExit(from: decoder)
        proxy = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .proxy)
    }

    func encode(to encoder: Encoder) throws {
        try exit.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(proxy, forKey: .proxy)
    }
}

/// The proxy library and the exits recorded per Profile, stored in the Profile database.
@MainActor
public final class ProxyLibrary: ObservableObject {
    @Published public private(set) var entries: [ProxyEntry] = []
    @Published public private(set) var profileExits: [UUID: ProfileExitRecord] = [:]
    public let store: ProfileStore

    static let maximumLabelLength = 80
    static let maximumNoteLength = 2000

    /// Reads the library from the store's database. Rows this version cannot read are left in place
    /// and not listed.
    public init(store: ProfileStore) {
        self.store = store
        Self.rows(in: store, """
            SELECT id, url, label, tags, note, created_at, last_exit, last_checked_at FROM proxies
            ORDER BY created_at, rowid
            """) { row in
            if let entry = Self.entry(row) { entries.append(entry) }
        }
        Self.rows(in: store, "SELECT id, exit, checked_at FROM profile_exits") { row in
            if let text = sqlite3_column_text(row, 0), let id = UUID(uuidString: String(cString: text)),
               let stored = Self.decoded(StoredExit.self, row, column: 1) {
                let checked = Date(timeIntervalSince1970: sqlite3_column_double(row, 2))
                profileExits[id] = ProfileExitRecord(exit: stored.exit, checkedAt: checked, proxy: stored.proxy)
            }
        }
    }

    private static func rows(in store: ProfileStore, _ sql: String, _ body: (OpaquePointer) -> Void) {
        guard let read = try? store.statement(sql) else { return }
        defer { sqlite3_finalize(read) }
        while sqlite3_step(read) == SQLITE_ROW { body(read) }
    }

    /// The proxy addresses in `text`, one per line, in any form `ProxyEndpoint.parse` reads, as
    /// normalized URLs without duplicates. Blank lines and lines starting with `#` are ignored;
    /// lines that are not proxy addresses come back in `rejected`, as typed.
    public static func parseList(_ text: String) -> (urls: [String], rejected: [String]) {
        var urls: [String] = []
        var rejected: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let address = line.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty, !address.hasPrefix("#") else { continue }
            guard let endpoint = try? ProxyEndpoint.parse(address, allowingSOCKSCredentials: true) else {
                rejected.append(address)
                continue
            }
            if !urls.contains(endpoint.url) { urls.append(endpoint.url) }
        }
        return (urls, rejected)
    }

    /// Adds the addresses that are not in the library yet, all or none; returns the new entries.
    /// Addresses are compared once normalized, so `host:port:user:pass` matches the same proxy written
    /// as a URL. An invalid address throws and adds nothing.
    @discardableResult
    public func add(_ urls: [String], label: String = "") throws -> [ProxyEntry] {
        let label = try Self.validatedLabel(label)
        var known = Set(entries.map(\.url))
        var added: [ProxyEntry] = []
        let now = Self.stored(Date())
        for address in urls {
            let url = try Self.normalized(address)
            guard known.insert(url).inserted else { continue }
            added.append(ProxyEntry(url: url, label: label, createdAt: now))
        }
        guard !added.isEmpty else { return [] }
        try transaction { try added.forEach(write) }
        entries += added
        return added
    }

    /// Saves an edited entry. A changed address must not match another entry, and drops the exit
    /// checked through the old one.
    public func update(_ entry: ProxyEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw ProfileError.invalid("代理库中没有这条代理。")
        }
        var value = entry
        value.url = try Self.normalized(entry.url)
        value.label = try Self.validatedLabel(entry.label)
        value.tags = try BrowserProfile.validatedTags(entry.tags)
        value.note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.note.count <= Self.maximumNoteLength, value.note.unicodeScalars.count <= Self.maximumNoteLength * 8 else {
            throw ProfileError.invalid("备注最多 \(Self.maximumNoteLength) 个字符。")
        }
        if entries.contains(where: { $0.id != value.id && $0.url == value.url }) {
            throw ProfileError.invalid("代理库中已有这个代理地址。")
        }
        value.createdAt = entries[index].createdAt
        value.lastCheckedAt = value.lastCheckedAt.map(Self.stored)
        if value.url != entries[index].url {
            value.lastExit = nil
            value.lastCheckedAt = nil
        }
        try write(value)
        entries[index] = value
    }

    public func remove(_ ids: [UUID]) throws {
        let doomed = Set(ids)
        guard entries.contains(where: { doomed.contains($0.id) }) else { return }
        try transaction {
            for id in doomed {
                try run("DELETE FROM proxies WHERE id=?") { sqlite3_bind_text($0, 1, id.uuidString, -1, sqliteTransient) }
            }
        }
        entries.removeAll { doomed.contains($0.id) }
    }

    /// Records the result of checking an entry: its exit, or nil when the check failed.
    public func recordCheck(_ id: UUID, exit: ProxyExit?, at date: Date = Date()) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var value = entries[index]
        value.lastExit = exit
        value.lastCheckedAt = Self.stored(date)
        try write(value)
        entries[index] = value
    }

    /// The entry for a Profile's proxy address, however it is written.
    public func entry(matching proxy: String) -> ProxyEntry? {
        guard let endpoint = try? ProxyEndpoint.parse(proxy, allowingSOCKSCredentials: true) else { return nil }
        return entries.first { $0.url == endpoint.url }
    }

    /// The exit last seen for a Profile through `proxy`, by default the proxy the Profile has now:
    /// one seen through another proxy says nothing about this one.
    public func lastExit(forProfile id: UUID, proxy: String? = nil) -> (exit: ProxyExit, checkedAt: Date)? {
        guard let record = profileExits[id], let proxy = proxy ?? currentProxy(of: id),
              record.applies(to: proxy) else { return nil }
        return (record.exit, record.checkedAt)
    }

    /// Records the exit seen for a Profile through `proxy`, by default the proxy it has now.
    public func recordExit(_ exit: ProxyExit, forProfile id: UUID, proxy: String? = nil, at date: Date = Date()) throws {
        let key = (proxy ?? currentProxy(of: id)).flatMap(ProfileExitRecord.key(for:))
        let payload = try JSONEncoder().encode(StoredExit(exit: exit, proxy: key))
        try run("""
            INSERT INTO profile_exits(id, exit, checked_at) VALUES(?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET exit=excluded.exit, checked_at=excluded.checked_at
            """) { write in
            guard sqlite3_bind_text(write, 1, id.uuidString, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_double(write, 3, Self.seconds(date)) == SQLITE_OK else { return SQLITE_ERROR }
            return payload.withUnsafeBytes { sqlite3_bind_blob(write, 2, $0.baseAddress, Int32($0.count), sqliteTransient) }
        }
        profileExits[id] = ProfileExitRecord(exit: exit, checkedAt: Self.stored(date), proxy: key)
    }

    /// The proxy address (or chain spec) of a Profile of the store, in the recycle bin or not.
    private func currentProxy(of id: UUID) -> String? {
        (store.profiles.first { $0.id == id } ?? store.trashed.first { $0.id == id }?.profile)?.proxySpec
    }

    /// Drops what is known about a Profile's exit, for instance once the Profile is gone.
    public func forgetExit(forProfile id: UUID) throws {
        try run("DELETE FROM profile_exits WHERE id=?") { sqlite3_bind_text($0, 1, id.uuidString, -1, sqliteTransient) }
        profileExits[id] = nil
    }

    /// Other Profiles of the store whose last seen exit IP equals this Profile's, in store order.
    /// Only exits seen through each Profile's present proxy count, and records left by Profiles
    /// that no longer exist are ignored.
    public func profilesSharingExit(with id: UUID) -> [UUID] {
        guard let ip = lastExit(forProfile: id)?.exit.ip else { return [] }
        return store.profiles.filter { profile in
            guard profile.id != id, let record = profileExits[profile.id], record.exit.ip == ip else { return false }
            return record.applies(to: profile.proxySpec)
        }.map(\.id)
    }

    /// Times are kept to the millisecond, so that a value read back from the database equals the one
    /// written: converting a Date to seconds since 1970 and back can move it by a fraction.
    private static func seconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded() / 1000
    }

    private static func stored(_ date: Date) -> Date {
        Date(timeIntervalSince1970: seconds(date))
    }

    private static func normalized(_ address: String) throws -> String {
        guard let endpoint = try ProxyEndpoint.parse(address, allowingSOCKSCredentials: true) else {
            throw ProfileError.invalid("代理地址不能为空。")
        }
        return endpoint.url
    }

    private static func validatedLabel(_ label: String) throws -> String {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maximumLabelLength, text.unicodeScalars.count <= maximumLabelLength * 8,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalid("代理名称最多 \(maximumLabelLength) 个字符。")
        }
        return text
    }

    // Tags are stored comma-separated; validated tags never contain a comma.
    private static func entry(_ row: OpaquePointer) -> ProxyEntry? {
        let text = { (column: Int32) -> String? in sqlite3_column_text(row, column).map { String(cString: $0) } }
        guard let id = text(0).flatMap(UUID.init(uuidString:)), let url = text(1),
              let endpoint = try? ProxyEndpoint.parse(url, allowingSOCKSCredentials: true), endpoint.url == url else {
            return nil
        }
        let checked = sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 7))
        return ProxyEntry(id: id, url: url, label: text(2) ?? "",
                          tags: (text(3) ?? "").split(separator: ",").map(String.init), note: text(4) ?? "",
                          createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 5)),
                          lastExit: decoded(ProxyExit.self, row, column: 6), lastCheckedAt: checked)
    }

    private static func decoded<Value: Decodable>(_ type: Value.Type, _ row: OpaquePointer, column: Int32) -> Value? {
        guard let bytes = sqlite3_column_blob(row, column) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column))))
    }

    private func write(_ entry: ProxyEntry) throws {
        let exit = try entry.lastExit.map { try JSONEncoder().encode($0) }
        try run("""
            INSERT INTO proxies(id, url, label, tags, note, created_at, last_exit, last_checked_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET url=excluded.url, label=excluded.label, tags=excluded.tags,
                note=excluded.note, last_exit=excluded.last_exit, last_checked_at=excluded.last_checked_at
            """) { write in
            let texts = [entry.id.uuidString, entry.url, entry.label, entry.tags.joined(separator: ","), entry.note]
            for (offset, value) in texts.enumerated() {
                guard sqlite3_bind_text(write, Int32(offset + 1), value, -1, sqliteTransient) == SQLITE_OK else { return SQLITE_ERROR }
            }
            guard sqlite3_bind_double(write, 6, Self.seconds(entry.createdAt)) == SQLITE_OK else { return SQLITE_ERROR }
            let bound = exit.map { data in
                data.withUnsafeBytes { sqlite3_bind_blob(write, 7, $0.baseAddress, Int32($0.count), sqliteTransient) }
            } ?? sqlite3_bind_null(write, 7)
            guard bound == SQLITE_OK else { return SQLITE_ERROR }
            return entry.lastCheckedAt.map { sqlite3_bind_double(write, 8, Self.seconds($0)) } ?? sqlite3_bind_null(write, 8)
        }
    }

    /// Prepares `sql`, lets `bind` fill in its parameters and runs it to completion. Like the store's
    /// own writes, it refuses a database a newer AnyBrowser wrote.
    private func run(_ sql: String, bind: (OpaquePointer) -> Int32) throws {
        try store.requireWritable()
        let statement = try store.statement(sql)
        defer { sqlite3_finalize(statement) }
        guard bind(statement) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw store.databaseError() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try store.requireWritable()
        guard sqlite3_exec(store.database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw store.databaseError() }
        do {
            try body()
            guard sqlite3_exec(store.database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw store.databaseError() }
        } catch {
            sqlite3_exec(store.database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
}
