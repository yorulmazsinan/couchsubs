// SPDX-License-Identifier: AGPL-3.0-only

import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// İçe aktarılan dosyada atlanan kaydın nedeni (Windows, Android ve günlükte aynı adlar).
public enum GamePackSkipReason: String, CaseIterable, Sendable {
    /// İngilizce satırda harf ya da rakam yok, ya da hazır paketteki anahtar 16 haneli onaltılık sayı değil.
    case invalidKey
    /// Türkçesi boş ya da metin değil.
    case emptyTranslation
    /// SRT kaydı dört satır değil (numara, zaman, İngilizce, Türkçe), numara ya da zaman bozuk; TXT satırında ayraç yok.
    case malformedRecord
    /// Aynı İngilizce satır aynı Türkçeyle bir kez daha (kayıp değil, bir kez kurulur).
    case duplicate
    /// Aynı İngilizce satır farklı Türkçelerle: hangisinin doğru olduğu bilinmediğinden hiçbiri kurulmaz.
    case conflict

    /// Günlükteki adı.
    public var logName: String {
        switch self {
        case .invalidKey: "İngilizcesi ya da anahtarı geçersiz"
        case .emptyTranslation: "Türkçesi boş"
        case .malformedRecord: "biçimi bozuk"
        case .duplicate: "tekrar"
        case .conflict: "çakışan"
        }
    }
}

public struct GamePackImportPreview: Sendable {
    public let suggestedTitle: String?
    public let entries: [String: String]
    public let invalidCount: Int
    public let duplicateCount: Int
    public let conflictCount: Int
    /// Hazır paketin (biçim 2) cümle parçaları: çok cümleli satırların cümleleri (`GamePack.segments`).
    public let segments: [String: String]
    /// Atlanan kayıtlar, nedenine göre (sıfır olanlar yok).
    public let skipped: [GamePackSkipReason: Int]
    /// Hazır paketin OCR hatalarına dayanıklı arama verisi (`fuzzy` JSON nesnesi), pakete olduğu gibi yazılır.
    public let fuzzy: Data?
    /// Dosyada OCR'a dayanıklı arama verisi vardı ama kurulmayacak: bazı satırlar atlandığı için artık tutmuyor.
    public let fuzzyDropped: Bool

    init(suggestedTitle: String?, entries: [String: String], segments: [String: String] = [:],
         skipped: [GamePackSkipReason: Int], fuzzy: Data? = nil, fuzzyDropped: Bool = false) {
        self.suggestedTitle = suggestedTitle
        self.entries = entries
        self.segments = segments
        self.skipped = skipped.filter { $0.value > 0 }
        self.fuzzy = fuzzy
        self.fuzzyDropped = fuzzyDropped
        invalidCount = [GamePackSkipReason.invalidKey, .emptyTranslation, .malformedRecord].reduce(0) { $0 + (skipped[$1] ?? 0) }
        duplicateCount = skipped[.duplicate] ?? 0
        conflictCount = skipped[.conflict] ?? 0
    }

    /// Kurulacak satırlar (tam satırlar ve parçalar).
    public var acceptedCount: Int { entries.count + segments.count }

    /// Atlanan kayıtların toplamı.
    public var skippedCount: Int { skipped.values.reduce(0, +) }

    /// Günlük satırı (Windows ve Android ile aynı metin): kaç satır kabul edildi, kaçı neden atlandı.
    public func logLine(fileName: String) -> String {
        var line = "Paket içe aktarma (\(fileName)): \(acceptedCount) satır kabul edildi"
        if !segments.isEmpty { line += " (\(entries.count) tam satır, \(segments.count) parça)" }
        line += ", \(skippedCount) kayıt atlandı"
        let reasons = GamePackSkipReason.allCases.compactMap { reason in skipped[reason].map { "\($0) \(reason.logName)" } }
        if !reasons.isEmpty { line += " (" + reasons.joined(separator: ", ") + ")" }
        if fuzzy != nil { line += "; OCR'a dayanıklı arama verisi var" }
        if fuzzyDropped { line += "; OCR'a dayanıklı arama verisi atlanan satırlar yüzünden kurulmadı" }
        return line
    }

    /// Paket kurulunca günlüğe yazılan satır (Windows ve Android ile aynı metin).
    public func installLog(title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Paket kuruldu: \(title) (\(GamePackImporter.makeID(title: title))), \(acceptedCount) satır"
    }
}

public enum GamePackImporter {
    public enum ImportError: Error, Equatable {
        case unsupportedFileType, invalidUTF8, invalidJSON, unsupportedPackFormat
        case blankTitle, emptyPack, destinationExists, sourceIsDestination, fileTooLarge
    }

    /// Içe aktarılan çeviri dosyası için üst sınır (bellek taşmasını önler).
    public static let maxFileBytes = 64 * 1024 * 1024

    /// URL'den en çok `maxFileBytes` okur; sağlayıcı boyut bildirmese veya dosya okuma sırasında büyüse de belleği sınırlar.
    public static func read(fileAt url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        while true {
            let remaining = maxFileBytes - data.count + 1
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining))
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maxFileBytes else { throw ImportError.fileTooLarge }
        }
        return data
    }

    public static func parse(_ data: Data, fileName: String) throws -> GamePackImportPreview {
        guard data.count <= maxFileBytes else { throw ImportError.fileTooLarge }
        let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data
        guard let source = String(data: bytes, encoding: .utf8) else { throw ImportError.invalidUTF8 }

        var pairs = Pairs()
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "json":
            var segments = Pairs()
            var fuzzy: [String: Any]?
            let title = try parseJSON(bytes, into: &pairs, segments: &segments, fuzzy: &fuzzy)
            var skipped = pairs.skipped
            skipped.merge(segments.skipped, uniquingKeysWith: +)
            // OCR'a dayanıklı arama verisi paketteki bütün anahtarların sırasına bağlı: satır atlandıysa tutmaz.
            var kept: Data?
            if let fuzzy {
                let order = Set(pairs.entries.keys).union(segments.entries.keys).compactMap(PackKey.number).sorted()
                if PackFuzzyIndex(json: fuzzy, order: order) != nil {
                    kept = try? JSONSerialization.data(withJSONObject: fuzzy)
                }
            }
            return GamePackImportPreview(suggestedTitle: title, entries: pairs.entries, segments: segments.entries,
                                         skipped: skipped, fuzzy: kept, fuzzyDropped: fuzzy != nil && kept == nil)
        case "txt":
            parseText(lines(source), into: &pairs)
        case "srt":
            parseSRT(lines(source), into: &pairs)
        default:
            throw ImportError.unsupportedFileType
        }
        return GamePackImportPreview(suggestedTitle: nil, entries: pairs.entries, skipped: pairs.skipped)
    }

    public static func makeID(title: String) -> String {
        var slug: [UInt8] = []
        var gap = false
        for byte in title.utf8 {
            let letter: UInt8
            switch byte {
            case 65...90: letter = byte + 32
            case 97...122, 48...57: letter = byte
            default:
                gap = !slug.isEmpty
                continue
            }
            if slug.count + (gap ? 2 : 1) > 80 { break }
            if gap { slug.append(45) }
            slug.append(letter)
            gap = false
        }
        return "community-" + (slug.isEmpty ? "game" : String(decoding: slug, as: UTF8.self))
    }

    @discardableResult
    public static func install(_ preview: GamePackImportPreview, title: String, directory: URL, replacing: Bool,
                               sourceURL: URL? = nil) throws -> URL {
        guard let title = nonblank(title) else { throw ImportError.blankTitle }
        guard !preview.entries.isEmpty else { throw ImportError.emptyPack }
        let id = makeID(title: title)
        let destination = directory.appendingPathComponent(id + ".json")
        if let sourceURL, sameFile(sourceURL, destination) { throw ImportError.sourceIsDestination }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        try encoded(preview, id: id, title: title).write(to: temporary, options: .withoutOverwriting)
        // A link publishes the complete file and fails if the name already exists.
        // rename publishes the complete file while replacing the old name atomically.
        let failure = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return EINVAL }
                let result = replacing ? rename(source, target) : link(source, target)
                return result == 0 ? 0 : errno
            }
        }
        if !replacing, failure == EEXIST { throw ImportError.destinationExists }
        if failure != 0 { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        return destination
    }

    private static func sameFile(_ source: URL, _ destination: URL) -> Bool {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        if source.path == destination.path { return true }
        // The same file may have a different spelling on a case-insensitive volume.
        guard let sourceID = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let destinationID = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return sourceID.isEqual(destinationID)
    }

    private struct InstalledPack: Encodable {
        let format = 1
        let id: String
        let title: String
        let entries: [String: String]
    }

    /// Kurulacak paket dosyası: parça ya da OCR verisi yoksa biçim 1, varsa ikisini de taşıyan biçim 2 (`GamePack.decode`).
    private static func encoded(_ preview: GamePackImportPreview, id: String, title: String) throws -> Data {
        guard !preview.segments.isEmpty || preview.fuzzy != nil else {
            return try JSONEncoder().encode(InstalledPack(id: id, title: title, entries: preview.entries))
        }
        var object: [String: Any] = ["format": 2, "id": id, "title": title, "entries": preview.entries]
        if !preview.segments.isEmpty { object["segments"] = preview.segments }
        if let fuzzy = preview.fuzzy, let value = try? JSONSerialization.jsonObject(with: fuzzy) { object["fuzzy"] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private struct Pairs {
        var entries: [String: String] = [:]
        var counts: [GamePackSkipReason: Int] = [:]
        // Retain every distinct target for conflicted keys to count subsequent repeats.
        var conflicts: [String: Set<Data>] = [:]

        var skipped: [GamePackSkipReason: Int] {
            var result = counts
            result[.conflict] = conflicts.count
            return result
        }

        mutating func skip(_ reason: GamePackSkipReason) { counts[reason, default: 0] += 1 }

        mutating func add(key: String?, target: String?) {
            guard let key else { return skip(.invalidKey) }
            guard let target = GamePackImporter.nonblank(target) else { return skip(.emptyTranslation) }
            if conflicts[key] != nil {
                if !conflicts[key, default: []].insert(Data(target.utf8)).inserted { skip(.duplicate) }
            } else if let earlier = entries[key] {
                if earlier.utf8.elementsEqual(target.utf8) {
                    skip(.duplicate)
                } else {
                    conflicts[key] = [Data(earlier.utf8), Data(target.utf8)]
                    entries[key] = nil
                }
            } else {
                entries[key] = target
            }
        }
    }

    private static func nonblank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Hazır paket (biçim 1 ya da uygulamanın kendi paketleri gibi parça ve OCR verisi taşıyan biçim 2), `subtitles`
    /// zarfı ya da düz `{İngilizce: Türkçe}` nesnesi. Biçim 2 reddediliyordu: paket betiğiyle yapılan topluluk paketi
    /// hiç kurulamıyordu (#1355).
    private static func parseJSON(_ data: Data, into pairs: inout Pairs, segments: inout Pairs,
                                  fuzzy: inout [String: Any]?) throws -> String? {
        let object = try OrderedJSONObject.decode(data)
        let format = object["format"] as? NSNumber
        if let format, CFGetTypeID(format) != CFBooleanGetTypeID() {
            guard format == 1 || format == 2 else { throw ImportError.unsupportedPackFormat }
            guard let entries = OrderedJSONObject(object["entries"]) else { throw ImportError.invalidJSON }
            for (key, target) in entries.members { pairs.add(key: hashedKey(key), target: target as? String) }
            if format == 2 {
                if let parts = OrderedJSONObject(object["segments"]) {
                    for (key, target) in parts.members { segments.add(key: hashedKey(key), target: target as? String) }
                }
                if let value = OrderedJSONObject(object["fuzzy"]) {
                    fuzzy = Dictionary(value.members.map { ($0.name, $0.value) }, uniquingKeysWith: { _, later in later })
                }
            }
            return nonblank(object["title"] as? String) ?? nonblank(object["game"] as? String)
        }
        if OrderedJSONObject(object["entries"]) != nil { throw ImportError.unsupportedPackFormat }
        if let subtitles = OrderedJSONObject(object["subtitles"]) {
            for (source, target) in subtitles.members { pairs.add(key: PackKey.key(source), target: target as? String) }
            return nonblank(object["game"] as? String) ?? nonblank(object["title"] as? String)
        }
        for (source, target) in object.members { pairs.add(key: PackKey.key(source), target: target as? String) }
        return nil
    }

    private struct OrderedJSONObject {
        let members: [(name: String, value: Any)]

        init?(_ value: Any?) {
            guard let list = value as? [Any], list.first as? Bool == true, list.count % 2 == 1 else { return nil }
            members = stride(from: 1, to: list.count, by: 2).compactMap { index in
                guard let name = list[index] as? String else { return nil }
                return (name, list[index + 1])
            }
        }

        subscript(_ name: String) -> Any? {
            members.last { $0.name == name }?.value
        }

        static func decode(_ data: Data) throws -> Self {
            // First validate the original syntax, including colons and commas.
            // Foundation decodes objects as dictionaries. Decode a second time
            // with each object represented as [true, key, value, ...] to retain
            // every member. Input arrays carry a false tag so they stay distinct.
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
                  let value = try? JSONSerialization.jsonObject(with: orderedRepresentation(data)),
                  let object = Self(value) else {
                throw ImportError.invalidJSON
            }
            return object
        }

        private static func orderedRepresentation(_ data: Data) -> Data {
            var result = Data()
            result.reserveCapacity(data.count)
            var inString = false
            var escaped = false
            var afterTag = false
            for byte in data {
                if inString {
                    result.append(byte)
                    if escaped { escaped = false }
                    else if byte == UInt8(ascii: "\\") { escaped = true }
                    else if byte == UInt8(ascii: "\"") { inString = false }
                    continue
                }
                if afterTag {
                    switch byte {
                    case 0x20, 0x09, 0x0a, 0x0d: continue
                    case UInt8(ascii: "}"), UInt8(ascii: "]"): break
                    default: result.append(UInt8(ascii: ","))
                    }
                    afterTag = false
                }
                switch byte {
                case UInt8(ascii: "{"):
                    result.append(contentsOf: "[true".utf8)
                    afterTag = true
                case UInt8(ascii: "["):
                    result.append(contentsOf: "[false".utf8)
                    afterTag = true
                case UInt8(ascii: "}"): result.append(UInt8(ascii: "]"))
                case UInt8(ascii: ":"): result.append(UInt8(ascii: ","))
                case UInt8(ascii: "\""):
                    inString = true
                    result.append(byte)
                default: result.append(byte)
                }
            }
            return result
        }
    }

    private static func hashedKey(_ key: String) -> String? {
        guard key.utf8.count == 16,
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return key.lowercased()
    }

    private static func lines(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func parseText(_ lines: [String], into pairs: inout Pairs) {
        for line in lines {
            guard let trimmed = nonblank(line), !trimmed.hasPrefix("#") else { continue }
            let tabFields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if tabFields.count == 2 {
                pairs.add(key: PackKey.key(String(tabFields[0])), target: String(tabFields[1]))
            } else if tabFields.count == 1, let delimiter = line.range(of: " = ") {
                pairs.add(key: PackKey.key(String(line[..<delimiter.lowerBound])), target: String(line[delimiter.upperBound...]))
            } else {
                pairs.skip(.malformedRecord)
            }
        }
    }

    private static let timestamp = try! NSRegularExpression(pattern: #"\A[0-9]{2}:[0-5][0-9]:[0-5][0-9],[0-9]{3}\z"#)

    private static func validTiming(_ line: String) -> Bool {
        let times = line.components(separatedBy: " --> ")
        // Fixed widths make the chronological order the same as the string order.
        return times.count == 2 && times[0] < times[1] && times.allSatisfy {
            timestamp.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
    }

    private static func parseSRT(_ lines: [String], into pairs: inout Pairs) {
        var cue: [String] = []
        func finishCue() {
            guard !cue.isEmpty else { return }
            defer { cue.removeAll(keepingCapacity: true) }
            guard cue.count == 4, cue[0].utf8.allSatisfy({ (48...57).contains($0) }), validTiming(cue[1]) else {
                pairs.skip(.malformedRecord)
                return
            }
            pairs.add(key: PackKey.key(cue[2]), target: cue[3])
        }
        for line in lines {
            if let text = nonblank(line) { cue.append(text) } else { finishCue() }
        }
        finishCue()
    }
}

/// İçe aktarma önizlemesinde gösterilen atlama satırları ve OCR notu (Mac ve iPhone; metinler Localizable.xcstrings
/// anahtarları, Windows aynı anahtarları, Android strings.xml'deki karşılıklarını gösterir).
public enum PackImportReport {
    public struct Row: Equatable, Sendable {
        public let label: String
        public let count: Int
    }

    /// Satırı kurulmayan nedenler (sıfır olanlar yok); tekrar ve çakışma ayrı satırlarda gösterilir.
    public static func reasons(_ preview: GamePackImportPreview) -> [Row] {
        let labels: [(GamePackSkipReason, String)] = [
            (.invalidKey, "Skipped: no usable English line or key"),
            (.emptyTranslation, "Skipped: empty Turkish translation"),
            (.malformedRecord, "Skipped: malformed record"),
        ]
        return labels.compactMap { reason, label in preview.skipped[reason].map { Row(label: label, count: $0) } }
    }

    /// OCR'a dayanıklı arama verisi kuruluyorsa ya da atlanan satırlar yüzünden kurulamıyorsa not; yoksa nil.
    public static func fuzzyNote(_ preview: GamePackImportPreview) -> String? {
        if preview.fuzzyDropped {
            return "The OCR-tolerant matching data cannot be used because some lines were skipped; exact lines still work."
        }
        return preview.fuzzy == nil ? nil : "Includes OCR-tolerant matching data."
    }
}
