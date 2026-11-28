// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// GTA 6'nın sağ alttaki bildirim kartı (gelen arama "Withheld Number", mesaj önizlemesi, uyarı): açık renkli, köşesi
/// yuvarlak düz kart; solda simge, üstte kalın başlık, altında koyu yazılı gövde. Kullanıcı bildirimi (GitHub #1443, X'te
/// başkaları da: "sağ alt mesajlar çevrilmiyor"): kartın yalnız başlığı (otomatik ekran yazısı) çevriliyor, gövdesi hiç
/// çevrilmiyordu. İki neden: kenar bildirimi yolu (`ScreenNotices`) yalnız altyazı alanı "Tam ekran"ken çalışıyordu; alt
/// şerit altyazı alanı kartın bir kısmını kesince gövde "koyu yazı açık zeminde (kâğıt/tabela)" (`InkTone`) sayılıp
/// atılıyordu. Otomatik ekran yazısı da menü dışında yalnız koyu zemindeki açık yazıyı bulur.
///
/// Artık oyun GTA 6 iken (ekran yazısı ya da telefon çevirisi açık) altyazı alanında okunan blok, sahne yazısı süzgeçlerinden
/// ve görev/HUD ayıklamasından önce kart mı diye bakılır (`split`): bloğun kutusu karenin sağında (`isCandidate`) ve
/// karede çevresinde düz, açık renkli, kapalı bir kart bulunuyor (`bounds`). Kart blokları altyazıya girmez; kartın bütün
/// yeri (alan kartı kesse de) "auto-notice-<n>" ek alanı olur (`ScreenNotices.observe(cards:)`), başlık ve gövde kendi
/// yerinde, kartın üstüne örtülerek çevrilir. Altyazı alanının ortasındaki kâğıt ilan ve tabela kart sayılmaz (sağda değil,
/// karenin kenarına dayalı ya da kapalı düz kart değil); onları `InkTone` atmaya devam eder.
///
/// Kart araması karenin `gridWidth` × `gridHeight` örnek ağında yapılır (karenin çözünürlüğünden bağımsız): kutunun içinin
/// üst çeyreği kartın zemini (en az `lightGround`), kutu her yöne bir örnek satırı/sütunu kadar büyütülür; büyütülen satırın
/// en az `groundShare` kadarı zemin (zeminden en çok `tolerance` farklı), en çok `otherShare` kadarı zeminden de mürekkepten
/// de (zeminden en az `inkGap` koyu) farklıysa satır kartındır. Asfalt, çimen ve kartın kenarı/gölgesi büyümeyi durdurur.
/// Kart kapalıdır: dört yanının en çok `edgeReach` örnek dışında kart rengi biter (`edgeShare`), karenin kenarına değmez,
/// boyu `minWidth`–`maxWidth` × `minHeight`–`maxHeight`, sağ kenarı karenin sağına yakındır (`minRight`). Kartın kutusunda
/// kendi başına aranamayan blok (simgenin yanındaki kısa başlık) bulunan kartın içindeyse o karta katılır.
/// Windows (NoticeCard.cs) ve Android (NoticeCard.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// Tests/CouchSubsCoreTests/Fixtures/notice-card.json (gerçek kare testdata/frames/gta6-n4-bildirim ve kayıtlı okuması).
public enum NoticeCard {
    public static let gridWidth = 480
    public static let gridHeight = 270
    /// Kartın zemini (kutunun içinin üst çeyreği; yazı zeminden koyudur) en az bu kadar açık. Kart yarı saydam beyazdır:
    /// gündüz ~230, gece karanlık sahnede ~150 (gerçek kare gta6-n4-bildirim).
    public static let lightGround = 120
    /// Zeminden en çok bu kadar farklı nokta zemindir.
    public static let tolerance = 24
    /// Zeminden en az bu kadar koyu nokta mürekkeptir (yazı, simge).
    public static let inkGap = 60
    /// Kartın satırında/sütununda zemin payı en az, başka (ne zemin ne mürekkep) payı en çok.
    public static let groundShare = 0.3
    public static let otherShare = 0.15
    /// Kutudaki mürekkep payı bu aralıkta (boş zemin ya da tümü koyu kutu yazı değildir).
    public static let minInk = 0.03
    public static let maxInk = 0.5
    /// Blok karenin sağında: kutunun sol kenarı en az `minLeft`, ortası en az `minCenter`.
    public static let minLeft = 0.5
    public static let minCenter = 0.6
    /// Kart karenin sağ kenarına yakın biter (en az `minRight`), sağ kenara değmez (en çok `maxRight`), sol kenarı en az
    /// `cardLeft`.
    public static let minRight = 0.85
    public static let maxRight = 0.995
    public static let cardLeft = 0.45
    /// Kartın boyu (kareye oranla).
    public static let minWidth = 0.1
    public static let maxWidth = 0.35
    public static let minHeight = 0.04
    public static let maxHeight = 0.35
    /// Kartın dört yanının hemen dışındaki satır/sütunda zemin rengi payı en çok bu kadar (kart çevresinden ayrılır; açık
    /// haritada ya da gökyüzünde büyüyen alan kart değildir).
    public static let edgeShare = 0.5
    /// Kartın kenarı en çok bu kadar örnek dışarıda biter (kenar çizgisi, gölge, yumuşak geçiş).
    public static let edgeReach = 3
    /// Kart yazının çevresinde en az bu kadar örnek (ağda) taşar: solda ve üstte ya da altta kart payı vardır.
    public static let margin = 2

    /// Altyazı hattı bildirim kartı arar mı (`SubtitlePipeline.findsNoticeCards`): çeviri sürüyor, oyun GTA 6 ve ekran
    /// yazısı ya da telefon çevirisi açık (Windows ve Android aynı).
    public static func enabled(running: Bool, game: String?, screenText: Bool, phone: Bool) -> Bool {
        guard running, let game else { return false }
        return GameName.key(game) == "gta 6" && (screenText || phone)
    }

    /// Blok kutusu (karede) bildirim kartı adayı mı: karenin sağında.
    public static func isCandidate(_ box: TextBox) -> Bool {
        box.right > box.left && box.bottom > box.top && box.left >= minLeft && (box.left + box.right) / 2 >= minCenter
    }

    /// `box` (karede) çevresindeki bildirim kartının karedeki yeri; kart yoksa nil. `luma(x, y)`: karenin (piksel)
    /// parlaklığı, 0–255.
    public static func bounds(around box: TextBox, width: Int, height: Int, luma: (Int, Int) -> Int) -> TextBox? {
        guard width > 0, height > 0, isCandidate(box) else { return nil }
        let gw = gridWidth, gh = gridHeight
        func sample(_ gx: Int, _ gy: Int) -> Int {
            let x = min(width - 1, Int((Double(gx) + 0.5) * Double(width) / Double(gw)))
            let y = min(height - 1, Int((Double(gy) + 0.5) * Double(height) / Double(gh)))
            return max(0, min(255, luma(x, y)))
        }
        var l = max(0, min(gw - 1, Int(box.left * Double(gw))))
        var r = max(0, min(gw - 1, Int(box.right * Double(gw)) - 1))
        var t = max(0, min(gh - 1, Int(box.top * Double(gh))))
        var b = max(0, min(gh - 1, Int(box.bottom * Double(gh)) - 1))
        guard r - l >= 2, b - t >= 1 else { return nil }
        var inside: [Int] = []
        for gy in t...b { for gx in l...r { inside.append(sample(gx, gy)) } }
        let ground = inside.sorted()[inside.count * 3 / 4]
        guard ground >= lightGround else { return nil }
        let ink = Double(inside.filter { $0 <= ground - inkGap }.count) / Double(inside.count)
        guard ink >= minInk, ink <= maxInk else { return nil }
        func isCard(_ values: [Int]) -> Bool {
            var flat = 0, other = 0
            for value in values {
                if abs(value - ground) <= tolerance { flat += 1 } else if value > ground - inkGap { other += 1 }
            }
            return Double(flat) >= groundShare * Double(values.count) && Double(other) <= otherShare * Double(values.count)
        }
        func column(_ gx: Int) -> [Int] { (t...b).map { sample(gx, $0) } }
        func row(_ gy: Int) -> [Int] { (l...r).map { sample($0, gy) } }
        let (l0, t0, b0) = (l, t, b)
        var grew = true
        while grew {
            grew = false
            if r + 1 < gw, isCard(column(r + 1)) { r += 1; grew = true }
            if l > 0, isCard(column(l - 1)) { l -= 1; grew = true }
            if t > 0, isCard(row(t - 1)) { t -= 1; grew = true }
            if b + 1 < gh, isCard(row(b + 1)) { b += 1; grew = true }
        }
        // Kart kapalıdır: karenin kenarına dayanmaz (açık gökyüzü, kar), yazının çevresinde kart payı vardır.
        guard l > 0, t > 0, r + 1 < gw, b + 1 < gh, l0 - l >= margin, (t0 - t) + (b - b0) >= margin else { return nil }
        func apart(_ values: [Int]) -> Bool {
            Double(values.filter { abs($0 - ground) <= tolerance }.count) <= edgeShare * Double(values.count)
        }
        // Kenarın hemen dışı yumuşak geçiş (kenar çizgisi, gölge) olabilir: en çok `edgeReach` örnek dışarıda kart rengi biter.
        let outside: [[[Int]]] = [
            (1...edgeReach).map { column(max(0, l - $0)) }, (1...edgeReach).map { column(min(gw - 1, r + $0)) },
            (1...edgeReach).map { row(max(0, t - $0)) }, (1...edgeReach).map { row(min(gh - 1, b + $0)) },
        ]
        guard outside.allSatisfy({ $0.contains(where: apart) }) else { return nil }
        let card = TextBox(left: Double(l) / Double(gw), top: Double(t) / Double(gh),
                           right: Double(r + 1) / Double(gw), bottom: Double(b + 1) / Double(gh))
        let w = card.right - card.left, h = card.bottom - card.top
        guard card.right >= minRight, card.right <= maxRight, card.left >= cardLeft,
              w >= minWidth, w <= maxWidth, h >= minHeight, h <= maxHeight else { return nil }
        return card
    }

    /// Okumanın (satır kutuları `area`'ya oranlı) bildirim kartı blokları ile kalan satırları. `card`: blok kutusu
    /// (karede) için kartın karedeki yeri (`bounds`; `sampler`). Aynı karta düşen bloklar (başlık ve gövde) tek karttır.
    /// Kart blokları karede (satır kutuları kareye oranlı) döner; kalan satırlar okumadaki sırasıyla.
    public static func split(_ reading: Reading, in area: TextBox,
                             card: (TextBox) -> TextBox?) -> (kept: Reading, cards: [(block: Reading, card: TextBox)]) {
        guard !reading.lines.isEmpty, reading.lines.allSatisfy({ $0.box != nil }) else { return (reading, []) }
        var taken = Set<Int>()
        var cards: [(indices: [Int], card: TextBox)] = []
        var missed: [(block: [Int], box: TextBox)] = []
        for block in Reading.blocks(reading.lines, in: area) {
            let box = block.map { reading.lines[$0].box!.placed(in: area) }.reduce(nil as TextBox?) { $0?.union($1) ?? $1 }
            guard let box, isCandidate(box) else { continue }
            guard let found = card(box) else {
                missed.append((block, box))
                continue
            }
            if let at = cards.firstIndex(where: { overlaps($0.card, found) }) {
                cards[at].indices += block
                cards[at].card = cards[at].card.union(found)
            } else {
                cards.append((block, found))
            }
            taken.formUnion(block)
        }
        guard !cards.isEmpty else { return (reading, []) }
        // Kartın içinde kalan öteki blok (simgenin yanındaki kısa başlık) da o karttır; kendi başına kart aranamasa da.
        for entry in missed {
            guard let at = cards.firstIndex(where: { contains($0.card, entry.box) }) else { continue }
            cards[at].indices += entry.block
            taken.formUnion(entry.block)
        }
        let kept = Reading(lines: reading.lines.indices.filter { !taken.contains($0) }.map { reading.lines[$0] })
        return (kept, cards.map { entry in
            (Reading(lines: entry.indices.sorted().map { reading.lines[$0] }).placed(in: area), entry.card)
        })
    }

    /// Kutu kartın içinde mi (yazı tanımanın kutu payıyla).
    static func contains(_ card: TextBox, _ box: TextBox) -> Bool {
        let pad = 0.005
        return box.left >= card.left - pad && box.right <= card.right + pad && box.top >= card.top - pad && box.bottom <= card.bottom + pad
    }

    /// İki kart aynı mı: küçüğünün alanının en az yarısı kadar örtüşüyor.
    static func overlaps(_ a: TextBox, _ b: TextBox) -> Bool {
        let w = min(a.right, b.right) - max(a.left, b.left), h = min(a.bottom, b.bottom) - max(a.top, b.top)
        guard w > 0, h > 0 else { return false }
        let smaller = min((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top))
        return w * h >= 0.5 * smaller
    }

    /// Bütün kare için kart araması (`bounds`). Kare yalnız ilk soruda, ağ boyunda (`gridWidth` × `gridHeight`) bir kez
    /// çözülür; sağda aday blok yoksa hiç çözülmez.
    public static func sampler(_ frame: CGImage) -> (TextBox) -> TextBox? {
        var loaded = false
        var pixels: GamePhonePixels?
        return { box in
            guard isCandidate(box) else { return nil }
            if !loaded {
                loaded = true
                pixels = GamePhonePixels(frame, width: gridWidth, height: gridHeight)
            }
            guard let grid = pixels else { return nil }
            return bounds(around: box, width: grid.width, height: grid.height) { x, y in
                let i = (y * grid.width + x) * 4
                return (299 * Int(grid.bytes[i]) + 587 * Int(grid.bytes[i + 1]) + 114 * Int(grid.bytes[i + 2])) / 1000
            }
        }
    }
}
