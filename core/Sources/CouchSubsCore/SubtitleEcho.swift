// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Altyazı hattının son okuduğu satırlar ve altyazı alanı: ekran yazısı (otomatik dedektör, hazır alanlar, görev satırı,
/// "Ekranı çevir") altyazıyı ikinci kez çizmesin. Kullanıcı bildirimi (X, beta.65/66): "Ekran yazılarını otomatik
/// çevir" açıkken altyazının çevirisi hem seçilen altyazı konumunda hem oyunun altyazısının tam üstünde görünüyordu.
/// Dedektör yalnız merkezi altyazı alanında kalan karoları dışlıyordu; alanın kenarına taşan satırın karoları (iki
/// satırlı altyazının alan dışında kalan üst satırı, alandan geniş satırın uçları) aday oluyor, bulunan alan yarım/bir
/// karo genişletildiği için altyazının kendisini de okuyordu. Hazır GTA 6 mesaj alanı da (0,72–0,99 x 0,45–0,80)
/// varsayılan altyazı alanıyla (0,14–0,86 x 0,62–0,97) kesişiyor, geniş altyazının sağ ucunu okuyordu. Görev satırının
/// bölgesi de (MissionLine) altyazı alanının içindedir; görev kalkıp yerine altyazı gelince altyazı orada da okunuyordu.
///
/// Kural: ekran yazısı okumasında altyazı alanında altyazı satırının yerine düşen satır (bkz. `isSubtitlePlace`), son
/// altyazı satırının hemen üstüne/altına taşan aynı boydaki satır ve altyazı hattının son `windowMs` içinde okuduğu metne
/// benzeyen satır atılır. Menü durumunda ve görev satırının kendi alanında yalnız metin eşleşmesi uygulanır (menü
/// satırları altyazı alanında da olabilir; görev satırı altyazı alanının içindedir). Karede okunan kendi çevirimiz de
/// (OBS Program projektörü, bkz. `OwnSubtitles`) metinden atılır. Windows (SubtitleEcho.cs) ve
/// Android (SubtitleEcho.kt) aynı kuralları uygular. İş parçacığı güvenlidir.
public final class SubtitleEcho: @unchecked Sendable {
    /// Altyazı hattının okuduğu metin bu kadar süre hatırlanır (ekran yazısı turu 0,5–1 sn arayla okur).
    public static let windowMs = 6000
    /// Altyazı satırına bitişik satır kuralı bu kadar süre geçerlidir (altyazı ekrandayken).
    public static let adjacentMs = 1500
    /// Kısa okuma, uzun satırın parçası sayılmak için en az bu kadar harf/rakam taşımalı.
    static let partMinimum = 10
    /// ve uzun satırın en az bu kadarı olmalı (altyazıda geçen kısa görev yazısı "Get to the docks" atılmasın).
    static let partShare = 0.4
    /// Bu kadar büyük altyazı alanı (Tam ekran) yerle dışlanmaz.
    static let wholeScreen = 0.6

    /// Uygulamanın tek altyazı hattı ve ekran yazısı okuyucuları bunu paylaşır (testler kendi örneğini kurar).
    public static let shared = SubtitleEcho()

    private struct Line {
        var text: String
        var box: TextBox?
        var at: Int
    }

    private let lock = NSLock()
    private let clock: () -> Int
    private var lines: [Line] = []
    /// Altyazı hattının gösterdiği çeviriler (hat verir): karede okunan kendi altyazımız ekran yazısı olarak da çevrilmez.
    public var own: OwnSubtitles? {
        get { lock.withLock { ownSubtitles } }
        set { lock.withLock { ownSubtitles = newValue } }
    }
    private var ownSubtitles: OwnSubtitles?
    private var region: CropRegion?

    public init(clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.clock = clock
    }

    /// Altyazı hattı her işlediği karede çağırır: `block` altyazı bloğunun satırları (yeri `region`'a oranla).
    public func record(_ block: Reading, region: CropRegion) {
        let time = clock()
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        lock.withLock {
            self.region = region
            for line in block.lines {
                let text = TextMatch.normalize(IconText.plain(line.text))
                guard text.count >= 3 else { continue }
                let box = line.box?.placed(in: place)
                if let index = lines.firstIndex(where: { $0.text == text }) {
                    lines[index].at = time
                    lines[index].box = box ?? lines[index].box
                } else {
                    lines.append(Line(text: text, box: box, at: time))
                }
            }
            lines.removeAll { time - $0.at > Self.windowMs }
            if lines.count > 64 { lines.removeFirst(lines.count - 64) }
        }
    }

    /// Okuma durdu ya da hat sıfırlandı.
    public func reset() {
        lock.withLock {
            lines.removeAll()
            region = nil
        }
    }

    /// Altyazı hattı son `windowMs` içinde bir altyazı okudu ("Ekranı çevir" yer kuralını yalnız o zaman uygular).
    public var hasRecent: Bool {
        let time = clock()
        return lock.withLock { lines.contains { time - $0.at <= Self.windowMs } }
    }

    /// `text` altyazı hattının son `windowMs` içinde okuduğu bir satıra benziyor ya da onun parçası/bütünü.
    public func isEcho(_ text: String) -> Bool {
        if own?.isOwn(text) == true { return true }
        let probe = TextMatch.normalize(IconText.plain(text))
        guard probe.count >= 3 else { return false }
        let time = clock()
        return lock.withLock {
            lines.contains { line in
                guard time - line.at <= Self.windowMs else { return false }
                if TextMatch.isSimilar(probe, line.text, threshold: 0.8) { return true }
                let (short, long) = probe.count <= line.text.count ? (probe, line.text) : (line.text, probe)
                return short.count >= Self.partMinimum && Double(short.count) >= Self.partShare * Double(long.count)
                    && long.contains(short)
            }
        }
    }

    /// Karedeki (0..1) kutu altyazının yerinde mi: altyazı alanında (merkezi içinde ya da alanının en az yarısı) ve altyazı
    /// hattının son `windowMs` içinde okuduğu bir satırın üstünde (`sameRow`), ya da son altyazı satırının hemen
    /// üstüne/altına taşan aynı boyda bir satır.
    ///
    /// Alanın tamamı dışlanmaz. Kullanıcı bildirimi (X, beta.69, GTA 6): "Ekranı çevir" altyazıyı çeviriyor, telefon
    /// mesajlarını çevirmiyordu. Sağ alttaki telefon kartı (0,72–0,99 x 0,45–0,80) varsayılan altyazı alanıyla
    /// (0,14–0,86 x 0,62–0,97) kesişiyor; altyazı okunurken kartın 0,62'nin altındaki mesaj satırlarının merkezi alanın
    /// içinde kaldığı için hepsi atılıyordu (hazır mesaj alanında da). Altyazının kendisi metinle, alan kenarına taşan
    /// ve alana düşen parçaları altyazı satırının yerinden tanınır.
    public func isSubtitlePlace(_ box: TextBox) -> Bool {
        let time = clock()
        return lock.withLock {
            // Tam ekran (ya da ekranın çoğu) altyazı alanıyken yer kuralı uygulanmaz; metin eşleşmesi yeter.
            if let region, (region.right - region.left) * (region.bottom - region.top) < Self.wholeScreen,
               Self.inside(box, region),
               lines.contains(where: { line in
                   guard time - line.at <= Self.windowMs, let other = line.box else { return false }
                   return Self.sameRow(box, other)
               }) { return true }
            return lines.contains { line in
                guard time - line.at <= Self.adjacentMs, let other = line.box else { return false }
                return Self.adjacent(box, other)
            }
        }
    }

    /// Ekran yazısı okumasından altyazıya ait satırlar çıkarılmış hali. `place`: okumanın karedeki yeri (satır kutuları
    /// ona oranla). `geometry`: yerle de dışla (menü durumu ve görev alanı dışında); metin eşleşmesi her zaman uygulanır.
    public func filter(_ reading: Reading, place: TextBox = TextBox(left: 0, top: 0, right: 1, bottom: 1),
                       geometry: Bool = true) -> Reading {
        let kept = reading.lines.filter { line in
            if isEcho(line.text) { return false }
            if geometry, let box = line.box, isSubtitlePlace(box.placed(in: place)) { return false }
            return true
        }
        return kept.count == reading.lines.count ? reading : Reading(lines: kept)
    }

    static func inside(_ box: TextBox, _ region: CropRegion) -> Bool {
        let x = (box.left + box.right) / 2, y = (box.top + box.bottom) / 2
        if x >= region.left && x <= region.right && y >= region.top && y <= region.bottom { return true }
        let w = min(box.right, region.right) - max(box.left, region.left)
        let h = min(box.bottom, region.bottom) - max(box.top, region.top)
        let area = (box.right - box.left) * (box.bottom - box.top)
        return w > 0 && h > 0 && area > 0 && w * h >= 0.5 * area
    }

    /// Kutu altyazı satırıyla aynı sırada (dikeyde örtüşüyor ya da arada satır boyunun yarısından az boşluk) ve yatayda
    /// dardakinin en az %80'i örtüşüyor: altyazının kendisi, parçası ya da aynı yere gelen yeni altyazı. Telefon kartının
    /// satırı geniş altyazıyla aynı sıradaysa bile yalnız ucu örtüşür, atılmaz.
    static func sameRow(_ box: TextBox, _ line: TextBox) -> Bool {
        let height = max(box.bottom - box.top, line.bottom - line.top)
        let gap = max(box.top - line.bottom, line.top - box.bottom)
        let overlap = min(box.right, line.right) - max(box.left, line.left)
        let narrower = min(box.right - box.left, line.right - line.left)
        return height > 0 && narrower > 0 && gap <= height * 0.5 && overlap >= narrower * 0.8
    }

    /// Aynı boyda (±%30), yatayda örtüşen ve dikeyde en çok bir satır boyu aralıklı iki satır (iki satırlı altyazının alan
    /// dışında kalan satırı).
    static func adjacent(_ box: TextBox, _ line: TextBox) -> Bool {
        let a = box.bottom - box.top, b = line.bottom - line.top
        guard a > 0, b > 0, max(a, b) <= min(a, b) * 1.3 else { return false }
        let gap = max(box.top - line.bottom, line.top - box.bottom)
        let overlap = min(box.right, line.right) - max(box.left, line.left)
        return gap <= b && overlap > 0.3 * min(box.right - box.left, line.right - line.left)
    }
}
