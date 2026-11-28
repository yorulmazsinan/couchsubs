// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Ekranın kenarındaki bildirim kartları (GTA 6: sağ altta telefona gelen mesajın önizlemesi, solda kayarak giren bildirim)
/// altyazı değildir, kendi yerinde çevrilir. Kullanıcı bildirimi (X, iki kişi): altyazı alanı "Tam ekran"ken bu kartlar
/// altyazı bloğu seçiliyordu (ortalanmış blok yokken en alttaki üç sözcüklü blok); çevirileri altyazının yerinde, ekranın
/// ortasında çiziliyor, art arda gelen kartlar orada üst üste toplanıyordu. Artık "Tam ekran" alanda (`isWholeScreen`)
/// karenin bir yarısında kalan ve ortasından uzak blok (`isNotice`) altyazı bloğuna girmez (`Reading.subtitleBlock`);
/// bildirim olarak izlenir. Kayarak giren kartın kutusu her karede kayar: kutu `settleMs` boyunca yerinde durunca (kayma
/// bitti) bölgesi "auto-notice-<n>" ek alanı olur, çevirisi `RegionWatcher` ile özgün stilinde kendi yerinde görünür. Kart
/// sonra yeniden kayarsa son geçerli yer kalır, yeni yerinde durulunca bölge oraya taşınır; konumu belirsiz kart hiç
/// çizilmez, asla ortaya çizilmez. Windows (ScreenNotices.cs) ve Android (ScreenNotices.kt) aynı kuralları ve eşikleri
/// uygular; ortak deneme dosyası Tests/CouchSubsCoreTests/Fixtures/screen-notice.json.
public struct ScreenNotices: Sendable {
    public static let idPrefix = "auto-notice-"
    /// Okunan alan karenin en az bu kadar genişliğini ve `tallArea` kadar yüksekliğini kaplıyorsa "Tam ekran" sayılır.
    public static let wideArea = 0.85
    public static let tallArea = 0.5
    /// Bildirim bloğunun yatay ortası karenin ortasından en az bu kadar uzaktır (blok ortayı geçmez).
    public static let sideOffset = 0.2
    /// Kutu bu kadar süre yerinde durunca (kayma bitti) bildirimin bölgesi gönderilir.
    public static let settleMs = 400
    /// Bu kadar görülmeyen bildirim ekrandan kalkmış sayılır.
    public static let forgetMs = 1500
    /// Kutunun kenarları bundan az oynarsa yerinde duruyor sayılır (yazı tanımanın kutu oynaması).
    public static let moveTolerance = 0.006
    /// En çok bu kadar bildirim aynı anda kendi yerinde çevrilir.
    public static let maxCount = 3

    /// Okunan alan (karedeki yeri) "Tam ekran" mı.
    public static func isWholeScreen(_ area: TextBox) -> Bool {
        area.right - area.left >= wideArea && area.bottom - area.top >= tallArea
    }

    /// Kutu (karede) bir kenar bildirimi mi: karenin bir yarısında kalıyor ve ortası karenin ortasından en az `sideOffset` uzak.
    public static func isNotice(_ box: TextBox) -> Bool {
        guard box.right > box.left, box.bottom > box.top else { return false }
        return (box.right <= 0.5 || box.left >= 0.5) && abs((box.left + box.right) / 2 - 0.5) >= sideOffset
    }

    /// Ek alan bir bildirim bölgesi mi.
    public static func isNotice(id: String) -> Bool { id.hasPrefix(idPrefix) }

    private struct Track: Sendable {
        var number: Int
        var box: TextBox
        var line: Double
        var still: Int
        var lastSeen: Int
        var region: CropRegion?
        /// Bildirim kartı (`NoticeCard`): kutu kartın bütün yeridir, bölge de odur.
        var card = false
    }

    private var tracks: [Track] = []
    private var counter = 0

    /// Şu an kendi yerinde okunan bildirim alanları.
    public private(set) var areas: [ExtraArea] = []

    public init() {}

    /// Bu karenin bildirim blokları (satır kutuları karede) ve bildirim kartları (`NoticeCard`; kartın karedeki yeri, alan
    /// türünden bağımsız). Alan listesi değiştiyse true. Bildirim yokken de her karede çağrılır: görülmeyen bildirim
    /// `forgetMs` sonra kalkar. Kartın bölgesi kartın kendisidir (başlık ve gövde birlikte okunur, çeviri kartı örter).
    public mutating func observe(_ blocks: [Reading], cards: [TextBox] = [], at time: Int) -> Bool {
        var matched = Set<Int>()
        for box in cards {
            if let index = tracks.indices.first(where: { !matched.contains($0) && tracks[$0].card && Self.same(tracks[$0].box, box) }) {
                if Self.moved(tracks[index].box, box) { tracks[index].still = time }
                tracks[index].box = box
                tracks[index].lastSeen = time
                matched.insert(index)
            } else {
                counter += 1
                tracks.append(Track(number: counter, box: box, line: 0, still: time, lastSeen: time, card: true))
                matched.insert(tracks.count - 1)
            }
        }
        for block in blocks {
            guard let box = block.box, Self.isNotice(box) else { continue }
            let line = block.lines.compactMap { $0.box.map { $0.bottom - $0.top } }.min() ?? (box.bottom - box.top)
            if let index = tracks.indices.first(where: { !matched.contains($0) && !tracks[$0].card && Self.same(tracks[$0].box, box) }) {
                if Self.moved(tracks[index].box, box) { tracks[index].still = time }
                tracks[index].box = box
                tracks[index].line = line
                tracks[index].lastSeen = time
                matched.insert(index)
            } else {
                counter += 1
                tracks.append(Track(number: counter, box: box, line: line, still: time, lastSeen: time))
                matched.insert(tracks.count - 1)
            }
        }
        tracks.removeAll { time - $0.lastSeen > Self.forgetMs }
        for index in tracks.indices where time - tracks[index].still >= Self.settleMs {
            let next = tracks[index].card ? Self.cardRegion(tracks[index].box) : Self.region(tracks[index].box, line: tracks[index].line)
            // Okuma kutusunun küçük oynaması bölgeyi değiştirmez (bölge değişirse bildirim yeniden okunur).
            if let current = tracks[index].region, Self.close(current, next) { continue }
            tracks[index].region = next
        }
        let next = tracks.compactMap { track in
            track.region.map { ExtraArea(id: Self.idPrefix + String(track.number), name: "Notice", region: $0, auto: true) }
        }.prefix(Self.maxCount)
        guard Array(next) != areas else { return false }
        areas = Array(next)
        return true
    }

    public mutating func reset() {
        tracks.removeAll()
        areas = []
    }

    /// Bölge: kutu ve her yanında pay (dikeyde satır boyunun %35'i, yatayda karenin %1'i), 0…1'e kırpılmış.
    static func region(_ box: TextBox, line: Double) -> CropRegion {
        CropRegion(top: max(0, box.top - 0.35 * line), bottom: min(1, box.bottom + 0.35 * line),
                   left: max(0, box.left - 0.01), right: min(1, box.right + 0.01))
    }

    /// Bildirim kartının bölgesi: kartın kendisi, 0…1'e kırpılmış.
    static func cardRegion(_ box: TextBox) -> CropRegion {
        CropRegion(top: max(0, box.top), bottom: min(1, box.bottom), left: max(0, box.left), right: min(1, box.right))
    }

    /// İki kutu aynı bildirim mi: karenin aynı yarısında ve dikeyde (yana kayan kart) ya da yatayda (yukarı kayan kart)
    /// küçüğünün en az yarısı kadar örtüşüyor.
    static func same(_ a: TextBox, _ b: TextBox) -> Bool {
        guard ((a.left + a.right) / 2 < 0.5) == ((b.left + b.right) / 2 < 0.5) else { return false }
        let vertical = min(a.bottom, b.bottom) - max(a.top, b.top)
        let horizontal = min(a.right, b.right) - max(a.left, b.left)
        let rows = vertical > 0 && vertical >= 0.5 * min(a.bottom - a.top, b.bottom - b.top)
        let columns = horizontal > 0 && horizontal >= 0.5 * min(a.right - a.left, b.right - b.left)
            && max(a.top, b.top) - min(a.bottom, b.bottom) <= max(a.bottom - a.top, b.bottom - b.top)
        return rows || columns
    }

    static func moved(_ a: TextBox, _ b: TextBox) -> Bool {
        abs(a.left - b.left) > moveTolerance || abs(a.top - b.top) > moveTolerance
            || abs(a.right - b.right) > moveTolerance || abs(a.bottom - b.bottom) > moveTolerance
    }

    private static func close(_ a: CropRegion, _ b: CropRegion) -> Bool {
        abs(a.left - b.left) <= moveTolerance && abs(a.top - b.top) <= moveTolerance
            && abs(a.right - b.right) <= moveTolerance && abs(a.bottom - b.bottom) <= moveTolerance
    }
}
