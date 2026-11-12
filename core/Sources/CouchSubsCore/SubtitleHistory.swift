// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Çevrilen altyazılar, en yenisi başta: bu oturumun ve önceki oturumların son `limit` satırı. Hızlı geçen bir satır
/// sonradan yeniden okunabilsin diye tutulur (ana ekrandaki liste ve "Geçmiş"). Uygulama küçük bir JSON dosyasına
/// yazar (`save(to:)`), açılışta okur (`load(from:)`). Windows'taki CouchSubs.Core/SubtitleHistory.cs ile aynı biçim.
public struct SubtitleHistory: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Codable, Sendable {
        public let id: Int
        /// Satırın çevrildiği an.
        public let date: Date
        public let source: String
        public let translation: String
        /// Oyun paketinden mi, çeviri motorundan mı geldi.
        public let origin: LineMetrics.Origin

        public init(id: Int, date: Date, source: String, translation: String, origin: LineMetrics.Origin) {
            self.id = id
            self.date = date
            self.source = source
            self.translation = translation
            self.origin = origin
        }
    }

    /// Varsayılan satır sayısı (dosya en çok ~200 KB olur).
    public static let defaultLimit = 200
    /// Bir satırın kaydedilen en uzun hâli (dosya şişmesin).
    public static let maxTextLength = 500

    public private(set) var entries: [Entry] = []
    public let limit: Int
    private var nextID = 0

    public init(limit: Int = SubtitleHistory.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// Yeni çeviriyi başa ekler. Aynı satırın yeniden okuması (benzer kaynak metin) yeni kayıt açmaz, son kaydı günceller.
    public mutating func add(source: String, translation: String, origin: LineMetrics.Origin = .engine, date: Date = Date()) {
        let translation = Self.clip(translation.trimmingCharacters(in: .whitespacesAndNewlines))
        let source = Self.clip(source)
        guard !translation.isEmpty else { return }
        if let last = entries.first,
           TextMatch.isSimilar(TextMatch.normalize(last.source), TextMatch.normalize(source)) {
            entries[0] = Entry(id: last.id, date: date, source: source, translation: translation, origin: origin)
            return
        }
        entries.insert(Entry(id: nextID, date: date, source: source, translation: translation, origin: origin), at: 0)
        nextID += 1
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// `date` anından (ör. oturumun başından) sonra çevrilen satırlar.
    public func entries(since date: Date) -> [Entry] {
        entries.filter { $0.date >= date }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    /// Satırlar düz metin olarak (kopyalamak için): her satırda saat, Türkçe ve İngilizcesi.
    public static func plainText(_ entries: [Entry], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { "[\(formatter.string(from: $0.date))] \($0.translation)\n\($0.source)" }.joined(separator: "\n\n")
    }

    // MARK: - Dosya

    /// ~/Library/Application Support/CouchSubs/history.json (iPhone'da uygulamanın kendi klasörü).
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("history.json")
    }

    private struct Stored: Codable {
        var version = 1
        var entries: [Entry]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Dosyadaki geçmiş; dosya yoksa ya da bozuksa boş geçmiş.
    public static func load(from file: URL, limit: Int = SubtitleHistory.defaultLimit) -> SubtitleHistory {
        var history = SubtitleHistory(limit: limit)
        guard let data = try? Data(contentsOf: file), let stored = try? decoder.decode(Stored.self, from: data) else { return history }
        history.entries = Array(stored.entries.prefix(history.limit))
        history.nextID = (history.entries.map(\.id).max() ?? -1) + 1
        return history
    }

    /// Geçmişi dosyaya yazar (yerine koyarak; yarım dosya kalmaz).
    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(Stored(entries: entries)).write(to: file, options: .atomic)
    }

    private static func clip(_ text: String) -> String {
        text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text
    }
}
