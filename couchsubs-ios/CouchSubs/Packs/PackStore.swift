// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// Sunucudaki paket listesi. Sözleşme: server/packs/README.md (Cloudflare Worker). İkisi de herkese açık, kimlik istemez:
/// `GET /v1/packs` liste, `GET /v1/packs/:id` paket (`packs/<id>.json.gz`); 404 paket yok.
struct PackManifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        /// Paketin sürümü (sunucuda artan bir sayı; yalnız gösterilir, karşılaştırma `sha256` ile).
        let version: String?
        /// İndirilen dosyanın (gövdenin) SHA-256'sı, küçük harf onaltılık.
        let sha256: String
        let size: Int?
        let entries: Int?

        init(id: String, title: String, version: String?, sha256: String, size: Int?, entries: Int?) {
            (self.id, self.title, self.version, self.sha256, self.size, self.entries) = (id, title, version, sha256, size, entries)
        }

        /// Sürüm sayı ya da metin olabilir.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            title = try values.decodeIfPresent(String.self, forKey: .title) ?? id
            if let number = try? values.decodeIfPresent(Int.self, forKey: .version) {
                version = String(number)
            } else {
                version = try values.decodeIfPresent(String.self, forKey: .version)
            }
            sha256 = try values.decode(String.self, forKey: .sha256)
            size = try values.decodeIfPresent(Int.self, forKey: .size)
            entries = try values.decodeIfPresent(Int.self, forKey: .entries)
        }
    }

    let packs: [Entry]
}

/// Oyun paketlerini sunucudan indirir (ücretsiz, herkese): liste, eksik ya da değişmiş paketi indirme, SHA-256 denetimi,
/// haftada bir yenileme. Paketler `files` klasörüne yazılır; `GamePackLibrary` uygulamayla gelenlerden sonra oradan okur,
/// aynı kimlikli indirilen paket uygulamayla gelenin yerine geçer.
actor PackStore {
    enum Failure: Error, Equatable {
        case server(Int)
        /// İndirilen dosyanın SHA-256'sı listedekiyle tutmuyor (dosya yazılmaz).
        case badChecksum(String)
        case badResponse
        case network
    }

    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    private let baseURL: URL
    private let directory: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    /// `directory`: paket önbelleği (Application Support/CouchSubs/Packs); `files` alt klasörü paketleri, `manifest.json`
    /// son listeyi tutar.
    init(baseURL: URL, directory: URL, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.directory = directory
        self.session = session
        self.now = now
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CouchSubs", isDirectory: true).appendingPathComponent("Packs", isDirectory: true)
    }

    /// `GamePackLibrary`'nin okuduğu klasör.
    nonisolated var filesDirectory: URL { Self.filesDirectory(in: directory) }

    static func filesDirectory(in directory: URL) -> URL { directory.appendingPathComponent("files", isDirectory: true) }
    private var manifestFile: URL { directory.appendingPathComponent("manifest.json") }
    private var refreshedFile: URL { directory.appendingPathComponent("refreshed") }

    /// Önbellekteki son liste (indirilmiş paketler).
    func cachedManifest() -> PackManifest? {
        (try? Data(contentsOf: manifestFile)).flatMap { try? JSONDecoder().decode(PackManifest.self, from: $0) }
    }

    var lastRefresh: Date? {
        (try? FileManager.default.attributesOfItem(atPath: refreshedFile.path)[.modificationDate]) as? Date
    }

    /// Son yenilemeden bu yana bir hafta geçti mi (ya da hiç yenilenmedi mi)?
    func needsRefresh() -> Bool {
        guard let lastRefresh else { return true }
        return now().timeIntervalSince(lastRefresh) >= Self.refreshInterval
    }

    /// Listeyi alır, eksik ya da değişmiş paketleri indirir, listede olmayanları siler. `force` false ise haftalık süre
    /// dolmadan hiçbir şey yapmaz. Dönen değer: indirilen (yeni ya da güncellenen) paket sayısı.
    @discardableResult
    func refresh(force: Bool = false) async throws -> Int {
        guard force || needsRefresh() else { return 0 }
        let manifest: PackManifest = try await fetch(path: "v1/packs").decoded()
        let manager = FileManager.default
        try manager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let previous = cachedManifest()
        var downloaded = 0
        for entry in manifest.packs {
            let file = packFile(entry.id)
            let unchanged = previous?.packs.first { $0.id == entry.id }?.sha256 == entry.sha256 && manager.fileExists(atPath: file.path)
            if unchanged { continue }
            let data = try await fetch(path: "v1/packs/\(entry.id)")
            guard Self.sha256(data) == entry.sha256.lowercased() else { throw Failure.badChecksum(entry.id) }
            try data.write(to: file, options: .atomic)
            downloaded += 1
        }
        // Sunucudan kalkan paket önbellekte de kalmasın.
        let wanted = Set(manifest.packs.map { packFile($0.id).lastPathComponent })
        for file in (try? manager.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)) ?? []
        where !wanted.contains(file.lastPathComponent) {
            try? manager.removeItem(at: file)
        }
        try JSONEncoder().encode(manifest).write(to: manifestFile, options: .atomic)
        if !manager.createFile(atPath: refreshedFile.path, contents: Data()) { throw Failure.badResponse }
        try manager.setAttributes([.modificationDate: now()], ofItemAtPath: refreshedFile.path)
        return downloaded
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func packFile(_ id: String) -> URL {
        // Kimlik dosya adına girer; sunucudan gelen değer yol olarak yorumlanmasın.
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filesDirectory.appendingPathComponent("\(safe).json.gz")
    }

    private func fetch(path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.network
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        default: throw Failure.server(http.statusCode)
        }
    }
}

private extension Data {
    func decoded<T: Decodable>() throws -> T {
        do { return try JSONDecoder().decode(T.self, from: self) } catch { throw PackStore.Failure.badResponse }
    }
}
