// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// Paket sunucusundaki (server/packs: `GET /v1/packs` = R2'deki index.json) bir paket.
public struct RemotePack: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let version: Int64
    public let sha256: String
    public let size: Int64?
    public let entries: Int?

    public init(id: String, title: String, version: Int64, sha256: String, size: Int64? = nil, entries: Int? = nil) {
        self.id = id
        self.title = title
        self.version = version
        self.sha256 = sha256
        self.size = size
        self.entries = entries
    }
}

/// Sunucudaki yeni ve güncellenen oyun paketleri (ücretsiz, hesapsız): Android'deki PackStore'un Mac ve iPhone karşılığı.
/// Liste alınır, değişen paket indirilir, SHA-256 ile doğrulanır ve paket klasörüne (`GamePackLibrary.userDirectory`)
/// konur; uygulamayla gelen aynı kimlikli paketin yerine geçer. Açılışta, günde bir ve yeni oyunda bakılır; sürümü değişmeyen paket yeniden
/// inmez, sunucudan kalkan paket silinir. Yarım ya da bozuk dosya hiç yüklenmez (önce geçici dosya, doğrulanınca yerine).
///
/// Klasörde kullanıcının kendi bıraktığı dosyalar da durur: sunucudan inmemiş (durum dosyasında olmayan ya da sonradan
/// değiştirilmiş) bir dosyanın üstüne yazılmaz, o dosya silinmez.
///
/// Sunucu adresi yapılandırmadan gelir (`configuredBaseURL`); adres yoksa özellik kapalıdır. Birincil adrese ulaşılamazsa
/// (ağ hatası, zaman aşımı, 5xx) yedek adres (`configuredFallbackURL`) denenir (`PackMirrors`). Windows'taki
/// CouchSubs.Core/PackUpdater.cs ile aynı kurallar.
public actor PackUpdater {
    /// Açılışta ve günde bir bakılır. Havuzdan her gece otomatik üretilen paketler (server/pool, `pool-<oyun kimliği>`)
    /// böylece en geç bir gün sonra gelir.
    public static let refreshInterval: TimeInterval = 24 * 3600
    /// PS5'te yeni bir oyun tanınınca son bakış bundan eskiyse hemen bakılır (o oyunun paketi yeni çıkmış olabilir).
    public static let gameCheckInterval: TimeInterval = 10 * 60
    /// Paket kimliği sunucudakiyle aynı biçimde (dosya adına girer; "../" gibi yollar baştan elenir).
    static let maxIdLength = 64
    /// Tek paket en çok bu kadar olabilir (bugünkü en büyük paket ~3 MB).
    static let maxPackBytes = 64 * 1024 * 1024

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public struct Installed: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// -1: bu paket son yenilemede inemedi (eski sürümü duruyor), sonraki açılışta yeniden denenir.
        public let version: Int64
        public let sha256: String
    }

    /// Yenilemenin sonucu: indirilen ve silinen paketler; `skipped` true ise süresi gelmediği için bakılmadı.
    public struct Refresh: Equatable, Sendable {
        public var downloaded: [String] = []
        public var removed: [String] = []
        public var skipped = false
        /// Liste alınamadı (ağ yok, sunucu kapalı); elde olanlar kaldı.
        public var failed = false

        public var changed: Bool { !downloaded.isEmpty || !removed.isEmpty }
    }

    private struct State: Codable {
        var checked: TimeInterval
        var packs: [Installed]
    }

    private struct Listing: Decodable {
        let packs: [RemotePack]
    }

    private let mirrors: PackMirrors
    private let directory: URL
    private let stateFile: URL
    private let fetch: Fetch
    private let clock: @Sendable () -> Date

    /// `directory`: paketlerin konacağı klasör (uygulamada `GamePackLibrary.userDirectory`); `stateFile` onun dışında
    /// durur ki paket gibi okunmasın. `fallbackURLs`: birincil adres ulaşılamazsa sırayla denenen yedekler.
    public init(baseURL: URL, fallbackURLs: [URL] = [], directory: URL, stateFile: URL,
                fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) },
                clock: @escaping @Sendable () -> Date = Date.init) {
        mirrors = PackMirrors(primary: baseURL, fallbacks: fallbackURLs)
        self.directory = directory
        self.stateFile = stateFile
        self.fetch = fetch
        self.clock = clock
    }

    /// Sunucu adresi: `COUCHSUBS_PACKS_URL` ortam değişkeni, `packsURL` ayarı ya da uygulamanın Info.plist'indeki
    /// `CSPacksBaseURL` (iPhone'daki gibi derleme ayarı `PACKS_API_BASE_URL`'den). Hiçbiri yoksa (bugünkü durum) nil:
    /// paket indirme kapalı kalır.
    public static func configuredBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                         defaults: UserDefaults = .standard, bundle: Bundle = .main) -> URL? {
        firstURL([environment["COUCHSUBS_PACKS_URL"], defaults.string(forKey: "packsURL"),
                  bundle.object(forInfoDictionaryKey: "CSPacksBaseURL") as? String])
    }

    /// Yedek adres (birincil adrese ulaşılamazsa): `COUCHSUBS_PACKS_FALLBACK_URL`, `packsFallbackURL` ayarı ya da Info.plist
    /// `CSPacksFallbackURL` (derleme ayarı `PACKS_API_FALLBACK_URL`). Yoksa nil: yalnız birincil adres kullanılır.
    public static func configuredFallbackURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                             defaults: UserDefaults = .standard, bundle: Bundle = .main) -> URL? {
        firstURL([environment["COUCHSUBS_PACKS_FALLBACK_URL"], defaults.string(forKey: "packsFallbackURL"),
                  bundle.object(forInfoDictionaryKey: "CSPacksFallbackURL") as? String])
    }

    /// İlk geçerli http(s) adresi; boş ya da doldurulmamış derleme değişkeni (`$(...)`) atlanır.
    public static func firstURL(_ candidates: [String?]) -> URL? {
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.hasPrefix("$("),
                  let url = URL(string: value), url.scheme == "https" || url.scheme == "http", url.host != nil else { continue }
            return url
        }
        return nil
    }

    /// Kurulu (sunucudan inmiş) paketler.
    public var installed: [Installed] { load().packs }

    /// Son başarılı bakışın zamanı (hiç bakılmadıysa nil).
    public var lastCheck: Date? {
        let checked = load().checked
        return checked > 0 ? Date(timeIntervalSince1970: checked) : nil
    }

    /// Son bakış `maxAge`'den eskiyse (ya da `force`) sunucuya bakar ve değişen paketleri indirir. Liste alınamazsa elde
    /// olanlar kalır; inemeyen paket sonraki açılışta yeniden denenir.
    public func refresh(force: Bool = false, maxAge: TimeInterval = PackUpdater.refreshInterval) async -> Refresh {
        let state = load()
        let now = clock()
        if !force, state.checked > 0, now.timeIntervalSince1970 - state.checked < maxAge,
           !state.packs.contains(where: { $0.version == -1 }) {
            return Refresh(skipped: true)
        }
        guard let remote = await list() else { return Refresh(failed: true) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var result = Refresh()
        var kept: [Installed] = []
        var retry = false
        for pack in remote where Self.isValidId(pack.id) && Self.isHex(pack.sha256) {
            let wanted = pack.sha256.lowercased()
            let existing = state.packs.first { $0.id == pack.id }
            let file = packFile(pack.id)
            let onDisk = Self.sha256(ofFile: file)
            if let existing, existing.version == pack.version, existing.sha256 == wanted, onDisk == wanted {
                kept.append(existing)
                continue
            }
            // Bizim indirmediğimiz (ya da indirdikten sonra değiştirilmiş) dosyaya dokunulmaz.
            if let onDisk, onDisk != existing?.sha256, onDisk != wanted { continue }
            guard let data = await download(pack.id), Self.sha256(data) == wanted else {
                retry = true
                if let existing, onDisk != nil {
                    kept.append(Installed(id: existing.id, title: existing.title, version: -1, sha256: existing.sha256))
                }
                continue
            }
            let temporary = directory.appendingPathComponent(".\(pack.id).download")
            do {
                try data.write(to: temporary, options: .atomic)
                if FileManager.default.fileExists(atPath: file.path) {
                    _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: file)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                if let existing, onDisk != nil {
                    kept.append(Installed(id: existing.id, title: existing.title, version: -1, sha256: existing.sha256))
                }
                continue
            }
            kept.append(Installed(id: pack.id, title: pack.title, version: pack.version, sha256: wanted))
            result.downloaded.append(pack.id)
        }

        // Sunucudan kalkan paket silinir (yalnız bizim indirdiğimiz ve değişmemişse).
        let remoteIds = Set(remote.map(\.id))
        for old in state.packs where !remoteIds.contains(old.id) {
            let file = packFile(old.id)
            if Self.sha256(ofFile: file) == old.sha256 { try? FileManager.default.removeItem(at: file) }
            result.removed.append(old.id)
        }
        // Yeni bir paket inemediyse kontrol zamanı ilerletilmez: sonraki açılışta yeniden denenir.
        save(State(checked: retry ? state.checked : now.timeIntervalSince1970, packs: kept))
        return result
    }

    /// Ayarlardan "indirilen paketleri sil": yalnız sunucudan inmiş ve değişmemiş dosyalar.
    public func clear() {
        for pack in load().packs {
            let file = packFile(pack.id)
            if Self.sha256(ofFile: file) == pack.sha256 { try? FileManager.default.removeItem(at: file) }
        }
        try? FileManager.default.removeItem(at: stateFile)
    }

    // MARK: - Ağ

    private func list() async -> [RemotePack]? {
        // Liste her bakışta sunucudan (yerel önbellek değil): yeni çıkan sürüm hemen görünsün (bkz. PackMirrors.get).
        guard let data = await get("v1/packs", cachePolicy: .reloadIgnoringLocalCacheData) else { return nil }
        return (try? JSONDecoder().decode(Listing.self, from: data))?.packs
    }

    private func download(_ id: String) async -> Data? {
        guard let data = await get("v1/packs/\(id)"),
              data.count <= Self.maxPackBytes else { return nil }
        return data
    }

    private func get(_ path: String, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async -> Data? {
        try? await mirrors.get(path, timeout: 60, cachePolicy: cachePolicy, fetch: fetch).get()
    }

    // MARK: - Disk

    private func packFile(_ id: String) -> URL { directory.appendingPathComponent("\(id).json.gz") }

    private func load() -> State {
        guard let data = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State(checked: 0, packs: [])
        }
        return state
    }

    private func save(_ state: State) {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateFile, options: .atomic) }
    }

    // MARK: - Yardımcılar

    /// Sunucudaki `^[a-z0-9][a-z0-9-]{0,63}$` ile aynı.
    static func isValidId(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= maxIdLength else { return false }
        let allowed: (Unicode.Scalar) -> Bool = { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        return scalars.allSatisfy(allowed) && scalars[0] != "-"
    }

    static func isHex(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(ofFile file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return sha256(data)
    }
}
