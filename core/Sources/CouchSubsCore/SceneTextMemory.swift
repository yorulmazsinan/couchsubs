// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Az önce sahne yazısı sayılıp atılan satır (plaka, tabela, telefon mesajı) bir sonraki karede başka okununca altyazı
/// olmaz. Altyazı kapısı (`SceneText`, `Reading.subtitleBlock`, telefon süzgeci) her kareye ayrı karar verir; yazı
/// tanıma aynı tabelayı kare kare başka okuduğu için bir karede atılan yazı ötekinde kuralın dışında kalıp çevriliyordu.
/// Kullanıcı bildirimi (#1411, GTA 6, Mac, beta-105, "Ekran yazılarını otomatik çevir" ve telefon okuması kapalı):
/// plakanın "GOOD TIME STATE" yazısı çoğu karede "plaka/tabela" sayılıp atılıyor, "NECE / & COCOTIME STATE O." okunan
/// karede ise çevrilip altyazı kutusunda gösteriliyordu; telefon bir karede bulunup mesajı atıldıktan sonra telefon
/// ıskalanınca aynı mesaj ("Once you're truly zen, the") altyazı olarak çevriliyordu; sola yaslı sohbet mesajı da
/// ("Yo Jason, Lucia, where y'all") bir karede "menü açıklaması" sayılıp ötekinde çevriliyordu. Ayarların kapalı olması
/// yalnız ayrı kutuları kapatıyordu; altyazı yoluna sızan yazı bu kapıdan geçiyordu.
///
/// Bu yüzden güvenilir nedenle (`remembers`) atılan satırlar `holdMs` boyunca hatırlanır; okumadaki satır onlardan birine
/// `similarity` oranında benziyorsa altyazı bloğu seçilmeden çıkarılır. Gerçek konuşmayı düşürmemek için:
/// - kamerayla kayan yazı (`SceneMotion`), düşük güven, ortadaki kısa satır, ürün yazısı ve menü listesi hatırlanmaz
///   (bunlar konuşmayı da bir kare atabiliyor);
/// - kısa satır (`minLetters` harften az: "Yeah.", "BOB") ne hatırlanır ne çıkarılır; `exactLetters` harften kısa satır
///   yalnız harfleri birebir aynıysa çıkarılır ("BOB RU" plakası "Bob, run!" konuşmasını götürmez);
/// - konuşan adlı satır hiç çıkarılmaz;
/// - süre her atılışta tazelenir, çıkarılan satır süreyi uzatmaz.
/// Windows (SceneTextMemory.cs) ve Android (SceneTextMemory.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// Tests/CouchSubsCoreTests/Fixtures/scene-text-memory.json.
public struct SceneTextMemory {
    /// Atılan satır bu kadar süre hatırlanır (son atılışından).
    public static let holdMs = 8000
    /// Boşluklar dışında en az bu kadar harf/rakamlı satır hatırlanır ve karşılaştırılır.
    public static let minLetters = 5
    /// Bu kadar harften kısa satırlar yalnız harfleri (boşluksuz) birebir aynıysa aynı yazı sayılır.
    public static let exactLetters = 10
    /// Sadeleştirilmiş iki satırın Levenshtein benzerliği bu orandan azsa aynı yazı sayılmaz.
    public static let similarity = 0.75
    /// En çok bu kadar satır hatırlanır (en eskisi düşer).
    public static let capacity = 40
    /// Telefonun ekranında okunup atılan satırın nedeni.
    public static let phoneReason = "telefon yazısı"
    /// Günlükte atılma nedeni (ardından ilk atılışın nedeni yazılır).
    public static let reason = "az önce sahne yazısı sayılan satırın yeniden okunuşu"

    /// Hatırlanan nedenler: konuşmayı atmayan kurallar.
    static let remembered: Set<String> = [
        SceneText.signReason, SceneText.numberReason, SceneText.plateNumberReason, SceneText.menuItemReason,
        SceneText.tiltedReason, InkTone.reason, Reading.offBandReason, phoneReason,
    ]

    struct Entry: Equatable {
        var text: String
        var reason: String
        var seenAt: Int
    }

    private var entries: [Entry] = []
    /// Son `filter` çağrısında çıkarılan satırlar ve ilk atılışlarının nedeni (günlük için).
    public private(set) var removed: [(line: TextLine, reason: String)] = []

    public init() {}

    /// Bu nedenle atılan satır hatırlanır mı.
    public static func remembers(_ reason: String) -> Bool { remembered.contains(reason) }

    /// Atılan satırları hatırlar (`reason` hatırlanan nedenlerden değilse hiçbir şey yapmaz). `time`: milisaniye saati.
    public mutating func remember(_ lines: [String], reason: String, at time: Int) {
        guard Self.remembers(reason) else { return }
        for line in lines {
            let key = TextMatch.normalize(line)
            guard Self.isLongEnough(key) else { continue }
            entries.removeAll { $0.text == key }
            entries.append(Entry(text: key, reason: reason, seenAt: time))
        }
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Okumanın az önce atılan satırlara benzeyenleri çıkarılmış hali.
    public mutating func filter(_ reading: Reading, at time: Int) -> Reading {
        removed = []
        entries.removeAll { time - $0.seenAt > Self.holdMs || time < $0.seenAt }
        guard !entries.isEmpty else { return reading }
        var kept: [TextLine] = []
        for line in reading.lines {
            if let entry = match(line.text) {
                removed.append((line, entry.reason))
            } else {
                kept.append(line)
            }
        }
        return removed.isEmpty ? reading : Reading(lines: kept)
    }

    /// Satırın benzediği hatırlanan satır (en yenisi); yoksa nil.
    func match(_ text: String) -> Entry? {
        guard SpeakerPrefix.split(text) == nil else { return nil }
        let key = TextMatch.normalize(text)
        guard Self.isLongEnough(key) else { return nil }
        let letters = Self.letters(key)
        return entries.last { entry in
            let other = Self.letters(entry.text)
            if letters.count < Self.exactLetters || other.count < Self.exactLetters { return letters == other }
            return TextMatch.isSimilar(key, entry.text, threshold: Self.similarity)
        }
    }

    /// Bu nedenle hatırlanan satırları unutur (oyunun altyazısı koyu yazı sayılınca `InkTone.reason`).
    public mutating func forget(reason: String) {
        entries.removeAll { $0.reason == reason }
    }

    public mutating func reset() {
        entries = []
        removed = []
    }

    static func isLongEnough(_ key: String) -> Bool { letters(key).count >= minLetters }

    static func letters(_ key: String) -> String { key.filter { $0 != " " } }
}
