// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// CouchSubs'ın gösterdiği çeviriler: okunan karede kendi altyazımız varsa yeni satır sayılmasın. Kullanıcı bildirimi (X,
/// capture card + OBS ile yayın): görüntü kaynağı OBS'in Program/Önizleme projektörüyken karede CouchSubs'ın OBS katmanı
/// (tarayıcı kaynağı) da vardır. Türkçe altyazı İngilizce satırın üstüne düşünce (örtme ya da alttaki sabit yer) yazı
/// tanıma onu okuyor, hat onu yeni satır sanıp yeniden çeviriyor ("Çeviri: Çeviri: …"), sonra İngilizce yeniden görünüp
/// eski çeviri geri geliyordu; altyazı yanıp sönüyordu. Ayrı yerde duran Türkçe satır İngilizce bloğa katılıyordu.
///
/// Kural: gösterilen çeviri ekranda kaldıkça (ve kalktıktan sonra `textGraceMs`) okunan bir satır ona benziyorsa
/// (yazı tanımanın Türkçe harfleri düz harfe çevirdiği hâliyle, bkz. `PoolFilter.fold`) ya da onun bir parçasıysa
/// (katman uzun çeviriyi satırlara böler) "kendi altyazısı" sayılır, atılır. Kaynağına (İngilizce satıra) benzeyen okuma
/// hiçbir zaman atılmaz (adlar ve çevrilmeyen kısa satırlar). Kendi altyazısı bir kez metinden tanınınca okunduğu yer
/// öğrenilir; çeviri ekrandayken o dikdörtgene düşen öbür satırlar da (yazı tanımanın metni tanınmayacak kadar bozduğu
/// parçalar) atılır. OBS'i okumayan kurulumda (PS5/Xbox akışı, telefon) karede bizim altyazımız yoktur; süzgeç bir şey
/// atmaz. Windows (OwnSubtitles.cs) ve Android (OwnSubtitles.kt) aynı kuralları uygular. İş parçacığı güvenlidir.
public final class OwnSubtitles: @unchecked Sendable {
    /// Çeviri kalktıktan sonra metin eşleşmesi bu kadar süre geçerli (OBS projektörünün ve okumanın gecikmesi).
    public static let textGraceMs = 3000
    /// Öğrenilen yer kuralı çeviri kalktıktan sonra bu kadar süre geçerli (aynı yere gelen yeni İngilizce satır atılmasın).
    public static let placeGraceMs = 500
    /// Bütün satır benzerliği (yazı tanıma bozukluğuna pay).
    static let similarity = 0.8
    /// Parça eşleşmesi: okunan satırın en az bu oranı çevirinin sözcükleri olmalı,
    static let partShare = 0.8
    /// ve kaynağında geçmeyen (Türkçe) en az bu kadar sözcük eşleşmeli.
    static let partWords = 2
    /// Bu kadar kısa okuma (harf/rakam) eşleştirilmez.
    static let minimumLetters = 4
    /// Hatırlanan en çok çeviri (katman önceki satırları da yığabilir).
    static let remembered = 6

    private struct Shown {
        var words: [String]
        var text: String
        var source: [String]
        var sourceText: String
        var until: Int
        /// Kendi altyazısının karede okunduğu yer (metinden tanındıkça büyür).
        var seen: TextBox?
    }

    private let lock = NSLock()
    private let clock: () -> Int
    private var shown: [Shown] = []

    public init(clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.clock = clock
    }

    /// Çeviri ekrana gitti; `durationMs`: ekranda kalma süresi. Yer, gönderilen kutudan değil karede okunduğu yerden
    /// öğrenilir: sabit yerleşimde katman İngilizce satırın yerinde değildir.
    public func record(_ translation: String, source: String, durationMs: Int) {
        let words = PoolFilter.fold(IconText.plain(translation))
        guard !words.isEmpty else { return }
        let source = PoolFilter.fold(IconText.plain(source))
        let time = clock()
        lock.withLock {
            shown.append(Shown(words: words, text: words.joined(separator: " "), source: source,
                               sourceText: source.joined(separator: " "), until: time + durationMs))
            if shown.count > Self.remembered { shown.removeFirst(shown.count - Self.remembered) }
        }
    }

    /// Ekrandaki çeviri kaldırıldı.
    public func cleared() {
        let time = clock()
        lock.withLock { for index in shown.indices { shown[index].until = min(shown[index].until, time) } }
    }

    public func reset() {
        lock.withLock { shown.removeAll() }
    }

    /// `text` ekrandaki (ya da az önce kalkan) bir çevirimize benziyor ya da onun parçası.
    public func isOwn(_ text: String) -> Bool {
        let probe = PoolFilter.fold(IconText.plain(text))
        let time = clock()
        return lock.withLock { matchIndex(probe, at: time) != nil }
    }

    /// Okumanın kendi altyazımız olan satırları ayrılmış hali. `place`: okumanın karedeki yeri (satır kutuları ona oranla).
    /// `own`: atılan satırlar (yerleri kareye oranla).
    public func split(_ reading: Reading, place: TextBox = TextBox(left: 0, top: 0, right: 1, bottom: 1))
        -> (kept: Reading, own: [TextLine]) {
        let time = clock()
        return lock.withLock {
            guard shown.contains(where: { time <= $0.until + Self.textGraceMs }) else { return (reading, []) }
            var keep = Array(repeating: true, count: reading.lines.count)
            var own: [TextLine] = []
            // Önce metin: tanınan satırın yeri öğrenilir.
            for (index, line) in reading.lines.enumerated() {
                let probe = PoolFilter.fold(IconText.plain(line.text))
                guard let match = matchIndex(probe, at: time) else { continue }
                keep[index] = false
                var placed = line
                placed.box = line.box?.placed(in: place)
                if let box = placed.box { shown[match].seen = shown[match].seen.map { $0.union(box) } ?? box }
                own.append(placed)
            }
            // Sonra yer: çeviri ekrandayken öğrenilen dikdörtgene düşen ve kaynağa benzemeyen satır.
            for (index, line) in reading.lines.enumerated() where keep[index] {
                guard let box = line.box?.placed(in: place) else { continue }
                let probe = PoolFilter.fold(IconText.plain(line.text))
                let inside = shown.contains { entry in
                    guard time <= entry.until + Self.placeGraceMs, let seen = entry.seen else { return false }
                    return Self.covers(seen, box) && !Self.resembles(probe, entry.source, entry.sourceText)
                }
                guard inside else { continue }
                keep[index] = false
                var placed = line
                placed.box = box
                own.append(placed)
            }
            guard !own.isEmpty else { return (reading, []) }
            return (Reading(lines: reading.lines.indices.filter { keep[$0] }.map { reading.lines[$0] }), own)
        }
    }

    /// Kendi altyazımız İngilizce satırın yerine mi düştü (örtme ya da üst üste binen sabit yer): öyleyse altyazı yalnız
    /// bizim çevirimiz okunduğu için "kalktı" sayılmaz. Yeri bilinmeyen okumada da öyle sayılır.
    public static func coversLine(_ own: [TextLine], line: TextBox?) -> Bool {
        guard let line else { return true }
        return own.contains { item in
            guard let box = item.box else { return true }
            let overlap = min(box.bottom, line.bottom) - max(box.top, line.top)
            let height = min(box.bottom - box.top, line.bottom - line.top)
            return height > 0 && overlap >= 0.5 * height
        }
    }

    private func matchIndex(_ probe: [String], at time: Int) -> Int? {
        let joined = probe.joined(separator: " ")
        guard joined.filter({ $0 != " " }).count >= Self.minimumLetters else { return nil }
        for index in shown.indices.reversed() {
            let entry = shown[index]
            guard time <= entry.until + Self.textGraceMs else { continue }
            if Self.resembles(probe, entry.source, entry.sourceText) { continue }
            if TextMatch.isSimilar(joined, entry.text, threshold: Self.similarity) { return index }
            // Katmanın böldüğü satırlardan biri: sözcüklerin hemen hepsi çeviride, en az ikisi kaynakta olmayan sözcük.
            guard probe.count >= Self.partWords else { continue }
            let found = probe.filter { word in entry.words.contains { PoolFilter.isClose(word, $0) } }
            let foreign = found.filter { word in !entry.source.contains { PoolFilter.isClose(word, $0) } }
            if Double(found.count) >= Self.partShare * Double(probe.count), foreign.count >= Self.partWords { return index }
        }
        return nil
    }

    /// Okuma kaynak satıra (İngilizce) benziyor: atılmaz.
    static func resembles(_ probe: [String], _ source: [String], _ sourceText: String) -> Bool {
        guard !probe.isEmpty, !source.isEmpty else { return false }
        if TextMatch.isSimilar(probe.joined(separator: " "), sourceText, threshold: similarity) { return true }
        let found = probe.filter { word in source.contains { PoolFilter.isClose(word, $0) } }
        return Double(found.count) >= 0.6 * Double(probe.count)
    }

    /// Satır kutusunun en az %70'i alanın (her yana 0,01 pay) içinde.
    static func covers(_ area: TextBox, _ box: TextBox) -> Bool {
        let pad = 0.01
        let w = min(box.right, area.right + pad) - max(box.left, area.left - pad)
        let h = min(box.bottom, area.bottom + pad) - max(box.top, area.top - pad)
        let size = (box.right - box.left) * (box.bottom - box.top)
        return w > 0 && h > 0 && size > 0 && w * h >= 0.7 * size
    }
}
