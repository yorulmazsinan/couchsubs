// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Ücretsiz çevirinin terim sözlüğü (Windows: CouchSubs.Core/Glossary.cs, aynı biçim ve kurallar). Dosya biçimi:
/// `{ "game": "God of War", "terms": { "Leviathan Axe": "Leviathan Baltası" }, "keep": ["Kratos", "Atreus"] }`.
/// `terms` İngilizce terimi verilen Türkçeyle değiştirir, `keep` adları olduğu gibi bırakır. Eşleşme büyük/küçük harfe
/// bakmaz, yalnız tam sözcüklerde olur, uzun terim önce gelir ("Leviathan Axe", "Axe"dan önce).
/// `keepExact` da adları bırakır ama yalnız yazıldığı gibi (büyük/küçük harf aynı) geçince: aynı zamanda sıradan bir
/// sözcük olan adlar için ("Soul" kahramanın adıyken "soul" ruh demek; Phantom Blade Zero).
/// Uygulamayla gelen genel sözlüğün üstüne kullanıcının klasöründeki `*.json` dosyaları eklenir (ad sırasıyla;
/// aynı terimde sonraki dosya kazanır).
public final class Glossary: @unchecked Sendable {
    /// Metinde bulunan terim: konumu (UTF-16), sözlükteki İngilizcesi ve Türkçesi.
    public struct TermMatch: Equatable, Sendable {
        public var start: Int
        public var length: Int
        public var english: String
        public var turkish: String
    }

    public enum ParseError: Error { case notAnObject }

    /// Sözlükte yazıldığı gibi İngilizce, Türkçe; `exact` ise yalnız aynı büyük/küçük harfle eşleşir.
    typealias Term = (english: String, turkish: String, exact: Bool)
    /// Küçük harfli İngilizce → terim.
    private let terms: [String: Term]
    /// Uzundan kısaya terimler; arama bu sırayla yapılır.
    private let ordered: [Term]

    /// Büyük harfle kalması gereken sözcükler (küçük harfle); `normalizeCase`'e ad olarak verilir.
    public let capitalWords: Set<String>
    /// Sözlüğün içeriğinden kısa bir iz; terim içeren satırların önbellek anahtarına girer, sözlük değişince yeniden çevrilir.
    public let fingerprint: String

    public static let empty = Glossary(terms: [:])

    /// Uygulamayla gelen genel oyun terimleri (Resources/glossary-en-tr.json; Windows da aynı dosyayı gömer).
    public static let builtIn: Glossary = {
        guard let url = Bundle.module.url(forResource: "glossary-en-tr", withExtension: "json"),
              let data = try? Data(contentsOf: url), let glossary = try? Glossary.parse(data) else { return .empty }
        return glossary
    }()

    private init(terms: [String: Term]) {
        self.terms = terms
        ordered = terms.values.sorted { $0.english.utf16.count != $1.english.utf16.count
            ? $0.english.utf16.count > $1.english.utf16.count : $0.english < $1.english }
        var words: Set<String> = []
        // `keepExact` adları sıradan sözcük de olduğundan büyük harfe çevrilmez ("I SOLD MY SOUL" → "soul").
        for term in ordered where !term.exact && term.english.contains(where: \.isUppercase) {
            // Sözlükte büyük harfle yazılmış terimler ad sayılır: tümü büyük harfli cümlede de büyük harfle kalır.
            for word in term.english.split(separator: " ") where word.count >= 2 { words.insert(word.lowercased()) }
        }
        capitalWords = words
        fingerprint = Self.makeFingerprint(ordered)
    }

    public var count: Int { terms.count }
    public var isEmpty: Bool { terms.isEmpty }

    /// Terimin Türkçesi; yoksa nil.
    public func turkish(_ english: String) -> String? { terms[Self.collapse(english).lowercased()]?.turkish }

    /// JSON sözlük dosyasını okur; biçim bozuksa hata atar.
    public static func parse(_ data: Data) throws -> Glossary {
        guard let root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        var terms: [String: Term] = [:]
        if let map = root["terms"] as? [String: Any] {
            // Sözlük sırası JSON'da tanımsız; aynı sonucu vermek için anahtar sırasıyla eklenir.
            for key in map.keys.sorted() { if let value = map[key] as? String { add(&terms, key, value) } }
        }
        if let keep = root["keep"] as? [Any] {
            for case let name as String in keep { add(&terms, name, name) }
        }
        if let keep = root["keepExact"] as? [Any] {
            for case let name as String in keep { add(&terms, name, name, exact: true) }
        }
        return Glossary(terms: terms)
    }

    public static func parse(_ json: String) throws -> Glossary { try parse(Data(json.utf8)) }

    private static func add(_ terms: inout [String: Term], _ english: String, _ turkish: String, exact: Bool = false) {
        let english = collapse(english)
        let turkish = collapse(turkish)
        // Harfsiz terim her yerde eşleşirdi; yer tutucu sayısı sınırlı olduğundan çok uzun terim de alınmaz.
        guard english.contains(where: \.isLetter), !turkish.isEmpty, english.utf16.count <= 80 else { return }
        terms[english.lowercased()] = (english, turkish, exact)
    }

    /// Sözlükleri birleştirir; aynı terimde sonraki kazanır.
    public static func merge(_ glossaries: [Glossary]) -> Glossary {
        var terms: [String: Term] = [:]
        for glossary in glossaries { terms.merge(glossary.terms) { _, new in new } }
        return Glossary(terms: terms)
    }

    /// Genel sözlük ve klasördeki `*.json` dosyaları; okunamayan ya da bozuk dosya atlanır.
    public static func load(directory: URL?) -> Glossary {
        var all = [builtIn]
        for file in userFiles(in: directory) {
            if let data = try? Data(contentsOf: file), let glossary = try? parse(data) { all.append(glossary) }
        }
        return merge(all)
    }

    static func userFiles(in directory: URL?) -> [URL] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// Metindeki terimler: büyük/küçük harfe bakmadan (`keepExact` adları bakarak), tam sözcük, uzun terim önce; çakışan
    /// kısa terim alınmaz.
    /// Sonuç metindeki sıraya göredir.
    public func find(_ text: String) -> [TermMatch] {
        guard !ordered.isEmpty, !text.isEmpty else { return [] }
        let string = text as NSString
        var found: [TermMatch] = []
        for term in ordered {
            var start = 0
            while start < string.length {
                let range = string.range(of: term.english, options: term.exact ? [.literal] : [.caseInsensitive],
                                         range: NSRange(location: start, length: string.length - start))
                guard range.location != NSNotFound else { break }
                let end = range.location + range.length
                if Self.isBoundary(string, range.location - 1), Self.isBoundary(string, end),
                   !found.contains(where: { range.location < $0.start + $0.length && $0.start < end }) {
                    found.append(TermMatch(start: range.location, length: range.length, english: term.english, turkish: term.turkish))
                }
                start = range.location + 1
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    public func matches(_ text: String) -> Bool { !find(text).isEmpty }

    private static func isBoundary(_ string: NSString, _ index: Int) -> Bool {
        guard index >= 0, index < string.length, let scalar = UnicodeScalar(string.character(at: index)) else { return true }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// FNV-1a (32 bit), terimler İngilizcesine göre sıralı; Windows'ta da aynı hesap.
    private static func makeFingerprint(_ terms: [Term]) -> String {
        var hash: UInt32 = 2_166_136_261
        for term in terms.sorted(by: { $0.english.lowercased().utf8.lexicographicallyPrecedes($1.english.lowercased().utf8) }) {
            // `exact` işareti yalnız varsa eklenir; eski sözlüklerin izi değişmez.
            for byte in (term.english.lowercased() + "\u{1}" + term.turkish + (term.exact ? "\u{3}" : "") + "\u{2}").utf8 {
                hash = (hash ^ UInt32(byte)) &* 16_777_619
            }
        }
        return "g" + String(format: "%08x", hash)
    }
}

/// Kullanıcı sözlük klasörünü izler: dosyalar değişince (ad, boyut, değişiklik zamanı) sözlük yeniden okunur.
/// Klasöre en çok birkaç saniyede bir bakılır; her altyazıda diske gidilmez.
public final class GlossaryStore: @unchecked Sendable {
    static let checkEvery: TimeInterval = 5

    private let directory: URL?
    private let clock: () -> Date
    private let lock = NSLock()
    private var current: Glossary?
    private var stamp = ""
    private var checkedAt = Date.distantPast

    /// `directory`: kullanıcı sözlüklerinin klasörü; nil ise yalnız genel sözlük.
    public init(directory: URL?, clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.clock = clock
    }

    /// ~/Library/Application Support/CouchSubs/Glossary
    public static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CouchSubs", isDirectory: true)
            .appendingPathComponent("Glossary", isDirectory: true)
    }

    /// Yalnız uygulamayla gelen sözlük (testler).
    public static func builtInOnly() -> GlossaryStore { GlossaryStore(directory: nil) }

    public var glossary: Glossary {
        lock.withLock {
            let now = clock()
            if let current, now.timeIntervalSince(checkedAt) < Self.checkEvery { return current }
            checkedAt = now
            let newStamp = makeStamp()
            if current == nil || newStamp != stamp {
                current = Glossary.load(directory: directory)
                stamp = newStamp
            }
            return current!
        }
    }

    private func makeStamp() -> String {
        Glossary.userFiles(in: directory).map { file -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(file.path)|\(size)|\(modified)"
        }.joined(separator: "\n")
    }
}
