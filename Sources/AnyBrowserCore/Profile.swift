import Darwin
import Foundation

public enum BrowserPlatform: String, CaseIterable, Codable, Sendable {
    case macOS = "macos", windows, linux

    public var title: String {
        switch self {
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }
}

public enum BrowserBrand: String, CaseIterable, Codable, Sendable {
    case chrome = "Chrome", edge = "Edge", opera = "Opera", vivaldi = "Vivaldi"
}

/// The font set a Profile presents to `measureText`. The engine still has to be able to
/// produce the matching widths; until it does, non-macOS Profiles show a consistency hint.
public enum FontProfile: String, CaseIterable, Codable, Sendable {
    case macos26 = "macos26", macos15 = "macos15"
    case windows11 = "windows11", windows10 = "windows10", linux68 = "linux68"

    public var title: String {
        switch self {
        case .macos26: return "macOS 26 字体"
        case .macos15: return "macOS 15 字体"
        case .windows11: return "Windows 11 字体"
        case .windows10: return "Windows 10 字体"
        case .linux68: return "Linux 字体"
        }
    }

    public var platform: BrowserPlatform {
        switch self {
        case .macos26, .macos15: return .macOS
        case .windows11, .windows10: return .windows
        case .linux68: return .linux
        }
    }

    public static func `default`(for platform: BrowserPlatform, version: String = "") -> FontProfile {
        switch platform {
        case .macOS: return version.hasPrefix("15") ? .macos15 : .macos26
        case .windows: return version.hasPrefix("10.0") ? .windows10 : .windows11
        case .linux: return .linux68
        }
    }
}

public enum FingerprintAdjustment: String, CaseIterable, Codable, Sendable {
    case font, audio, canvas, clientRects = "clientrects", gpu

    public var title: String {
        switch self {
        case .font: return "字体"
        case .audio: return "音频"
        case .canvas: return "Canvas"
        case .clientRects: return "元素坐标"
        case .gpu: return "WebGL 参数"
        }
    }
}

public enum FingerprintField: String, CaseIterable, Hashable, Sendable {
    case seed, platform, platformVersion, brand, brandVersion, cpuCount, language, timeZone, adjustments

    public var title: String {
        switch self {
        case .seed: return "指纹种子"
        case .platform: return "平台"
        case .platformVersion: return "平台版本"
        case .brand: return "浏览器品牌"
        case .brandVersion: return "品牌版本"
        case .cpuCount: return "逻辑 CPU"
        case .language: return "语言"
        case .timeZone: return "时区"
        case .adjustments: return "指纹改写项"
        }
    }
}

public struct FingerprintSettings: Codable, Equatable, Sendable {
    public var seed: Int
    public var platform: BrowserPlatform? = nil
    public var platformVersion = ""
    public var brand: BrowserBrand? = nil
    public var brandVersion = ""
    public var cpuCount: Int? = nil
    public var language = ""
    public var timeZone = ""
    public var adjustments: Set<FingerprintAdjustment> = [.canvas, .clientRects]

    /// Ordered `navigator.languages`; `language` is the first entry when generated.
    public var languages: [String]? = nil
    public var screenWidth: Int? = nil
    public var screenHeight: Int? = nil
    public var availWidth: Int? = nil
    public var availHeight: Int? = nil
    public var colorDepth: Int? = nil
    public var deviceScaleFactor: Double? = nil
    /// `navigator.deviceMemory` as the engine reports it from the seed (see `EngineHardwareTable`);
    /// recorded for display, not passed to the engine.
    public var deviceMemory: Int? = nil
    public var touch: Bool? = nil
    public var fontProfile: FontProfile? = nil

    public init(seed: Int) {
        self.seed = seed
    }
}

extension FingerprintSettings {
    /// Only the seed is required: older versions wrote fewer fields. A value that only a newer
    /// version knows throws `NewerValue` rather than being dropped, so the row stays as written.
    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        seed = try data.decode(Int.self, forKey: .seed)
        platform = try data.decodeKnown(BrowserPlatform.self, forKey: .platform)
        platformVersion = try data.decodeIfPresent(String.self, forKey: .platformVersion) ?? ""
        brand = try data.decodeKnown(BrowserBrand.self, forKey: .brand)
        brandVersion = try data.decodeIfPresent(String.self, forKey: .brandVersion) ?? ""
        cpuCount = try data.decodeIfPresent(Int.self, forKey: .cpuCount)
        language = try data.decodeIfPresent(String.self, forKey: .language) ?? ""
        timeZone = try data.decodeIfPresent(String.self, forKey: .timeZone) ?? ""
        if let names = try data.decodeIfPresent([String].self, forKey: .adjustments) {
            adjustments = try Set(names.map { try NewerValue.known(FingerprintAdjustment.self, $0) })
        }
        languages = try data.decodeIfPresent([String].self, forKey: .languages)
        screenWidth = try data.decodeIfPresent(Int.self, forKey: .screenWidth)
        screenHeight = try data.decodeIfPresent(Int.self, forKey: .screenHeight)
        availWidth = try data.decodeIfPresent(Int.self, forKey: .availWidth)
        availHeight = try data.decodeIfPresent(Int.self, forKey: .availHeight)
        colorDepth = try data.decodeIfPresent(Int.self, forKey: .colorDepth)
        deviceScaleFactor = try data.decodeIfPresent(Double.self, forKey: .deviceScaleFactor)
        deviceMemory = try data.decodeIfPresent(Int.self, forKey: .deviceMemory)
        touch = try data.decodeIfPresent(Bool.self, forKey: .touch)
        fontProfile = try data.decodeKnown(FontProfile.self, forKey: .fontProfile)
    }
}

/// How the account behind a Profile is doing, recorded by the user to filter and batch-manage Profiles.
public enum AccountStatus: String, CaseIterable, Codable, Sendable {
    case active, verifying, limited, banned

    public var title: String {
        switch self {
        case .active: return "正常"
        case .verifying: return "待验证"
        case .limited: return "受限"
        case .banned: return "已封禁"
        }
    }
}

public struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    public static let defaultProxy = "127.0.0.1:7890"

    public var id: UUID
    public var name: String
    public var port: Int
    public var fingerprint: FingerprintSettings
    public var proxy: String
    /// Optional first-hop transit proxy for proxy chaining (e.g. local Clash `127.0.0.1:7890`).
    /// Empty means direct connection to `proxy`.
    public var transitProxy: String
    /// Free-form group shown in the sidebar; empty means ungrouped.
    public var group: String
    public var notes: String
    /// This Profile's own Passkey Box account; nil uses the account set in AnyBrowser.
    public var passkeyBox: PasskeyBoxAccount?
    public var launch: LaunchOptions
    /// Free-form labels for search (`tag:`) and batch actions.
    public var tags: [String]
    /// The account state the user recorded; nil when not set.
    public var accountStatus: AccountStatus?
    /// This Profile's Stripe device id, a lowercase UUIDv4 minted when the identity is created.
    /// `DeviceIdentity.effective` derives one from the seed when nil, so an older row still gets a
    /// stable value; "整套重新生成" clears it.
    public var deviceIdentity: String?

    public init(id: UUID = UUID(), name: String, port: Int, fingerprint: FingerprintSettings,
                proxy: String = BrowserProfile.defaultProxy, transitProxy: String = "",
                group: String = "", notes: String = "",
                passkeyBox: PasskeyBoxAccount? = nil, launch: LaunchOptions = LaunchOptions(),
                tags: [String] = [], accountStatus: AccountStatus? = nil,
                deviceIdentity: String? = nil) {
        self.id = id
        self.name = name
        self.port = port
        self.fingerprint = fingerprint
        self.proxy = proxy
        self.transitProxy = transitProxy
        self.group = group
        self.notes = notes
        self.passkeyBox = passkeyBox
        self.launch = launch
        self.tags = tags
        self.accountStatus = accountStatus
        self.deviceIdentity = deviceIdentity
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        id = try data.decode(UUID.self, forKey: .id)
        name = try data.decode(String.self, forKey: .name)
        port = try data.decode(Int.self, forKey: .port)
        fingerprint = try data.decode(FingerprintSettings.self, forKey: .fingerprint)
        proxy = try data.decodeIfPresent(String.self, forKey: .proxy) ?? Self.defaultProxy
        transitProxy = try data.decodeIfPresent(String.self, forKey: .transitProxy) ?? ""
        group = try data.decodeIfPresent(String.self, forKey: .group) ?? ""
        notes = try data.decodeIfPresent(String.self, forKey: .notes) ?? ""
        passkeyBox = try data.decodeIfPresent(PasskeyBoxAccount.self, forKey: .passkeyBox)
        launch = try data.decodeIfPresent(LaunchOptions.self, forKey: .launch) ?? LaunchOptions()
        tags = try data.decodeIfPresent([String].self, forKey: .tags) ?? []
        // A status written by a newer version reads as unset instead of hiding the Profile.
        accountStatus = (try? data.decodeIfPresent(AccountStatus.self, forKey: .accountStatus)) ?? nil
        deviceIdentity = try data.decodeIfPresent(String.self, forKey: .deviceIdentity)
    }

    /// Combined proxy route spec (`proxy` when unchained, or `transitProxy -> proxy` when chained).
    public var proxySpec: String {
        ProxyChain.spec(proxy: proxy, transitProxy: transitProxy)
    }

    /// Parsed proxy chain for this Profile, or nil when no proxy is configured.
    public func proxyChain(allowingSOCKSCredentials: Bool = true) throws -> ProxyChain? {
        try ProxyChain.parse(proxy: proxy, transitProxy: transitProxy,
                             allowingSOCKSCredentials: allowingSOCKSCredentials)
    }
}

public enum BrowserRunState: Equatable, Sendable {
    case stopped, starting, stopping
    case running(pid: Int32, port: Int, debugReady: Bool)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum ProfileError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

extension BrowserProfile {
    public static let maximumTags = 20

    /// Trimmed tags without duplicates (ignoring case), each at most 30 characters, without
    /// commas or control characters.
    public static func validatedTags(_ tags: [String]) throws -> [String] {
        var result: [String] = []
        for tag in tags {
            let text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard text.count <= 30, text.unicodeScalars.count <= 240, !text.contains(","),
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProfileError.invalid("标签最多 30 个字符，且不能包含逗号：\(text.prefix(30))")
            }
            if !result.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                result.append(text)
            }
        }
        guard result.count <= maximumTags else {
            throw ProfileError.invalid("每个 Profile 最多 \(maximumTags) 个标签。")
        }
        return result
    }

    public func validated() throws -> BrowserProfile {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Combining marks can stack without limit on one character, so scalars are bounded too,
        // generously enough for emoji sequences (up to 8 scalars per character).
        guard !result.name.isEmpty, result.name.count <= 80, result.name.unicodeScalars.count <= 640,
              !result.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalid("输入 1–80 字的 Profile 名称。")
        }
        guard (1024...65535).contains(port) else {
            throw ProfileError.invalid("调试端口须为 1024–65535。")
        }
        if let deviceIdentity = result.deviceIdentity, !DeviceIdentity.isValid(deviceIdentity) {
            throw ProfileError.invalid("设备标识须为小写 UUIDv4。")
        }
        // A platform or version change made outside the editor (imports, automation, tests)
        // must not keep a font set from the old identity. A Profile without a platform keeps
        // no font claim and is rejected by validation instead.
        if let platform = result.fingerprint.platform, result.fingerprint.fontProfile != nil {
            result.fingerprint.fontProfile = FontProfile.default(for: platform,
                                                                 version: result.fingerprint.platformVersion)
        }
        // The ordered language list must agree with the primary language field.
        if result.fingerprint.language.isEmpty {
            result.fingerprint.languages = nil
        } else if result.fingerprint.languages?.first != result.fingerprint.language {
            let primary = result.fingerprint.language
            let base = primary.split(separator: "-").first.map(String.init)
            result.fingerprint.languages = base == primary ? [primary]
                : [primary, base].compactMap { $0 }
        }
        try result.fingerprint.validate()
        result.proxy = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        result.transitProxy = transitProxy.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try ProxyChain.parse(proxy: result.proxy, transitProxy: result.transitProxy)
        result.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.group.count <= 40, result.group.unicodeScalars.count <= 320,
              !result.group.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileError.invalid("分组名称最多 40 个字符。")
        }
        guard notes.count <= 2000, notes.unicodeScalars.count <= 16000 else {
            throw ProfileError.invalid("备注最多 2000 个字符。")
        }
        result.passkeyBox = try passkeyBox?.validated()
        result.launch = try launch.validated()
        result.tags = try Self.validatedTags(tags)
        return result
    }

    /// Chromium arguments for this Profile. `extensions` are the unpacked extension directories
    /// it loads. Start URLs are not passed here; the runtime opens them once the browser is ready.
    /// `relayPort` is the port of the Profile's `ProxyRelay` on 127.0.0.1, which a proxy with
    /// credentials is reached through.
    public func launchArguments(userDataDirectory: URL, extensions: [URL] = [], relayPort: Int? = nil) -> [String] {
        var arguments = [
            "--user-data-dir=\(userDataDirectory.path)",
            "--remote-debugging-port=\(port)",
            "--no-first-run",
            "--no-default-browser-check",
            "--fingerprint=\(fingerprint.seed)",
            // The window's name in the Window and Dock menus, in place of the page title.
            "--window-name=\(name)",
        ]
        if let chain = try? ProxyChain.parse(proxy: proxy, transitProxy: transitProxy) {
            // The relay looks like a proxy without sign-in, and keeps host names for the upstream to resolve.
            if chain.needsRelay, let relayPort {
                arguments.append("--proxy-server=http://127.0.0.1:\(relayPort)")
            } else {
                arguments.append("--proxy-server=\(chain.exit.server)")
            }
            // A proxied Profile must not leak its real address through non-proxied UDP.
            arguments.append("--webrtc-ip-handling-policy=disable_non_proxied_udp")
        }
        arguments += fingerprint.arguments()
        if !extensions.isEmpty {
            // Chromium parses --load-extension as a comma-separated list.
            arguments.append("--load-extension=\(extensions.map(\.path).joined(separator: ","))")
        }
        arguments += launch.arguments()
        return arguments
    }
}

extension FingerprintSettings {
    /// The language the browser runs in: `language`, or else the first of `languages`.
    var primaryLanguage: String {
        language.isEmpty ? (languages?.first ?? "") : language
    }

    /// The Accept-Language list: the generated one, or the primary language and its base language.
    /// Empty without a primary language.
    var acceptLanguages: [String] {
        let primary = primaryLanguage
        guard !primary.isEmpty else { return [] }
        // A hand-edited primary language wins over a stale generated list.
        if let languages, languages.first == primary { return languages }
        let base = primary.split(separator: "-").first.map(String.init) ?? primary
        return base == primary ? [primary] : [primary, base]
    }

    /// The fingerprint switches after `--fingerprint=<seed>`.
    func arguments() -> [String] {
        var arguments: [String] = []
        if let platform {
            arguments.append("--fingerprint-platform=\(platform.rawValue)")
        }
        if !platformVersion.isEmpty {
            arguments.append("--fingerprint-platform-version=\(platformVersion)")
        }
        // The engine only reports Chromium in UA-CH when no brand is given, while every real Chrome
        // names Google Chrome in both the brand list and `sec-ch-ua`. A platform identity therefore
        // always carries the brand.
        let effectiveBrand = brand ?? (platform == nil ? nil : .chrome)
        if let effectiveBrand {
            arguments.append("--fingerprint-brand=\(effectiveBrand.rawValue)")
        }
        if !brandVersion.isEmpty {
            arguments.append("--fingerprint-brand-version=\(brandVersion)")
        }
        if let cpuCount {
            arguments.append("--fingerprint-hardware-concurrency=\(cpuCount)")
        }
        if !primaryLanguage.isEmpty {
            arguments.append("--lang=\(primaryLanguage)")
            arguments.append("--accept-lang=\(acceptLanguages.joined(separator: ","))")
        }
        if !timeZone.isEmpty {
            arguments.append("--timezone=\(timeZone)")
        }
        if let screenWidth {
            arguments.append("--fingerprint-screen-width=\(screenWidth)")
        }
        if let screenHeight {
            arguments.append("--fingerprint-screen-height=\(screenHeight)")
        }
        if let deviceScaleFactor {
            arguments.append("--fingerprint-device-scale-factor=\(String(format: "%g", deviceScaleFactor))")
        }
        // The engine has no Linux GPU values to spoof WebGL with; say so rather than rely on it.
        let disabled = FingerprintAdjustment.allCases.filter {
            !adjustments.contains($0) || ($0 == .gpu && platform == .linux)
        }
        if !disabled.isEmpty {
            arguments.append("--disable-spoofing=\(disabled.map(\.rawValue).joined(separator: ","))")
        }
        // `--lang` leaves ICU on the Mac's own languages, so Date strings, Intl defaults, Workers
        // and blob frames would show them. Cocoa reads `-AppleLanguages <plist>` from argv as a
        // user default. Chromium also takes the value for a start URL: the old-style `(de-DE)`
        // opened `http://(de-de)/` and sent that request through the proxy at every launch, while
        // the XML form is no valid URL and is dropped. A valid tag needs no XML escaping.
        if Self.isLanguageTag(primaryLanguage) {
            arguments += ["-AppleLanguages", "<array><string>\(primaryLanguage)</string></array>"]
        }
        return arguments
    }
}

extension FingerprintSettings {
    fileprivate func validate() throws {
        guard (1...Int(Int32.max)).contains(seed) else {
            throw ProfileError.invalid("指纹种子须为 1–2147483647 的整数。")
        }
        if let cpuCount, !(1...256).contains(cpuCount) {
            throw ProfileError.invalid("逻辑 CPU 数须为 1–256。")
        }
        for version in [platformVersion, brandVersion] where !version.isEmpty {
            guard version.range(of: #"^[0-9]{1,9}(\.[0-9]{1,9}){0,3}$"#, options: .regularExpression) == version.startIndex..<version.endIndex else {
                throw ProfileError.invalid("版本须由 1–4 段数字组成，例如 26.0.0。")
            }
        }
        if platform == nil, !platformVersion.isEmpty {
            throw ProfileError.invalid("先选择平台，再指定平台版本。")
        }
        if brand == nil, !brandVersion.isEmpty {
            throw ProfileError.invalid("先选择浏览器品牌，再指定品牌版本。")
        }
        if brand == .opera || brand == .vivaldi, brandVersion.isEmpty {
            throw ProfileError.invalid("Opera 和 Vivaldi 需要显式填写品牌版本。")
        }
        if !language.isEmpty, !Self.isLanguageTag(language) {
            throw ProfileError.invalid("输入有效的语言标签，例如 zh-CN 或 en-US。")
        }
        if !timeZone.isEmpty, !Self.isTimeZone(timeZone) {
            throw ProfileError.invalid("输入 IANA 时区，例如 Asia/Shanghai 或 UTC。")
        }
        if let languages {
            guard !languages.isEmpty else { throw ProfileError.invalid("语言列表不能为空。") }
            for value in languages where !Self.isLanguageTag(value) {
                throw ProfileError.invalid("输入有效的语言标签，例如 zh-CN 或 en-US。")
            }
        }
        for value in [screenWidth, screenHeight] {
            if let value, !(480...7680).contains(value) {
                throw ProfileError.invalid("屏幕尺寸须在 480–7680 之间。")
            }
        }
        for value in [availWidth, availHeight] {
            if let value, !(320...7680).contains(value) {
                throw ProfileError.invalid("可用屏幕尺寸须在 320–7680 之间。")
            }
        }
        if let screenWidth, let availWidth, availWidth > screenWidth {
            throw ProfileError.invalid("可用屏幕宽度不能大于屏幕宽度。")
        }
        if let screenHeight, let availHeight, availHeight > screenHeight {
            throw ProfileError.invalid("可用屏幕高度不能大于屏幕高度。")
        }
        if let colorDepth, colorDepth != 24, colorDepth != 30 {
            throw ProfileError.invalid("色深须为 24 或 30。")
        }
        if let deviceScaleFactor, !(1.0...3.0).contains(deviceScaleFactor) {
            throw ProfileError.invalid("设备像素比须在 1–3 之间。")
        }
        // The engine reports 8, 16 or 32 by seed; older versions saved any value from 1 to 8.
        if let deviceMemory, !((1...8).contains(deviceMemory) || deviceMemory == 16 || deviceMemory == 32) {
            throw ProfileError.invalid("设备内存须为 1–8、16 或 32 GB。")
        }
        if let fontProfile {
            guard let platform else {
                throw ProfileError.invalid("先选择平台，再指定字体表。")
            }
            if fontProfile.platform != platform {
                throw ProfileError.invalid("字体表与平台不匹配。")
            }
        }
    }

    /// A language tag such as zh-CN or en-US, as a whole.
    static func isLanguageTag(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) == text.startIndex..<text.endIndex
    }

    /// An IANA time zone this Mac knows, UTC, or a current IANA name that macOS lists only under
    /// its old spelling. `TimeZone(identifier:)` is not used: it also accepts PST and GMT+8.
    static func isTimeZone(_ text: String) -> Bool {
        TimeZone.knownTimeZoneIdentifiers.contains(text) || text == "UTC" || currentTimeZoneNames.contains(text)
    }

    /// Renamed zones exit-IP services report by their current name, while some macOS releases list
    /// only the old one (Asia/Calcutta, Europe/Kiev, America/Godthab, …).
    static let currentTimeZoneNames: Set<String> = [
        "Asia/Kolkata", "Europe/Kyiv", "Asia/Kathmandu", "Asia/Yangon", "Atlantic/Faroe", "America/Nuuk",
        "Asia/Ho_Chi_Minh", "Asia/Dhaka", "Asia/Thimphu", "Asia/Ulaanbaatar", "Africa/Asmara",
        "Pacific/Kanton", "Pacific/Chuuk", "Pacific/Pohnpei", "America/Ciudad_Juarez",
        "America/Argentina/Buenos_Aires", "America/Indiana/Indianapolis", "America/Kentucky/Louisville",
    ]

    mutating func randomize(_ fields: Set<FingerprintField>, excluding seeds: Set<Int>) {
        // Platform and brand are drawn with the whole-identity weights, so the field randomizer
        // ends up on the same engine-supported combinations; a kept field narrows the draw.
        if fields.contains(.platform) || fields.contains(.brand) {
            let keptPlatform = fields.contains(.platform) ? nil : platform
            let keptBrand = fields.contains(.brand) || brand == .opera || brand == .vivaldi ? nil : brand
            let preset = IdentitySampler.weightedPreset {
                (keptPlatform == nil || $0.platform == keptPlatform) && (keptBrand == nil || $0.brand == keptBrand)
            }
            if fields.contains(.platform) {
                platform = preset.platform
                // These values belonged to the old platform and cannot follow it.
                screenWidth = nil
                screenHeight = nil
                availWidth = nil
                availHeight = nil
                colorDepth = nil
                deviceScaleFactor = nil
                touch = false
            }
            if fields.contains(.brand) {
                brand = preset.brand
            }
        }
        // A version kept from the previous platform or brand would contradict the new one.
        if fields.contains(.platformVersion) || fields.contains(.platform) && !platformVersion.isEmpty {
            platformVersion = Self.randomPlatformVersion(for: platform)
        }
        if fields.contains(.platform), let platform {
            fontProfile = FontProfile.default(for: platform, version: platformVersion)
        } else if fields.contains(.platformVersion), let platform, fontProfile != nil {
            fontProfile = FontProfile.default(for: platform, version: platformVersion)
        }
        if fields.contains(.brandVersion) {
            brandVersion = Self.randomBrandVersion(for: brand, platform: platform)
        } else if fields.contains(.brand) {
            // Opera and Vivaldi have no engine default; an empty Chrome or Edge version follows the engine.
            brandVersion = brand == .opera || brand == .vivaldi || !brandVersion.isEmpty
                ? Self.randomBrandVersion(for: brand, platform: platform) : ""
        }
        // Language and time zone are one identity: randomizing either moves both.
        if fields.contains(.language) || fields.contains(.timeZone) {
            let locale = IdentitySampler.sampleLocale()
            language = locale.language
            timeZone = locale.timeZone
            languages = locale.languages
        }
        if fields.contains(.adjustments) {
            var next: Set<FingerprintAdjustment> = [.canvas, .clientRects]
            if let platform, platform != .linux { next.insert(.gpu) }
            if Bool.random() { next.insert(.audio) }
            // `.font` follows the platform in adaptToPlatform, which runs below.
            adjustments = next
        } else if fields.contains(.platform) {
            // A platform switch must also switch the GPU/font policies.
            if let platform {
                if platform == .linux { adjustments.remove(.gpu) } else { adjustments.insert(.gpu) }
            } else {
                adjustments.remove(.gpu)
            }
        }
        adaptToPlatform()

        // The seed fixes the GPU and memory, so hardware is settled last. A CPU count the user
        // keeps on the same platform gets a seed whose GPU ships with it; a new platform or seed
        // otherwise gets a CPU count of its own.
        let hardware = EngineHardwareTable.bundled
        let spoofsGPU = adjustments.contains(.gpu)
        let keepsCPU = !fields.contains(.cpuCount) && !fields.contains(.platform) && cpuCount != nil
        if fields.contains(.seed) {
            let taken = seeds.union([seed])
            seed = Self.newSeed(excluding: taken)
            if keepsCPU, spoofsGPU {
                for _ in 0..<64 where !hardware.exists(platform: platform, seed: seed, cpuCount: cpuCount) {
                    seed = Self.newSeed(excluding: taken)
                }
            }
        }
        if fields.contains(.cpuCount) || fields.contains(.platform) && cpuCount != nil {
            cpuCount = IdentitySampler.randomCPUCount(for: platform, seed: seed, spoofsGPU: spoofsGPU)
        }
        deviceMemory = hardware.deviceMemory(seed: seed)
    }

    /// Applies a validated locale from the proxy exit or the Mac itself.
    public mutating func apply(_ locale: IdentitySampler.LocaleHint) {
        language = locale.language
        timeZone = locale.timeZone
        languages = locale.languages
    }

    /// Drops what the platform cannot use: a version without a platform, and WebGL spoofing on Linux.
    public mutating func adaptToPlatform() {
        if platform == nil {
            platformVersion = ""
            // Engine-default identity is the host Mac; platform-specific claims cannot stand.
            fontProfile = nil
            adjustments.remove(.font)
            screenWidth = nil
            screenHeight = nil
            availWidth = nil
            availHeight = nil
            colorDepth = nil
            deviceScaleFactor = nil
        }
        // The engine reports memory by seed on every platform; a recorded value follows it.
        if deviceMemory != nil {
            deviceMemory = EngineHardwareTable.bundled.deviceMemory(seed: seed)
        }
        if platform == .linux {
            adjustments.remove(.gpu)
        }
        // A manually changed platform must not keep a font set from the old one, and a platform
        // without a table would silently read this Mac's fonts.
        if let platform {
            if fontProfile == nil || fontProfile?.platform != platform {
                fontProfile = FontProfile.default(for: platform, version: platformVersion)
            }
            adjustments.insert(.font)
            // A platform identity without a screen would report the host display.
            IdentitySampler.applyScreen(to: &self, for: platform)
        }
    }

    /// A released version of the platform, drawn through the presets' versions and weights.
    private static func randomPlatformVersion(for platform: BrowserPlatform?) -> String {
        guard let platform else { return "" }
        return IdentitySampler.weightedPreset { $0.platform == platform }.platformVersions.randomElement() ?? ""
    }

    private static func randomBrandVersion(for brand: BrowserBrand?, platform: BrowserPlatform?) -> String {
        switch brand {
        case .chrome:
            // The builds the engine itself picks from, all released for Windows and macOS;
            // .215 was released for macOS and Linux only.
            var builds = ["148.0.7778.217", "148.0.7778.179", "148.0.7778.168", "148.0.7778.97"]
            if platform != .windows { builds.append("148.0.7778.215") }
            let current = builds.filter { $0.hasPrefix("\(BundledVersions.engineMajor).") }
            return current.randomElement() ?? ""
        case .edge:
            // Given a version the engine sends it unreduced (Edg/148.0.3967.54), unlike real Edge;
            // left empty it picks a released build for UA-CH and sends Edg/148.0.0.0.
            return ""
        case .opera:
            // Opera numbers its releases 16 below the Chromium they are built on (Opera 132 on 148).
            return "\(BundledVersions.engineMajor - 16).0.0.0"
        case .vivaldi: return ["7.5", "7.6"].randomElement()!
        case nil: return ""
        }
    }

    /// A free seed for which a macOS identity can exist: the engine gives an Apple M4 (which ships
    /// with at least 16 GB) to even seeds and an M2 (at most 24 GB) to odd ones, and memory is
    /// `[8, 16, 32][seed % 3]`, so `seed % 6` 0 (M4, 8 GB) and 5 (M2, 32 GB) are skipped.
    /// A new free seed the engine maps to the same hardware as `seed`: copies and imports keep their
    /// CPU count, which must stay a real combination with the GPU and memory the seed selects.
    static func newSeed(excluding seeds: Set<Int>, sameHardwareAs seed: Int) -> Int {
        let period = EngineHardwareTable.bundled.hardwarePeriod
        let remainder = seed % period
        let steps = (Int(Int32.max) - remainder) / period
        var value: Int
        repeat {
            value = Int.random(in: 0...steps) * period + remainder
        } while value < 1 || seeds.contains(value)
        return value
    }

    static func newSeed(excluding seeds: Set<Int>) -> Int {
        let hardware = EngineHardwareTable.bundled
        var value: Int
        repeat {
            value = Int.random(in: 1...Int(Int32.max))
        } while seeds.contains(value) || !hardware.macOSSeedExists(value)
        return value
    }
}
