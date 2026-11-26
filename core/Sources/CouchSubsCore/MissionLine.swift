// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Görev/hedef satırı altyazıdan ayrı, kendi yerinde: altyazı hattının altyazı bloğundan çıkardığı satırlardan
/// (`StickyRows.removed`) konuşan adı taşımayan ve en az `settleMs` ekranda kalan satırlar görevdir. Bölgesi
/// "auto-mission" ek alanı olarak sürekli okunur, çevirisi özgün stilinde kendi yerinde görünür (RegionWatcher). Görev
/// yerinde durdukça bölge değişmez: altyazı her değiştiğinde görev kutusu yeniden gönderilmez, yanıp sönmez. Windows
/// (MissionLine.cs) ve Android (MissionLine.kt) aynı kuralları uygular.
public struct MissionLine {
    public static let areaId = "auto-mission"
    /// Satır bu kadar ekranda kalınca görev sayılır.
    public static let settleMs = 3000
    /// Bu kadar görülmeyen satır ekrandan kalkmış sayılır.
    public static let forgetMs = 1500
    /// Görev çevirisinin kutusu: koyu kehribar zemin, beyaz yazı. Kullanıcı bildirimi (beta.100): görev yazısının Türkçesi
    /// altyazıyla ve öbür ekran yazılarıyla aynı görünüyor, hangisinin görev olduğu anlaşılmıyordu. TV ve önizlemeler bu
    /// zemini öğenin `style`ından çizer (Windows: MissionLine.Style, Android: MissionLine.STYLE).
    public static let style = PhoneTextStyle(background: "#7A4E00", foreground: "#FFFFFF")
    /// Görev çevirisinin başındaki hedef imi (yaygın yazı tiplerinde bulunan dolu üçgen; emoji değildir).
    public static let marker = "\u{25BA} "

    private struct Track {
        var text: String
        /// Satırın okunduğu gibi hâli (günlük için).
        var source: String
        var since: Int
        var lastSeen: Int
        var box: TextBox
    }

    private var tracks: [Track] = []

    /// Görevin karedeki bölgesi; görev yoksa nil.
    public private(set) var region: CropRegion?
    /// Ekranda duran görev satırlarının karedeki yeri (`settleMs` dolmadan da): TV ve OBS sayfası altyazı kutusunu bunun
    /// üstüne taşır, kutu oyundaki görev satırını örtmez. Kullanıcı bildirimi (X, beta.100–104, GTA 6): "Örtsün"de iki
    /// satırlık Türkçe İngilizce satırın ortasına göre büyüyor, alttaki görev satırının ("Get in the speedboat") üst
    /// yarısını kapatıyordu. Okuma kutusunun küçük oynaması değer değiştirmez (yeniden gönderilmez).
    public private(set) var clearance: TextBox?
    /// Son `observe`ta görev sayılmadan (`settleMs` dolmadan) ekrandan kalkan satırlar: altyazıdan da çıkarıldıkları için
    /// hiç çevrilmediler; günlüğe bir kez yazılır.
    public private(set) var dropped: [String] = []

    public init() {}

    /// Altyazı bloğundan çıkarılan satırlar (yeri `area`'ya oranla). Görev bölgesi değiştiyse true.
    public mutating func observe(_ removed: [TextLine], area: TextBox, at time: Int) -> Bool {
        for line in removed {
            guard let box = line.box, SpeakerPrefix.split(line.text) == nil else { continue }
            let text = TextMatch.normalize(line.text)
            guard text.count >= 3 else { continue }
            let placed = box.placed(in: area)
            guard Self.isCandidate(line.text, box: placed) else { continue }
            if let index = tracks.firstIndex(where: { TextMatch.isSimilar($0.text, text) }) {
                tracks[index].lastSeen = time
                tracks[index].box = placed
            } else {
                tracks.append(Track(text: text, source: line.text, since: time, lastSeen: time, box: placed))
            }
        }
        dropped = tracks.filter { time - $0.lastSeen > Self.forgetMs && $0.lastSeen - $0.since < Self.settleMs }.map(\.source)
        tracks.removeAll { time - $0.lastSeen > Self.forgetMs }
        let shown = tracks.first.map { first in tracks.dropFirst().reduce(first.box) { $0.union($1.box) } }
        if let shown, let current = clearance, Self.near(shown, current) {
            // Aynı yer: değişmez.
        } else {
            clearance = shown
        }
        let settled = tracks.filter { time - $0.since >= Self.settleMs }
        var next: CropRegion?
        if let first = settled.first {
            let union = settled.dropFirst().reduce(first.box) { $0.union($1.box) }
            let line = settled.map { $0.box.bottom - $0.box.top }.min()!
            var candidate = CropRegion(top: max(0, union.top - 0.35 * line), bottom: min(1, union.bottom + 0.35 * line),
                                       left: max(0, union.left - 0.01), right: min(1, union.right + 0.01))
            // Okuma kutusunun küçük oynaması bölgeyi değiştirmez (bölge değişirse görev yeniden okunur).
            if let current = region, Self.within(candidate, current, line * 0.5) { candidate = current }
            next = candidate
        }
        guard next != region else { return false }
        region = next
        return true
    }

    /// Satır (kutusu karede) görev olabilir mi. Görev satırı ortadadır ve sözcüklerden oluşur; ekranın bir yanındaki
    /// HUD yazısı (`ScreenNotices.isNotice`: GTA 6'da arama kartının yanındaki küçük yazı) ya da okuma kırıntısı
    /// (`OcrNoise.isCrumb`) görev sayılıp kendi yerinde çevrilmez. Kullanıcı bildirimi (GitHub #882, GTA 6): telefon
    /// araması sürerken arama kartının yanında "kulaklı ar." diye küçük bir çeviri kutusu çıkıyordu.
    public static func isCandidate(_ text: String, box: TextBox) -> Bool {
        !ScreenNotices.isNotice(box) && !OcrNoise.isCrumb(text)
    }

    public mutating func reset() {
        tracks.removeAll()
        dropped = []
        region = nil
        clearance = nil
    }

    /// İki kutu satır boyunun çeyreğinden az oynamış mı.
    static func near(_ a: TextBox, _ b: TextBox) -> Bool {
        let tolerance = 0.25 * min(a.bottom - a.top, b.bottom - b.top)
        return abs(a.top - b.top) <= tolerance && abs(a.bottom - b.bottom) <= tolerance
            && abs(a.left - b.left) <= tolerance * 2 && abs(a.right - b.right) <= tolerance * 2
    }

    private static func within(_ a: CropRegion, _ b: CropRegion, _ tolerance: Double) -> Bool {
        abs(a.top - b.top) <= tolerance && abs(a.bottom - b.bottom) <= tolerance
            && abs(a.left - b.left) <= tolerance * 2 && abs(a.right - b.right) <= tolerance * 2
    }
}
