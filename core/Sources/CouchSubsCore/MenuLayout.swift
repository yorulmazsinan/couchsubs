// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Menü ekranında çevirinin biçimi ayardan gelir, her okumada yeniden seçilmez (#1365, Ayarlar › Ekran yazıları ›
/// "Menülerde İngilizcenin üstünü ört"). beta.105 testinde GTA 6 haritasında aynı satır art arda okumalarda örtü, yan,
/// üst/alt ya da haritada yüzen ikiz kutu oluyordu (5 dakikada 237 yan, 139 örtü, 37 ikiz): `TextPainter` kipi satırın
/// çevresindeki boş alana ve zemin desenine göre seçiyor, kayan harita ve seçim çubuğu bunları her karede değiştiriyordu.
///
/// Menüdeki otomatik alanın çizimleri `TextPainter`'ın ölçtüğü örtü kutusu, zemin ve yazı rengiyle kalır; yalnız yerleşim
/// kilitlenir. Yerleşim yalnız yazıların kutularından çıkar (kare noktalarına bakılmaz): aynı ekran her okumada aynı çizilir.
/// - **B, üstünü ört (`cover`):** her yazı kendi yerinde, ölçülen zemin renginde örtülür; kartın başlığı ve metni ayrı
///   ayrı örtülür, kişi resmi ve simgeler açıkta kalır.
/// - **A, yanına yaz (varsayılan):** her satırın Türkçesi İngilizcesinin hemen yanına, koyu zeminli etikete (`label`)
///   yazılır: sola yaslı satırda sağına, sağa yaslı satırda (tuş çubuğu) soluna; satırın simgesi ve komşu yazılar
///   örtülmez. Yanına sığmayan etiket (sekme şeridi, sıkışık tuş çubuğu) altına, olmazsa üstüne yazılır; şeridin bir
///   sekmesi altına yazıldıysa öbür sekmeler de altına, biri hiçbir yere sığmazsa şeridin hepsi örtülür (şerit bir bütün).
///   Listede Türkçeler tek sütunda başlar (sola yaslı listede en uzun satırın sağında). Hiçbir yere sığmayan satır örtülür.
///   Haritanın görev kartının (`cards`) çevirisi kartın hemen altına (yer yoksa üstüne), kartın zemininde, kişi
///   resmiyle ikiz kart olarak gelir; ikisine de yer yoksa ya da kart bir listenin parçasıysa (Görevler ekranı: sol kenarı
///   kartla hizalı başka yazılar) kartın satırları da yanına yazılır.
/// - İki biçimde de satırın üstüne/altına küçük yazma, haritaya uzak ikiz kutu ve iki satırı tek kutuda birleştirme olmaz;
///   etiketler başka yazının ya da ikiz kartın üstüne binmez.
///
/// Kutular kareye oranla (0…1); `aspect`: karenin genişlik/yükseklik oranı (yatay paylar satır yüksekliğinden çevrilir).
/// Windows (MenuLayout.cs) ve Android (MenuLayout.kt) aynı kuralı, aynı eşikleri kullanır; ortak deneme dosyası
/// Fixtures/menu-layout.json.
public enum MenuLayout {
    /// Yanına yazılan Türkçenin etiket zemini (TV yarı saydam çizer, yazı açık renk).
    public static let labelColor = "#121419"
    /// Türkçe ile İngilizce (ya da satırın simgesi) arası, satır yüksekliğinin katı.
    public static let gapLines = 0.4
    /// Satırın yanındaki simge okunan kutuda değilse simge için bırakılan yer, satır yüksekliğinin katı.
    public static let iconLines = 1.2
    /// Yanına yazılan Türkçenin en çok uzayabileceği yer: İngilizcenin `besideMax` katı artı bir satır, en az `reachLines`.
    public static let besideMax = 1.6
    public static let reachLines = 12.0
    /// Yanında bu kadar yer (İngilizcenin genişliğinin payı) yoksa Türkçe altına/üstüne yazılır.
    public static let roomShare = 0.6
    /// Aynı satırda sayılmak için dikey örtüşme (kısa kutunun payı).
    public static let sameRow = 0.3
    /// Etiket bir yazıya ancak etiketin boyunun bu payından çok binerse çakışır (sıkışık listede komşu satırların okunan
    /// kutuları birkaç nokta örtüşür).
    public static let touchShare = 0.25
    /// Aynı satırda bu kadar yakın (satır yüksekliğinin katı) iki yazı tek şerittir: biri altına/üstüne yazıldıysa öbürü de.
    public static let stripGapLines = 4.0
    /// Ekran kenarından bırakılan pay, satır yüksekliğinin katı.
    public static let edgeLines = 0.2
    /// İkiz kartın kart yazılarının çevresindeki iç boşluğu ve kartla arası, satır yüksekliğinin katı.
    public static let cardPadLines = 0.5
    public static let cardGapLines = 0.3
    /// Kart dışı bir yazının sol kenarı kartınkine bu kadar yakınsa (satır yüksekliğinin katı) kart bir listenin parçasıdır.
    public static let columnLines = 1.0
    /// Alt alta iki satır bu kadar (satır yüksekliğinin katı) aralıkla aynı listenin sütunundadır.
    public static let columnGapLines = 1.5

    /// Menüdeki çizimler ayardaki biçime kilitlenir. `cards`: görev kartlarının parçaları (her kart için `paints`
    /// sıraları); `cover`: B (üstünü ört), false: A (yanına yaz). `portrait`: ikiz kurulacak kartın parçalarında kişi
    /// resmi yoksa kartın parçaları ve zemini verilip resim (kutusu ve kesilmiş görüntüsü) kareden aranır
    /// (`TextPainter.cardPortrait`; ikiz kart resimsiz kalmasın).
    public static func locked(_ paints: [TextPaint], targets: [TextPainter.Target], cards: [[Int]], cover: Bool,
                              aspect: Double,
                              portrait: (([Int], String) -> (box: TextBox, image: String?)?)? = nil) -> [TextPaint] {
        guard paints.count == targets.count, !paints.isEmpty else { return paints }
        var result = paints.map(plain)
        if cover { return result }
        let taken = paints.indices.map { paints[$0].cover.union(targets[$0].box) }
        var done = Set<Int>()
        var twins: [TextBox] = []
        for card in cards {
            // Kutusu boş (genişliği ya da yüksekliği olmayan) parça ikize girmez.
            let card = card.filter {
                $0 >= 0 && $0 < paints.count && !done.contains($0)
                    && paints[$0].cover.right - paints[$0].cover.left > 1e-9 && paints[$0].cover.bottom - paints[$0].cover.top > 1e-9
            }
            guard !card.isEmpty,
                  let made = cardTwin(card, paints: paints, targets: targets, taken: taken, twins: twins, aspect: aspect,
                                      portrait: portrait)
            else { continue }
            for (m, paint) in made { result[m] = paint }
            done.formUnion(card)
            twins.append(made[0].1.twin!)
        }
        var vertical = Set<Int>()
        let base = result
        for i in paints.indices where !done.contains(i) {
            let (paint, below) = beside(i, paints: paints, targets: targets, taken: taken, twins: twins, aspect: aspect,
                                        base: base[i], side: true)
            result[i] = paint
            if below { vertical.insert(i) }
        }
        let free = paints.indices.filter { !done.contains($0) }
        // Şerit bir bütün: aynı satırda yakın yazılar (sekme şeridi, tuş çubuğu) tek biçimde çizilir. Hepsi yanına sığıyorsa
        // yanına; değilse hepsi altına/üstüne; biri de sığmazsa hepsi örtülür (şeritte kimi Türkçe yanında, kimi altında, kimi
        // örtülü kalıyordu).
        for strip in strips(free, paints: paints, targets: targets, taken: taken, aspect: aspect) {
            if strip.count < 2 || strip.allSatisfy({ result[$0].mode == .beside && !vertical.contains($0) }) { continue }
            let tried = strip.map { beside($0, paints: paints, targets: targets, taken: taken, twins: twins, aspect: aspect,
                                           base: base[$0], side: false) }
            let below = tried.allSatisfy { $0.1 }
            for (k, i) in strip.enumerated() {
                result[i] = below ? tried[k].0 : base[i]
                if below { vertical.insert(i) } else { vertical.remove(i) }
            }
        }
        // Liste bir sütun: alt alta, aynı yana yaslı satırların yanına yazılan Türkçeleri tek sütunda başlar (sola yaslı
        // listede en uzun satırın sağında, sağa yaslı listede en uzun satırın solunda). Bir satıra orada yer yoksa liste
        // her satırın yanında kalır.
        let side = free.filter { result[$0].mode == .beside && !vertical.contains($0) && result[$0].spot != nil }
        for right in [false, true] {
            let members = side.filter { (targets[$0].align == .right) == right }
                .sorted { (paints[$0].cover.top, $0) < (paints[$1].cover.top, $1) }
            var used = Set<Int>()
            for start in members where !used.contains(start) {
                used.insert(start)
                var column = [start]
                for b in members where !used.contains(b) {
                    let last = column[column.count - 1]
                    let line = max(targets[last].lineHeight, targets[b].lineHeight)
                    let edgeA = right ? taken[start].right : taken[start].left
                    let edgeB = right ? taken[b].right : taken[b].left
                    if abs(edgeA - edgeB) <= columnLines * line / max(0.1, aspect),
                       paints[b].cover.top >= paints[last].cover.top,
                       paints[b].cover.top - paints[last].cover.bottom <= columnGapLines * line {
                        used.insert(b)
                        column.append(b)
                    }
                }
                guard column.count >= 2 else { continue }
                let x = right ? column.map { result[$0].spot!.right }.min()! : column.map { result[$0].spot!.left }.max()!
                let aligned = column.map {
                    besideAt($0, x: x, right: right, paints: paints, targets: targets, taken: taken, twins: twins,
                             aspect: aspect, current: result[$0])
                }
                guard aligned.allSatisfy({ $0 != nil }) else { continue }
                for (k, i) in column.enumerated() { result[i] = aligned[k]! }
            }
        }
        return result
    }

    /// Aynı satırda birbirine yakın (aralarında en çok `stripGapLines` satır) yazıların şeritleri; zincirleme (sekme şeridinin
    /// bütün sekmeleri). Sıra `free` sırası.
    static func strips(_ free: [Int], paints: [TextPaint], targets: [TextPainter.Target], taken: [TextBox],
                       aspect: Double) -> [[Int]] {
        var strips: [[Int]] = []
        var seen = Set<Int>()
        for start in free where !seen.contains(start) {
            seen.insert(start)
            var strip = [start]
            var q = 0
            while q < strip.count {
                let a = strip[q]
                q += 1
                for b in free where !seen.contains(b) {
                    let ca = paints[a].cover, cb = paints[b].cover
                    let lineX = max(1e-6, min(targets[a].lineHeight, targets[b].lineHeight)) / max(0.1, aspect)
                    if overlapY(ca, cb) >= sameRow * min(ca.bottom - ca.top, cb.bottom - cb.top),
                       max(0, max(taken[a].left, taken[b].left) - min(taken[a].right, taken[b].right)) <= stripGapLines * lineX {
                        seen.insert(b)
                        strip.append(b)
                    }
                }
            }
            strips.append(strip)
        }
        return strips
    }

    /// Satırın kendi kutusu simgesiyle birlikte (okunan kutu); simge okunmadıysa simge tarafına simge kadar yer.
    static func own(_ i: Int, paints: [TextPaint], taken: [TextBox], lineX: Double) -> TextBox {
        let c = paints[i].cover
        var own = taken[i]
        if paints[i].iconSide == .left, c.left - own.left < 0.5 * iconLines * lineX { own.left = c.left - iconLines * lineX }
        if paints[i].iconSide == .right, own.right - c.right < 0.5 * iconLines * lineX { own.right = c.right + iconLines * lineX }
        return own
    }

    /// Satırın engelleri: öbür yazıların kutuları (sırasıyla) ve ikiz kartlar (sıra -1).
    static func others(_ i: Int, taken: [TextBox], twins: [TextBox]) -> [(j: Int, box: TextBox)] {
        taken.indices.filter { $0 != i }.map { (j: $0, box: taken[$0]) } + twins.map { (j: -1, box: $0) }
    }

    /// Yanına yazılan Türkçenin `start`'tan (sola yaslıda sol kenarı, sağa yaslıda sağ kenarı) uzayabileceği son nokta:
    /// ekranın kenarı, en çok erişim, satırdaki yazı ya da ikiz kart. Karşıdan bakan komşu (sola yaslı satırın sağında sağa
    /// yaslı değer, "STYLE … SOUVENIR") arayı ortadan böler; ikisinin Türkçesi üst üste binmez.
    static func limit(_ i: Int, start: Double, right: Bool, own: TextBox, paints: [TextPaint], targets: [TextPainter.Target],
                      others: [(j: Int, box: TextBox)], aspect: Double) -> Double {
        let c = paints[i].cover
        let lineX = max(1e-6, targets[i].lineHeight) / max(0.1, aspect)
        let gap = gapLines * lineX, edge = edgeLines * lineX, eps = 1e-9, w = c.right - c.left
        let reach = max(besideMax * w + lineX, reachLines * lineX)
        let touch = touchShare * (c.bottom - c.top)
        if !right {
            var limit = min(1 - edge, start + reach)
            for o in others where overlapY(o.box, c) > touch && o.box.right > start {
                let facing = o.j >= 0 && targets[o.j].align == .right && o.box.left >= own.right - eps
                limit = min(limit, facing ? (own.right + o.box.left - gap) / 2 : o.box.left - gap)
            }
            return limit
        }
        var low = max(edge, start - reach)
        for o in others where overlapY(o.box, c) > touch && o.box.left < start {
            let facing = o.j >= 0 && targets[o.j].align != .right && o.box.right <= own.left + eps
            low = max(low, facing ? (o.box.right + own.left + gap) / 2 : o.box.right + gap)
        }
        return low
    }

    /// Yanına yazma, Türkçe `x`'te başlarken (sola yaslıda sol kenarı, sağa yaslıda sağ kenarı; listenin sütunu): engeller
    /// `limit` ile aynı; yer yoksa nil.
    static func besideAt(_ i: Int, x: Double, right: Bool, paints: [TextPaint], targets: [TextPainter.Target], taken: [TextBox],
                         twins: [TextBox], aspect: Double, current: TextPaint) -> TextPaint? {
        let c = paints[i].cover
        let lineX = max(1e-6, targets[i].lineHeight) / max(0.1, aspect)
        let w = c.right - c.left
        let reach = max(besideMax * w + lineX, reachLines * lineX)
        let end = limit(i, start: x, right: right, own: own(i, paints: paints, taken: taken, lineX: lineX), paints: paints,
                        targets: targets, others: others(i, taken: taken, twins: twins), aspect: aspect)
        guard abs(end - x) >= roomShare * min(w, reach), right ? end <= x : end >= x else { return nil }
        var p = current
        if right {
            p.spot = TextBox(left: max(end, x - w), top: c.top, right: x, bottom: c.bottom)
            p.spotRoom = TextBox(left: end, top: c.top, right: x, bottom: c.bottom)
        } else {
            p.spot = TextBox(left: x, top: c.top, right: min(end, x + w), bottom: c.bottom)
            p.spotRoom = TextBox(left: x, top: c.top, right: end, bottom: c.bottom)
        }
        return p
    }

    /// Ölçülen örtü, zemin ve yazı rengi kalır; kip örtmeye döner, yanına yazma ve ikiz alanları silinir.
    static func plain(_ paint: TextPaint) -> TextPaint {
        var p = paint
        p.mode = .cover
        p.spot = nil
        p.spotRoom = nil
        p.twin = nil
        p.radius = 0
        p.scale = 1
        p.tail = nil
        p.portrait = nil
        p.portraitTwin = nil
        p.portraitImage = nil
        p.portraitSquare = false
        p.edge = nil
        p.label = nil
        return p
    }

    static func overlapY(_ a: TextBox, _ b: TextBox) -> Double { max(0, min(a.bottom, b.bottom) - max(a.top, b.top)) }

    static func overlaps(_ a: TextBox, _ b: TextBox) -> Bool {
        min(a.right, b.right) > max(a.left, b.left) && min(a.bottom, b.bottom) > max(a.top, b.top)
    }

    static func shifted(_ box: TextBox, dy: Double) -> TextBox {
        TextBox(left: box.left, top: box.top + dy, right: box.right, bottom: box.bottom + dy)
    }

    /// A: satırın Türkçesi yanında (yer yoksa altında ya da üstünde), koyu etikette; hiçbir yere sığmazsa örtü (`base`).
    /// `side`: false ise yanı denenmez (şeridin öbür sekmeleri). İkinci değer: Türkçe altına/üstüne yazıldı.
    static func beside(_ i: Int, paints: [TextPaint], targets: [TextPainter.Target], taken: [TextBox], twins: [TextBox],
                       aspect: Double, base: TextPaint, side: Bool) -> (TextPaint, Bool) {
        let c = paints[i].cover
        let lineY = max(1e-6, targets[i].lineHeight)
        let lineX = lineY / max(0.1, aspect)
        let gap = gapLines * lineX, edge = edgeLines * lineX, eps = 1e-9
        let w = c.right - c.left, h = c.bottom - c.top
        // Genişliği ya da yüksekliği olmayan kutu (bozuk okuma) yanına yazılmaz.
        guard w > eps, h > eps else { return (base, false) }
        let reach = max(besideMax * w + lineX, reachLines * lineX)
        let own = Self.own(i, paints: paints, taken: taken, lineX: lineX)
        let others = Self.others(i, taken: taken, twins: twins)
        var p = base
        p.mode = .beside
        p.label = labelColor
        let touch = touchShare * h
        if side && targets[i].align != .right {
            let left = own.right + gap
            let end = limit(i, start: left, right: false, own: own, paints: paints, targets: targets, others: others, aspect: aspect)
            if end - left >= roomShare * min(w, reach) {
                p.spot = TextBox(left: left, top: c.top, right: min(end, left + w), bottom: c.bottom)
                p.spotRoom = TextBox(left: left, top: c.top, right: end, bottom: c.bottom)
                return (p, false)
            }
        } else if side {
            let right = own.left - gap
            let end = limit(i, start: right, right: true, own: own, paints: paints, targets: targets, others: others, aspect: aspect)
            if right - end >= roomShare * min(w, reach) {
                p.spot = TextBox(left: max(end, right - w), top: c.top, right: right, bottom: c.bottom)
                p.spotRoom = TextBox(left: end, top: c.top, right: right, bottom: c.bottom)
                return (p, false)
            }
        }
        // Yanına sığmayan etiket (sekme şeridinin sekmesi, sıkışık tuş çubuğu) altına, olmazsa üstüne; aynı satırdaki
        // komşularla arasının ortasını geçmez (komşunun etiketiyle arada boşluk kalır), başka yazının üstüne binmez, uzadığı
        // alan da o bantta başka yazıya varmaz.
        let mates = paints.indices.filter { j in
            j != i && overlapY(c, paints[j].cover) >= sameRow * min(h, paints[j].cover.bottom - paints[j].cover.top)
        }
        var l = max(edge, own.left - 0.5 * w), r = min(1 - edge, own.right + 0.5 * w)
        for j in mates {
            let o = taken[j]
            if o.left >= own.right - eps { r = min(r, (own.right + o.left) / 2 - gap) }
            else if o.right <= own.left + eps { l = max(l, (o.right + own.left) / 2 + gap) }
        }
        let step = gapLines * lineY
        for top in [own.bottom + step, own.top - step - h] {
            let spot = TextBox(left: c.left, top: top, right: c.right, bottom: top + h)
            guard spot.top >= 0, spot.bottom <= 1 else { continue }
            let hit = others.contains { o in
                min(o.box.right, spot.right) > max(o.box.left, spot.left) && overlapY(o.box, spot) > touch
            }
            guard !hit else { continue }
            var bandLeft = l, bandRight = r
            for o in others where overlapY(o.box, spot) > touch {
                if o.box.right <= c.left + eps { bandLeft = max(bandLeft, o.box.right + gap) }
                else if o.box.left >= c.right - eps { bandRight = min(bandRight, o.box.left - gap) }
            }
            p.spot = spot
            p.spotRoom = TextBox(left: min(bandLeft, c.left), top: top, right: max(bandRight, c.right), bottom: top + h)
            return (p, true)
        }
        return (base, false)
    }

    /// A: görev kartının ikizi kartın hemen altında (yer yoksa üstünde), kartın zemininde; başka yazının ya da ikizin
    /// üstüne binmez. İkisine de yer yoksa ya da kart bir listenin parçasıysa nil (kartın satırları yanına yazılır; Görevler
    /// ekranında son görev ikiz kart, öbürleri yanında çiziliyordu).
    static func cardTwin(_ card: [Int], paints: [TextPaint], targets: [TextPainter.Target], taken: [TextBox],
                         twins: [TextBox], aspect: Double,
                         portrait: (([Int], String) -> (box: TextBox, image: String?)?)? = nil) -> [(Int, TextPaint)]? {
        let heights = card.map { targets[$0].lineHeight }.sorted()
        let line = max(1e-6, heights[heights.count / 2])
        let padY = cardPadLines * line, padX = padY / max(0.1, aspect)
        let left = card.map { taken[$0].left }.min()!
        if paints.indices.contains(where: { !card.contains($0) && abs(taken[$0].left - left) <= columnLines * line / max(0.1, aspect) }) {
            return nil
        }
        // Kartın zemini: en büyük parçanın (açıklama) ölçülen zemini.
        func area(_ b: TextBox) -> Double { (b.right - b.left) * (b.bottom - b.top) }
        let largest = card.max { area(paints[$0].cover) < area(paints[$1].cover) }!
        let fill = paints[largest].background
        // Kişi resmi: ölçümün bulduğu ya da kareden aranan; ikizde kartın bütün parçalarında aynı (TV ilkinden çizer).
        var face = card.lazy.compactMap { paints[$0].portrait }.first
        var image = card.lazy.compactMap { paints[$0].portraitImage }.first
        if face == nil, let found = portrait?(card, fill) {
            face = found.box
            image = found.image
        }
        var union = taken[card[0]]
        for m in card { union = union.union(taken[m]) }
        if let face { union = union.union(face) }
        let box = TextBox(left: union.left - padX, top: union.top - padY, right: union.right + padX, bottom: union.bottom + padY)
        let step = (box.bottom - box.top) + cardGapLines * line
        let blockers = paints.indices.filter { !card.contains($0) }.map { taken[$0] } + twins
        func free(_ b: TextBox) -> Bool {
            b.top >= 0 && b.bottom <= 1 && b.left >= 0 && b.right <= 1 && !blockers.contains { overlaps($0, b) }
        }
        let dy: Double
        if free(shifted(box, dy: step)) { dy = step }
        else if free(shifted(box, dy: -step)) { dy = -step }
        else { return nil }
        let twin = shifted(box, dy: dy)
        return card.map { m in
            var p = plain(paints[m])
            p.mode = .twin
            p.twin = twin
            p.radius = paints[m].radius
            p.background = fill
            p.background2 = nil
            p.direction = nil
            p.patterned = false
            let spot = shifted(paints[m].cover, dy: dy)
            p.spot = spot
            p.spotRoom = TextBox(left: spot.left, top: spot.top, right: max(spot.right, twin.right - padX), bottom: spot.bottom)
            if let face {
                p.portrait = face
                p.portraitTwin = shifted(face, dy: dy)
                p.portraitImage = image
                p.portraitSquare = true
            }
            p.edge = paints[m].edge
            return (m, p)
        }
    }
}
