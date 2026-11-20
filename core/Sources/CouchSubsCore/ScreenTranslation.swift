// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
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
        /// Her parçadaki kumanda simgeleri, parçadaki `ButtonIcons.marker` sırasıyla; simge yoksa nil.
        public var icons: [[IconSlot]]? = nil
    }

    public struct Item: Equatable, Sendable {
        public var source: String
        /// Parçaların çevirisi, her parça ayrı satırda.
        public var translation: String
        public var box: TextBox
        public var lineHeight: Double
        /// Çevirinin içindeki kumanda simgeleri (kareden kesilmiş); TV `translation`'ın o yerine koyar.
        public var icons: [IconPlacement]?
        public var style: PhoneTextStyle?
        /// Otomatik ekran yazısında özgün yazının görünüşü; TV ve masaüstü çeviriyi bu stilde çizer.
        public var look: TextLook?

        public init(source: String, translation: String, box: TextBox, lineHeight: Double, icons: [IconPlacement]? = nil) {
            self.source = source
            self.translation = translation
            self.box = box
            self.lineHeight = lineHeight
            self.icons = icons
        }

        /// Birden çok parça var: TV satır satır, sola yaslı gösterir.
        public var paragraphs: Bool { translation.contains("\n") }
    }

    /// Kalabalık ekranda TV'yi kutuyla doldurmamak ve çeviriyi uzatmamak için en çok bu kadar grup çevrilir; fazlası
    /// olunca en az yazısı olanlar (tek sözcüklük etiketler) bırakılır.
    public static let maxGroups = 30

    /// Grupları sırayla çevirir; her grup çevrilince o ana kadarki sonuçlarla `progress` çağrılır. Çevirisi aslıyla
    /// aynı olan (ad, sayı, zaten Türkçe yazı) grup gösterilmez. `frame` okunan kareyse yazıların içindeki kumanda
    /// simgeleri ondan kesilip çeviriye konur; simgelerin yeri çeviride uydurma adlarla korunur (`IconText`).
    public static func translate(_ reading: Reading, using translate: (String) async throws -> String,
                                 frame: CGImage? = nil, progress: ([Item]) -> Void = { _ in }) async throws -> [Item] {
        var items: [Item] = []
        for group in withImages(groups(reading, frame: frame), from: frame) {
            try Task.checkCancellation()
            let prepared = group.paragraphs.map(IconText.protect)
            var translated: [String] = []
            for paragraph in prepared { translated.append(try await translate(paragraph.text)) }
            guard let item = item(group, prepared, translated) else { continue }
            items.append(item)
            progress(items)
        }
        return items
    }

    /// Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün parçaları birlikte gider ve sonuç bir
    /// kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir. `frame`: bkz. yukarıdaki `translate`.
    public static func translate(_ reading: Reading, using translator: TextTranslator, frame: CGImage? = nil,
                                 progress: ([Item]) -> Void = { _ in }) async throws -> [Item] {
        guard translator.translatesTogether else {
            return try await translate(reading, using: { try await translator.translate($0) }, frame: frame, progress: progress)
        }
        let groups = withImages(groups(reading, frame: frame), from: frame)
        let prepared = groups.map { group in group.paragraphs.map(IconText.protect) }
        let paragraphs = prepared.flatMap { list in list.map { $0.text } }
        guard !paragraphs.isEmpty else { return [] }
        let translations = try await translator.translateAll(paragraphs)
        try Task.checkCancellation()
        var items: [Item] = []
        var next = 0
        for (index, group) in groups.enumerated() {
            let count = group.paragraphs.count
            let translated = (next..<next + count).map { $0 < translations.count ? translations[$0] : "" }
            next += count
            if let item = item(group, prepared[index], translated) { items.append(item) }
        }
        if !items.isEmpty { progress(items) }
        return items
    }

    /// Simgelerin resimleri kareden kesilir; kare yoksa gruplar olduğu gibi kalır (simge okunan haliyle yazılır).
    static func withImages(_ groups: [Group], from frame: CGImage?) -> [Group] {
        guard let frame else { return groups }
        return groups.map { group in
            guard let icons = group.icons else { return group }
            var cut = group
            cut.icons = icons.map { ButtonIcons.withImages($0, frame: frame) }
            return cut
        }
    }

    /// Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) nil. Boş çeviride parçanın
    /// aslı gösterilir; simgeler TV'de çevirinin içindeki yerlerine konur.
    static func item(_ group: Group, _ prepared: [IconText.Protected], _ translations: [String]) -> Item? {
        var changed = false
        var texts: [String] = []
        var slots: [IconSlot] = []
        for (index, paragraph) in group.paragraphs.enumerated() {
            let translated = (index < translations.count ? translations[index] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = translated.isEmpty ? IconText.indexed(paragraph, offset: slots.count)
                : IconText.restore(translated, names: index < prepared.count ? prepared[index].names : [], offset: slots.count)
            changed = changed || !TextMatch.isSimilar(TextMatch.normalize(IconText.plain(paragraph)),
                                                      TextMatch.normalize(IconText.plain(text)), threshold: 0.90)
            texts.append(text)
            if let all = group.icons, index < all.count { slots += all[index] }
        }
        guard changed else { return nil }
        let rendered = IconText.render(texts.joined(separator: "\n"), slots: slots)
        return Item(source: group.paragraphs.map(IconText.plain).joined(separator: "\n"), translation: rendered.text,
                    box: group.box, lineHeight: group.lineHeight, icons: rendered.icons.isEmpty ? nil : rendered.icons)
    }

    /// Satırları gruplara toplar. Yazının içindeki kumanda simgeleri işaretlenir (`ButtonIcons`); kumanda ipuçları ve
    /// yazı tanıma çöpleri atılır; harfi olmayan ya da tek harfli satırlar ("23m", "9", "+") göstergedir, çevrilmez. Bir
    /// satır, üstündeki satırın hemen altındaysa, yatayda onunla üst üste biniyorsa ve yazı boyu benziyorsa o gruba
    /// katılır; küçük harfle başlayan satır üstteki bitmemiş cümleye katılır (`continues`). Gruplar yukarıdan aşağı; en çok
    /// `maxGroups`, en çok yazısı olanlar.
    public static func groups(_ reading: Reading, frame: CGImage? = nil, keepIdentifiers: Bool = false) -> [Group] {
        var marked = reading.withButtonIcons()
        // Tam ekranda yalnız aksi halde atılacak kısa ipuçlarında simgeyi görüntüden doğrula.
        if let frame {
            marked = Reading(lines: marked.lines.map { line in
                (line.icons ?? []).isEmpty && ButtonPrompts.isPrompt(line.text) ? ButtonIcons.markFree(line, frame: frame) : line
            })
        }
        let lines = marked.withoutButtonPrompts().withoutOcrNoise(keepIdentifiers: keepIdentifiers).lines
            .filter { $0.box != nil && isWords($0.text) }
            .sorted { $0.box!.top < $1.box!.top }
        return groups(from: lines)
    }

    /// Kutuları bilinen, süzülmüş ve sıralı satırları yeniden işaretlemeden gruplar.
    static func groups(from lines: [TextLine]) -> [Group] {
        var groups: [[TextLine]] = []
        for line in lines {
            if let index = groups.lastIndex(where: { belongs(line.box!, below: $0.last!.box!) }),
               !bridgesColumns(groups[index].last!.box!, line.box!, lines),
               !bridgesColumns(line.box!, groups[index].last!.box!, lines) {
                groups[index].append(line)
            } else if let index = groups.lastIndex(where: { continues(line, above: $0.last!) }) {
                // Küçük harfle başlayan satır, üstündeki bitmemiş cümlenin devamıdır: satır aralığı biraz geniş ya da
                // yanında başka bir yazı olsa da o gruba katılır. Ayrı grup olunca yarım cümle tek başına çevriliyor ya da
                // grup sınırına takılıp hiç çevrilmiyordu; bilgi kutusunun son satırı İngilizce kalıyordu.
                groups[index].append(line)
            } else {
                groups.append([line])
            }
        }
        return busiest(groups).map { group in
            let heights = group.map { $0.box!.bottom - $0.box!.top }.sorted()
            let box = group.dropFirst().reduce(group[0].box!) { $0.union($1.box!) }
            let icons = paragraphIcons(group)
            return Group(paragraphs: paragraphs(group), box: box, lineHeight: heights[heights.count / 2],
                         icons: icons.contains(where: { !$0.isEmpty }) ? icons : nil)
        }
    }

    /// Kalabalık ekranda en çok yazısı olan `maxGroups` grup, yukarıdan aşağı sırasıyla. Önceden en üstteki gruplar
    /// alınıyordu: menü ve gösterge etiketleri sınırı doldurunca ekranın alt yarısındaki bilgi kutusu hiç çevrilmiyordu.
    private static func busiest(_ groups: [[TextLine]]) -> [[TextLine]] {
        guard groups.count > maxGroups else { return groups }
        let letters = groups.map { group in group.reduce(0) { $0 + $1.text.filter(\.isLetter).count } }
        let kept = groups.indices.sorted { letters[$0] != letters[$1] ? letters[$0] > letters[$1] : $0 < $1 }.prefix(maxGroups)
        return kept.sorted().map { groups[$0] }
    }

    /// Alt satır, üstteki satırın bitmemiş cümlesini sürdürüyor: küçük harfle başlıyor, üstteki cümle sonu işaretiyle
    /// bitmiyor, yazı boyu benzer, yatayda üst üste ve arada satır yüksekliğinin bir buçuk katından az boşluk var.
    private static func continues(_ lower: TextLine, above upper: TextLine) -> Bool {
        guard let first = lower.text.first(where: \.isLetter), first.isLowercase,
              !SubtitleStabilizer.endsSentence(upper.text.trimmingCharacters(in: .whitespaces)),
              let below = lower.box, let above = upper.box else { return false }
        let a = above.bottom - above.top, b = below.bottom - below.top
        guard max(a, b) <= min(a, b) * 1.6 else { return false }
        guard below.top - above.bottom < max(a, b) * 1.5, below.top >= above.top else { return false }
        let overlap = min(below.right, above.right) - max(below.left, above.left)
        let narrower = min(below.right - below.left, above.right - above.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    // Geniş başlık/alt satır iki bağımsız sütundan birine katılmasın. Filtrelenmiş OCR satırlarına bakılır.
    private static func bridgesColumns(_ wide: TextBox, _ column: TextBox, _ lines: [TextLine]) -> Bool {
        lines.contains { line in
            let peer = line.box!
            guard min(column.right, peer.right) <= max(column.left, peer.left) else { return false }
            let rowOverlap = min(column.bottom, peer.bottom) - max(column.top, peer.top)
            guard rowOverlap > 0, rowOverlap >= min(column.bottom - column.top, peer.bottom - peer.top) * 0.5 else { return false }
            return (belongs(column, below: wide) && belongs(peer, below: wide))
                || (belongs(wide, below: column) && belongs(wide, below: peer))
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

    /// `paragraphs` ile aynı bölmede her parçanın kumanda simgeleri, metindeki sırasıyla.
    static func paragraphIcons(_ lines: [TextLine]) -> [[IconSlot]] {
        var texts: [String] = []
        var result: [[IconSlot]] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let icons = line.icons ?? []
            if let previous = texts.last, !startsNew(after: previous, text) {
                texts[texts.count - 1] += " " + text
                result[result.count - 1] += icons
            } else {
                texts.append(text)
                result.append(icons)
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
