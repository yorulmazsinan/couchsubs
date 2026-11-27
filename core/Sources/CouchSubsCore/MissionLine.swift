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
    /// Görev sayılmış (kendi kutusunda gösterilen) satır ancak bu kadar görülmezse kalkar (histerezis): tek okumada ya da
    /// kamera geçişinde kaçan görev satırının kutusu kalkıp gelmez, altyazı kutusu aşağı inip yeniden yukarı kaçmaz.
    /// Sinan Bey (GTA 6, beta.105): görev kutusu yanıp sönüyor, yer değiştiriyor, bazen hiç görünmüyordu. Gerçek kare
    /// okumalarında (gta6-854-gorev, pencere-kare-5-gorev) görev satırının 2 sn'lik ıskası kutuyu üç kez kaldırıp
    /// getiriyordu. Windows ve Android aynı.
    public static let holdMs = 4000
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
        /// Görev sayıldı (`settleMs` doldu): kendi kutusunda gösteriliyor; `holdMs` histerezisi ve `claim` uygulanır.
        var settled = false
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
        dropped = tracks.filter { !$0.settled && time - $0.lastSeen > Self.forgetMs && $0.lastSeen - $0.since < Self.settleMs }
            .map(\.source)
        tracks.removeAll { time - $0.lastSeen > ($0.settled ? Self.holdMs : Self.forgetMs) }
        for i in tracks.indices where time - tracks[i].since >= Self.settleMs { tracks[i].settled = true }
        let shown = tracks.first.map { first in tracks.dropFirst().reduce(first.box) { $0.union($1.box) } }
        if let shown, let current = clearance, Self.near(shown, current) {
            // Aynı yer: değişmez.
        } else {
            clearance = shown
        }
        let settled = tracks.filter(\.settled)
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

    /// Görev sayılmış satırın okumadaki yeni okunuşları: okumadan çıkarılır (`kept`), görev satırı olarak `observe`a verilir
    /// (`claimed`). Görev satırı sabit satır süzgecinden (`StickyRows`) geçmeden de altyazıdan ayrı kalır: konuşma bitip
    /// görev tek başına kaldığında ya da ıskadan sonra geri geldiğinde altyazı kutusunda çevrilmez ("Get in the Speedboat"
    /// altyazı ile görev kutusu arasında gidip geliyordu), sabit satır süzgecinin geri gelen görevi "yeni" sayıp konuşmayı
    /// sabit (görev) saymasına da yol açmaz. Satır aynı yazıda (`TextMatch.isSimilar`) ve görevin yerinde (dikeyde
    /// görev kutusuyla örtüşür) olmalı; konuşan adlı satır hiç alınmaz.
    public func claim(_ reading: Reading, area: TextBox) -> (kept: Reading, claimed: [TextLine]) {
        let shown = tracks.filter(\.settled)
        guard !shown.isEmpty else { return (reading, []) }
        var kept: [TextLine] = [], claimed: [TextLine] = []
        for line in reading.lines {
            guard let box = line.box, SpeakerPrefix.split(line.text) == nil else { kept.append(line); continue }
            let placed = box.placed(in: area)
            let text = TextMatch.normalize(line.text)
            let ours = text.count >= 3 && shown.contains { track in
                let height = min(placed.bottom - placed.top, track.box.bottom - track.box.top)
                let overlap = min(placed.bottom, track.box.bottom) - max(placed.top, track.box.top)
                return overlap >= 0.5 * height && TextMatch.isSimilar(track.text, text)
            }
            if ours { claimed.append(line) } else { kept.append(line) }
        }
        return claimed.isEmpty ? (reading, []) : (Reading(lines: kept), claimed)
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
