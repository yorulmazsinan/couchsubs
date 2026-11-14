// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// "Ekranı çevir": karenin tamamı bir kez okunur, yazılar yerlerine göre gruplara ayrılır (menü, görev paneli, bilgi
/// kutusu, altyazı...) ve her grup ayrı çevrilir. TV her çeviriyi kendi İngilizce yazısının üstüne, o yazının
/// boyutunda koyar (Windows: CouchSubs.Core/ScreenTranslation.cs ile aynı kurallar).
public enum ScreenTranslation {
    /// Ekrandaki bir yazı grubu.
    public struct Group: Equatable, Sendable {
        /// Ayrı ayrı çevrilecek parçalar (başlık, cümle, menü satırı...).
        public var paragraphs: [String]
        /// Karedeki yeri, kenarlara oranla.
        public var box: TextBox
        /// Satırlarının tipik yüksekliği, karenin yüksekliğine oranla; TV yazı boyunu buna göre seçer.
        public var lineHeight: Double
    }

    public struct Item: Equatable, Sendable {
        public var source: String
        /// Parçaların çevirisi, her parça ayrı satırda.
        public var translation: String
        public var box: TextBox
        public var lineHeight: Double

        public init(source: String, translation: String, box: TextBox, lineHeight: Double) {
            self.source = source
            self.translation = translation
            self.box = box
            self.lineHeight = lineHeight
        }

        /// Birden çok parça var: TV satır satır, sola yaslı gösterir.
        public var paragraphs: Bool { translation.contains("\n") }
    }

    /// Kalabalık ekranda TV'yi kutuyla doldurmamak ve çeviriyi uzatmamak için en çok bu kadar grup çevrilir.
    public static let maxGroups = 30

    /// Grupları sırayla çevirir; her grup çevrilince o ana kadarki sonuçlarla `progress` çağrılır. Çevirisi aslıyla
    /// aynı olan (ad, sayı, zaten Türkçe yazı) grup gösterilmez.
    public static func translate(_ reading: Reading, using translate: (String) async throws -> String,
                                 progress: ([Item]) -> Void = { _ in }) async throws -> [Item] {
        var items: [Item] = []
        for group in groups(reading) {
            try Task.checkCancellation()
            var translated: [String] = []
            for paragraph in group.paragraphs { translated.append(try await translate(paragraph)) }
            guard let item = item(group, translated) else { continue }
            items.append(item)
            progress(items)
        }
        return items
    }

    /// Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün parçaları birlikte gider ve sonuç bir
    /// kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir.
    public static func translate(_ reading: Reading, using translator: TextTranslator,
                                 progress: ([Item]) -> Void = { _ in }) async throws -> [Item] {
        guard translator.translatesTogether else {
            return try await translate(reading, using: { try await translator.translate($0) }, progress: progress)
        }
        let groups = groups(reading)
        let paragraphs = groups.flatMap(\.paragraphs)
        guard !paragraphs.isEmpty else { return [] }
        let translations = try await translator.translateAll(paragraphs)
        try Task.checkCancellation()
        var items: [Item] = []
        var next = 0
        for group in groups {
            let count = group.paragraphs.count
            let translated = (next..<next + count).map { $0 < translations.count ? translations[$0] : paragraphs[$0] }
            next += count
            if let item = item(group, translated) { items.append(item) }
        }
        if !items.isEmpty { progress(items) }
        return items
    }

    /// Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) nil.
    private static func item(_ group: Group, _ translations: [String]) -> Item? {
        var changed = false
        let texts = zip(group.paragraphs, translations).map { paragraph, translation in
            var text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = paragraph }
            changed = changed || !TextMatch.isSimilar(TextMatch.normalize(paragraph), TextMatch.normalize(text), threshold: 0.90)
            return text
        }
        guard changed else { return nil }
        return Item(source: group.paragraphs.joined(separator: "\n"), translation: texts.joined(separator: "\n"),
                    box: group.box, lineHeight: group.lineHeight)
    }

    /// Satırları gruplara toplar. Kumanda ipuçları ve yazı tanıma çöpleri atılır; harfi olmayan ya da tek harfli satırlar
    /// ("23m", "9", "+") göstergedir, çevrilmez. Bir satır, üstündeki satırın hemen altındaysa, yatayda onunla üst üste
    /// biniyorsa ve yazı boyu benziyorsa o gruba katılır. Gruplar yukarıdan aşağı, en çok `maxGroups`.
    public static func groups(_ reading: Reading) -> [Group] {
        let lines = reading.withoutButtonPrompts().withoutOcrNoise().lines
            .filter { $0.box != nil && isWords($0.text) }
            .sorted { $0.box!.top < $1.box!.top }
        var groups: [[TextLine]] = []
        for line in lines {
            if let index = groups.lastIndex(where: { belongs(line.box!, below: $0.last!.box!) }) {
                groups[index].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.prefix(maxGroups).map { group in
            let heights = group.map { $0.box!.bottom - $0.box!.top }.sorted()
            let box = group.dropFirst().reduce(group[0].box!) { $0.union($1.box!) }
            return Group(paragraphs: paragraphs(group), box: box, lineHeight: heights[heights.count / 2])
        }
    }

    /// Alt satır üsttekinin hemen altında (arada satır yüksekliğinin %80'inden az), yatayda onunla üst üste ve yazı boyu benzer.
    private static func belongs(_ lower: TextBox, below upper: TextBox) -> Bool {
        let a = upper.bottom - upper.top, b = lower.bottom - lower.top
        guard max(a, b) <= min(a, b) * 1.6 else { return false }
        guard lower.top - upper.bottom < max(a, b) * 0.8, lower.top >= upper.top else { return false }
        let overlap = min(lower.right, upper.right) - max(lower.left, upper.left)
        let narrower = min(lower.right - lower.left, upper.right - upper.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /// Önceki parça cümleyi bitirdiyse ya da kısa bir başlık/menü satırıysa (en çok üç sözcük, virgülsüz) ve yeni satır
    /// büyük harfle başlıyorsa yeni parça başlar; yoksa satır öncekinin devamıdır (cümle iki satıra sarılmış).
    static func paragraphs(_ lines: [TextLine]) -> [String] {
        var result: [String] = []
        for line in lines.map({ $0.text.trimmingCharacters(in: .whitespaces) }) {
            if let previous = result.last, !startsNew(after: previous, line) {
                result[result.count - 1] += " " + line
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func startsNew(after previous: String, _ line: String) -> Bool {
        if SubtitleStabilizer.endsSentence(previous) { return true }
        return line.first?.isUppercase == true && wordCount(previous) <= 3 && !previous.hasSuffix(",")
    }

    /// En az iki harfi ve iki harfli bir sözcüğü olan satır yazıdır; geri kalanı sayı ve simgedir.
    static func isWords(_ text: String) -> Bool {
        text.filter(\.isLetter).count >= 2 && text.split(whereSeparator: \.isWhitespace).contains { $0.filter(\.isLetter).count >= 2 }
    }

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// Çevirilerin TV'de kalma süresi (ms): yazı çoksa daha uzun; tuşa yeniden basınca hemen kalkar.
    public static func displayMilliseconds(_ items: [Item]) -> Int {
        min(60000, max(12000, 8000 + items.reduce(0) { $0 + $1.translation.count } * 50))
    }
}
