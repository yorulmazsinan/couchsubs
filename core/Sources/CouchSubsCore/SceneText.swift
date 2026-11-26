// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Oyun dünyasındaki yazı (tabela, tişört, plaka, afiş) altyazı alanına düşse de altyazı değildir. Alt bölge karenin
/// üçte birinden büyüktür (yükseklikte %35, genişlikte %72); GTA 6'da yürüyen karakterin tişörtü ya da sokaktaki tabela
/// o alana girince altyazı bloğu seçiliyor, ekranda altyazı yokken tek başına çevriliyordu (X bildirimleri, beta.73:
/// iPhone ve iPad). Altyazı bloğu seçilirken (`Reading.subtitleBlock`) şu bloklar atılır; konuşan adı taşıyan blok hep
/// altyazıdır:
/// - eğik satır (en az üç sözcük; perspektifli tabela: sözcüklerin dikey ortası satır boyunca tek yöne kayıyor ya da
///   satır kutusu sözcük boyunun `tiltedLineHeight` katından yüksek),
/// - düşük güvenli kısa blok (en çok `lowConfidenceWords` sözcük, ortalama güven `lowConfidence`'tan az),
/// - karenin ortasındaki kısa, noktalamasız tek satır (en çok üç sözcük; altyazı ve görev satırı karenin alt ya da üst
///   kenarına yakındır, `edgeBand`),
/// - plaka/tabela: alt alta kısa, büyük harfli satırlar (`isSign`) ve harfsiz sayı (`isNumber`); altyazının yerinde de,
/// - açık zemin üzerinde koyu yazı (kâğıt ilan, `InkTone`; görüntü verilince, `darkInk`); altyazının yerinde de.
///
/// Gerçek altyazı asla atılmaz (GitHub #822, beta.75 → beta.76: "çoğu zaman altyazı çevrilmiyor"): altyazısı karenin
/// alttan %22'lik şeridinin biraz üstünde duran oyunlarda (karenin %72–78'i) "Let's go", "Over here", "Yeah" gibi kısa
/// altyazıların hepsi "ortadaki kısa satır" sayılıp atılıyordu. Bu yüzden:
/// - altyazı biçimindeki blok (ortalanmış, alt şeritte, en az iki sözcük) düşük güvenle de atılmaz;
/// - bu oturumda kesin altyazı okunan yükseklikteki blok (`SubtitleBand`) yalnız eğikse atılır.
/// Atılan bloğun nedeni altyazı günlüğüne yazılır (`reason`).
/// Windows (SceneText.cs) ve Android (SceneText.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// Tests/CouchSubsCoreTests/Fixtures/scene-text.json.
public enum SceneText {
    /// Sözcüklerin dikey ortası ilk sözcükten sonuncuya bu kadar sözcük boyu kayarsa satır eğiktir.
    public static let tiltShift = 0.6
    /// Satır kutusu sözcüklerin ortanca boyunun bu katından yüksekse satır eğiktir.
    public static let tiltedLineHeight = 1.8
    public static let lowConfidence = 0.4
    public static let lowConfidenceWords = 5
    /// Kısa ve noktalamasız tek satır en çok bu kadar sözcüktür.
    public static let shortWords = 3
    /// Karenin alt ve üst kenarından bu kadarı (karenin yüksekliğine oranla) altyazı şerididir.
    public static let edgeBand = 0.22
    /// Ortalanmış sayılmak için bloğun yatay ortasının karenin ortasından en çok uzaklığı (`Reading.subtitleBlock` ile aynı).
    public static let centerTolerance = 0.12

    /// `block` bir sahne yazısı mı. Satır kutuları `area`'ya oranlıdır; `area` okunan alanın karedeki yeridir.
    public static func isSceneText(_ block: Reading, in area: TextBox, band: SubtitleBand = SubtitleBand()) -> Bool {
        reason(block, in: area, band: band) != nil
    }

    /// Blok sahne yazısıysa atılma nedeni (altyazı günlüğü için), değilse nil. `darkInk`: satır kutusu (okunan alanın
    /// görüntüsüne oranla) açık zeminde koyu yazı mı (`InkTone.sampler`); verilmezse renge bakılmaz.
    public static func reason(_ block: Reading, in area: TextBox, band: SubtitleBand = SubtitleBand(),
                              darkInk: ((TextBox) -> Bool)? = nil) -> String? {
        guard let first = block.lines.first, SpeakerPrefix.split(first.text) == nil else { return nil }
        let placed = block.lines.compactMap { $0.box?.placed(in: area) }
        guard placed.count == block.lines.count, let box = block.box?.placed(in: area) else { return nil }
        // Kâğıt ilan altyazının yerinde de atılır (GitHub #1124).
        if let darkInk, InkTone.isDarkBlock(block, dark: darkInk) { return InkTone.reason }
        let words = wordCount(block.text)
        let middle = (box.top + box.bottom) / 2
        // Plaka ve tabela altyazının yerinde de atılır (GitHub #1052).
        if isSign(block) { return "plaka/tabela (kısa büyük harfli satırlar)" }
        if isNumber(block.text) { return "harfsiz sayı" }
        // Bu oturumda altyazının okunduğu yükseklik: yalnız eğik tabela ve tuş simgeli menü eylemi atılır.
        let learned = band.contains(box)
        // Silah çarkı, mağaza ve menü satırı (GitHub #1285, #1293); rakamlı büyük harfli ad yalnız altyazının yüksekliği
        // dışında (beta.103 kaçan altyazı).
        if isMenuItem(block, learned: learned) { return menuItemReason }
        // Altyazı biçimi: ortalanmış, karenin alt şeridinde, en az iki sözcük.
        let subtitleLike = isCentered(box) && middle >= 1 - edgeBand && words >= 2
        if block.lines.contains(where: isTilted), !subtitleLike { return "eğik satır (tabela)" }
        if learned || subtitleLike { return nil }
        if let confidence = block.confidence, confidence < lowConfidence, words <= lowConfidenceWords {
            return "düşük tanıma güveni (\(String(format: "%.2f", confidence)))"
        }
        if block.lines.count == 1, words <= shortWords, !looksSpoken(first.text), middle > edgeBand, middle < 1 - edgeBand {
            return "karenin ortasında kısa satır"
        }
        return nil
    }

    static let menuItemReason = "menü/mağaza satırı (tuş simgeli eylem ya da rakamlı büyük harfli ad)"

    /// Silah çarkı, mağaza ve menü satırı (GitHub #1285, #1293; GTA 6, ekran yazısı çevirisi kapalıyken): altyazı alanına
    /// düşen "srow LONGARMS O TAKE AMMO", "SHOW SHIRT (1/3) A BUY O BU", "IN LJ TYPE 9 SMG" konuşma sanılıp bozuk
    /// çevriliyordu. Hiçbir satırı konuşma izi (`looksSpoken`: cümle sonu, virgül, tırnak) taşımayan blokta:
    /// - tuş simgesinin okunuşunun ("O", "X", "A", "•", simge) hemen ardından menü eylemi (`menuActions`: "BUY", "TAKE") ya da
    /// - küçük harfsiz, en az bir sözcüklü ve rakamlı yazı (ürün/silah adı, fiyat, sayaç: "TYPE 9 SMG", "1 555 0127").
    /// Konuşan adlı blok (`reason` onu hiç incelemez) ve noktalamalı bağırma ("GET DOWN!", "THREE OF THEM, 2 CARS!")
    /// altyazı kalır. Windows (SceneText.IsMenuItem) ve Android (isMenuItem) aynı.
    /// Rakamlı büyük harfli yazı yalnız kanıtla atılır (beta.103, iki kullanıcı: "bazı altyazıları kaçırıyor"): bu oturumda
    /// altyazının okunduğu yükseklikteyse (`learned`) ya da kişi zamiri taşıyorsa ("I NEED 50 GRAND") noktalamasız bağırma
    /// altyazıdır. Tuş simgesi + menü eylemi her yerde atılır.
    static func isMenuItem(_ block: Reading, learned: Bool = false) -> Bool {
        guard !block.lines.contains(where: { looksSpoken($0.text) }) else { return false }
        let tokens = block.lines.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        if zip(tokens, tokens.dropFirst()).contains(where: { isGlyph($0) && menuActions.contains($1) }) { return true }
        guard !learned, !tokens.contains(where: { pronouns.contains($0.replacingOccurrences(of: "’", with: "'")) }) else { return false }
        let text = block.text
        return text.contains(where: \.isUppercase) && !text.contains(where: \.isLowercase)
            && tokens.contains { $0.contains(where: \.isNumber) } && tokens.contains { $0.filter(\.isLetter).count >= 2 }
    }

    /// Büyük harfli konuşmanın kişi zamirleri: ürün, silah ve menü adında geçmez (`isMenuItem`).
    static let pronouns: Set<String> = [
        "I", "I'M", "I'LL", "I'VE", "I'D", "ME", "MY", "YOU", "YOU'RE", "YOUR", "WE", "WE'RE", "US", "OUR",
        "HE", "SHE", "HIM", "HER", "THEY", "THEM",
    ]

    /// Menünün tuş eylemleri ("△ BUY", "○ TAKE AMMO", "□ ADD TO TRUNK"); büyük harfle yazılır.
    static let menuActions: Set<String> = [
        "BUY", "SELL", "TAKE", "EQUIP", "ADD", "REMOVE", "RENAME", "DELETE", "CUSTOMIZE", "PREVIEW", "PURCHASE",
    ]

    /// Tuş simgesinin yazı tanımadaki okunuşu: "O" (○), "X" (✕), "A" (△) ya da harf ve rakam olmayan tek karakter
    /// ("•", "□", `ButtonIcons.marker`).
    /// Konuşmanın tiresi ("- TAKE IT EASY") tuş simgesi sayılmaz.
    static func isGlyph(_ token: String) -> Bool {
        if token == "O" || token == "X" || token == "A" { return true }
        return token.count == 1 && !token.contains(where: { $0.isLetter || $0.isNumber || "-–—".contains($0) })
    }

    /// Sözcük yerleri biliniyorsa satır eğik mi (perspektifli tabela, yan duran tişört). Altyazı yatay yazılır.
    static func isTilted(_ line: TextLine) -> Bool {
        guard let words = line.words, words.count >= 3, let box = line.box else { return false }
        let heights = words.map { $0.box.bottom - $0.box.top }.sorted()
        let median = heights[heights.count / 2]
        guard median > 0 else { return false }
        if box.bottom - box.top > tiltedLineHeight * median { return true }
        let middles = words.sorted { $0.box.left < $1.box.left }.map { ($0.box.top + $0.box.bottom) / 2 }
        let shift = middles.last! - middles.first!
        guard abs(shift) > tiltShift * median else { return false }
        // Tek yöne kayma: aradaki sözcükler geri dönmez (yazı tanımanın kutu oynaması sözcük boyunun %15'i kadar).
        let direction: Double = shift > 0 ? 1 : -1
        return zip(middles, middles.dropFirst()).allSatisfy { ($1 - $0) * direction >= -0.15 * median }
    }

    /// Plaka ya da tabela: en az iki satır ve her satır `isSignLine`; noktalama yalnız son satırın sonunda ve o satır tek
    /// sözcükse olabilir (yazı tanıma plakanın kenarını "." ya da "!" okuyor: "AKB / GLORIANA.", "AK8 / FLORIA!").
    /// Kullanıcı bildirimi (GitHub #1052, GTA 6, beta.84): plaka iki-üç satır okunduğu için tek satır kuralına
    /// takılmıyor, altyazının yerinde durduğu için de (`SubtitleBand`) çevriliyordu ("AKB / FLORIANA", "DISCOVER 28 /
    /// AKB / GLORIANA."). Altyazı satırı en çok üç sözcükken sarılmaz; kısa bağırma replikleri ("NO! / GET DOWN!")
    /// ilk satırda noktalama taşıdığı için kalır, konuşan adlı blok hep altyazıdır.
    static func isSign(_ block: Reading) -> Bool {
        guard block.lines.count >= 2, block.lines.allSatisfy({ isSignLine($0.text) }),
              block.lines.dropLast().allSatisfy({ !looksSpoken($0.text) }), let last = block.lines.last else { return false }
        return !looksSpoken(last.text) || wordCount(last.text) <= 1
    }

    /// Plaka/tabela satırı: kısa (en çok `signLineLength` harf ve en çok `shortWords` sözcük), küçük harfsiz, en az bir
    /// büyük harf; soru işareti, tire ile başlayan karşılıklı konuşma ve konuşan adı yok. Büyük/küçük harfi olmayan yazıya
    /// (Japonca) dokunulmaz.
    static func isSignLine(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard line.count <= signLineLength, line.contains(where: \.isUppercase), !line.contains(where: \.isLowercase),
              !line.contains("?"), let first = line.first, !"-–—".contains(first), SpeakerPrefix.split(line) == nil
        else { return false }
        return wordCount(line) <= shortWords
    }

    /// Plaka/tabela satırının en çok karakteri ("C118 DISCOVER 76").
    static let signLineLength = 20

    /// Harfsiz sayı ("82403610."): plaka numarası, sayaç; altyazı değildir.
    static func isNumber(_ text: String) -> Bool {
        !text.contains(where: \.isLetter) && text.contains(where: \.isNumber)
    }

    static func isCentered(_ box: TextBox) -> Bool { abs((box.left + box.right) / 2 - 0.5) <= centerTolerance }

    /// Konuşma izi: cümle sonu noktalaması, virgül, noktalı virgül ya da tırnak.
    static func looksSpoken(_ text: String) -> Bool {
        SubtitleStabilizer.endsSentence(text) || text.contains(where: { ",;\"“”".contains($0) })
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }.count
    }
}

/// Bu oturumda kesin altyazı okunan yükseklikler (karenin yüksekliğine oranla). Altyazı her oyunda kendi yerinde durur;
/// orada okunan kısa satır ("Let's go") tabela sayılmaz (`SceneText.reason`). Kesin altyazı: ortalanmış, sahne yazısı
/// sayılmayan ve en az dört sözcüklü, konuşma noktalamalı ya da konuşan adlı blok. Hat sıfırlanınca unutulur
/// (Windows: SubtitleBand, Android: SubtitleBand).
public struct SubtitleBand: Equatable, Sendable {
    /// En çok bu kadar yükseklik hatırlanır (en eskisi düşer).
    public static let capacity = 6
    /// Kesin altyazı sayılmak için en az sözcük (noktalaması ya da konuşan adı yoksa).
    public static let sureWords = 4

    struct Span: Equatable, Sendable {
        var top: Double
        var bottom: Double
        var line: Double
    }

    private(set) var spans: [Span] = []

    public init() {}

    /// Hatırlanan yüksekliğin her yanındaki pay (satır boyuna oranla). GTA 6'da görev satırı ("Follow the plane") altyazının
    /// hemen altında belirir; pencere kaynağında orta noktası bir satır payının hemen dışında kalıyor, tek başına geldiğinde
    /// "karenin ortasında kısa satır" sayılıp atılıyordu (gerçek kare pencere-kare-2-gorev).
    public static let margin = 1.5

    /// Bu oturumda hiç altyazı yüksekliği öğrenilmedi.
    public var isEmpty: Bool { spans.isEmpty }

    /// Kutunun (karede) dikey ortası hatırlanan bir altyazı yüksekliğine (`margin` satır boyu payla) düşüyor mu.
    public func contains(_ box: TextBox) -> Bool {
        let middle = (box.top + box.bottom) / 2
        return spans.contains { middle >= $0.top - Self.margin * $0.line && middle <= $0.bottom + Self.margin * $0.line }
    }

    /// Seçilen altyazı bloğu kesin altyazıysa yüksekliği hatırlanır. Satır kutuları `area`'ya oranlıdır.
    public mutating func record(_ block: Reading, in area: TextBox) {
        guard let first = block.lines.first, let box = block.box?.placed(in: area), SceneText.isCentered(box) else { return }
        let sure = SpeakerPrefix.split(first.text) != nil || SceneText.wordCount(block.text) >= Self.sureWords
            || block.lines.contains { SceneText.looksSpoken($0.text) }
        guard sure, !SceneText.isSceneText(block, in: area) else { return }
        let span = Span(top: box.top, bottom: box.bottom, line: (box.bottom - box.top) / Double(block.lines.count))
        if let index = spans.firstIndex(where: { abs($0.top - span.top) < span.line / 2 && abs($0.bottom - span.bottom) < span.line / 2 }) {
            spans.remove(at: index)
        }
        spans.append(span)
        if spans.count > Self.capacity { spans.removeFirst(spans.count - Self.capacity) }
    }

    public mutating func reset() { spans = [] }
}
