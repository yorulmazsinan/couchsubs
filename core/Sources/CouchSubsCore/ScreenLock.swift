// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Ekran kilidi (Sinan Bey: "stabil olsun artık"). Bütün ekran okuması (250–500 ms'de bir) her turda her bloğun kutusuna
/// yeniden karar veriyordu: kutular titriyor, yer değiştiriyor, kalkıp geliyor, yazılar birbirinin yerine geçiyordu.
/// Ekran yazısı katmanı (otomatik ekran yazısı; altyazı, görev kutusu `MissionLine.areaId`, kenar bildirimi ve telefon
/// hariç) artık kilitlenir:
/// - Kilit: blokların kümesi art arda `steadyPasses` turda aynı (aynı yazılar aşağı yukarı aynı yerlerde) okununca o
///   ekranın düzeni kilitlenir. Her blok bir yuvadır; kutusu, yeri, boyu ve çevirisi sabittir.
/// - Küçük değişiklik (imleç gezdi, sayaç/saat ilerledi, bir bloğun yazısı biraz değişti): kutu taşınmaz, eklenmez,
///   kalkmaz. Yalnız var olan kutunun yazısı güncellenir, o da yuvanın okuması `steadyPasses` tur aynı kaldıysa.
/// - Açılma: blokların `changeShare` kadarı gitti/yeni geldi/yerinde başka yazı oldu, ya da düzen tutmuyor (aynı yazılar
///   başka yerde); art arda `changePasses` turda. Ekran yazısı `emptyMs`'ten uzun kalkınca da açılır, katman temizlenir.
/// - Ekran önbelleği: kilitli ekranın yuvaları (çevirileri ve kutularıyla) yazılarının sadeleştirilmiş kümesiyle saklanır;
///   aynı ekrana (menüye) dönülünce aynı çeviriler aynı kutularda hemen çizilir.
/// - Her kilit ve açılış günlüğe nedeni ve blok sayısıyla bir satır yazılır.
/// - Hazır alanlar da (#1391, `preset-*`: GTA 6 sol üstteki yardım ve sağdaki mesaj alanı) kilidin altında: harita ve görev
///   listesi menü durumu bir an kapanınca hazır alandan, sonra yine otomatik alandan okunuyor; hazır alanın kutuları
///   kilitsiz kalıp her turda yeniden karar veriliyor, otomatik alanın kutularının üstüne biniyordu (beta.108).
/// - Yollar arası çakışma (#1391): aynı yeri iki yol (görev kutusu, otomatik ekran yazısı, hazır alan) birden çizerse
///   sabit öncelikle (`rank`) yalnız biri kalır: görev kutusu > otomatik ekran yazısı > hazır alan. Kilide giren bloklar da
///   aynı öncelikle birleşir (`merge`): iki yolun okuduğu aynı satır tek blok sayılır.
/// Yalnız gönderilenleri süzer: okuma, çeviri ve çizim ölçümü `RegionWatcher`'da olduğu gibi sürer. Windows
/// (ScreenLock.cs) ve Android (ScreenLock.kt) aynı kurallar.
@MainActor
final class ScreenLock {
    /// Kilidin altındaki alan: otomatik ekran yazısı; görev kutusu ve kenar bildirimi kendi yuvasında kalır.
    static func covers(_ id: String) -> Bool {
        (id.hasPrefix("auto-") || GameAreaPresets.isPreset(id)) && id != MissionLine.areaId && !ScreenNotices.isNotice(id: id)
    }

    /// Kilidin altındaki alan; `routes` kapalıyken (beta.108 davranışı, yalnız denemelerin önce/sonra sayısı) hazır alan
    /// kilide girmez.
    func covers(_ id: String) -> Bool {
        Self.covers(id) && (routes || !GameAreaPresets.isPreset(id))
    }

    /// Hazır alanlar kilide girer ve yollar arası çakışma çözülür (#1391). false yalnız denemelerde (beta.108 davranışı).
    var routes = true

    /// Yolun önceliği (küçük olan kalır): görev kutusu, otomatik ekran yazısı, hazır alan, diğer.
    static func rank(_ id: String) -> Int {
        if id == MissionLine.areaId { return 0 }
        if id.hasPrefix("auto-") { return 1 }
        if GameAreaPresets.isPreset(id) { return 2 }
        return 3
    }

    /// Kilidin dışında kalıp yine de üstüne çizilmeyecek yol (görev kutusu).
    static func blocks(_ id: String) -> Bool { id == MissionLine.areaId }

    /// Başka yolun kutusuyla (küçüğünün alanına oranla) en az bu kadar örtüşen kutu çakışır.
    static let routeOverlap = 0.1

    /// Öğenin TV'de kapladığı yerler: özgün yazının kutusu, örtüsü, yanına yazılan ya da ikiz kutusu.
    static func footprint(_ item: ScreenTranslation.Item) -> [TextBox] {
        [item.box] + [item.paint?.cover, item.paint?.spot, item.paint?.twin].compactMap { $0 }
    }

    static func footprints(_ payload: Payload) -> [[TextBox]] {
        if let items = payload.blocks, !items.isEmpty { return items.map(footprint) }
        return payload.box.map { [[$0]] } ?? []
    }

    static func clash(_ a: [TextBox], _ b: [TextBox]) -> Bool {
        a.contains { x in b.contains { overlap(x, $0) >= routeOverlap } }
    }

    /// Turun blokları alan alan: yüksek öncelikli yolun bloğuyla aynı yerdeki alçak yol bloğu atılır (aynı satırı iki yol
    /// okudu). Aynı öncelikteki alanlar olduğu gibi kalır.
    func merge(_ areas: [(id: String, blocks: [Block])]) -> [Block] {
        guard routes else { return areas.flatMap(\.blocks) }
        var kept: [(rank: Int, box: TextBox)] = []
        var result: [Block] = []
        for area in areas.sorted(by: { (Self.rank($0.id), $0.id) < (Self.rank($1.id), $1.id) }) {
            let rank = Self.rank(area.id)
            let fresh = area.blocks.filter { block in
                !kept.contains { $0.rank < rank && Self.overlap($0.box, block.box) >= Self.routeOverlap }
            }
            kept += fresh.map { (rank, $0.box) }
            result += fresh.map { block in
                var block = block
                block.route = rank
                return block
            }
        }
        return result
    }

    /// Okunan blok: sadeleştirilmiş yazısı ve karedeki yeri.
    struct Block: Equatable {
        var key: String
        var box: TextBox
        /// Bloğu okuyan yolun önceliği (`rank`; `merge` yazar).
        var route = 1
    }

    /// TV'ye gidecek alan içeriği (`RegionSending.sendRegion`).
    struct Payload: Equatable {
        var text: String
        var box: TextBox?
        var lineHeight: Double?
        var icons: [IconPlacement]?
        var blocks: [ScreenTranslation.Item]?
    }

    /// Gönderilecek alan; `payload` nil ise kutu kalkar. `forget`: kilit alanı izleyicinin bilmeden temizledi, izleyici
    /// alanın gösterilen durumunu unutmalı (yazı geri gelince yeniden çizilsin).
    struct Send: Equatable {
        var id: String
        var payload: Payload?
        var forget = false
    }

    /// Kilit için art arda aynı okunması gereken tur; kilitliyken yazı güncellemesi için de.
    static let steadyPasses = 2
    /// Blokların bu payı gitti, yeni geldi ya da yerinde başka yazı varsa ekran değişmiştir.
    static let changeShare = 0.35
    /// Ekran değişikliği art arda bu kadar turda görülürse kilit açılır (tek turluk bozuk okuma açmaz).
    static let changePasses = 2
    /// Ekran yazısı bundan uzun kalkarsa kilit açılır, katman temizlenir.
    static let emptyMs = 1000
    /// İki kutu (küçüğünün alanına oranla) en az bu kadar örtüşüyorsa aynı yerdir.
    static let samePlace = 0.5
    /// Saklanan en çok ekran sayısı.
    static let cacheLimit = 16
    /// Yeri okunmayan yuva (#1391: GTA 6 haritasında menü durumu bir an kapanınca menü alanları kalkıyor, hazır alan
    /// okuyordu) bu kadar süre ekran değişikliğine sayılmaz; daha uzun sürerse gitmiş sayılır.
    static let unreadMs = 1500

    struct Slot: Equatable {
        var key: String
        var box: TextBox
        /// Yuvayı okuyan yolun önceliği: daha alçak yol (hazır alan) bu yuvayı doldurmaz, yazısını değiştirmez (#1391:
        /// hazır alanın kesik okuması "Keep an eye or" görev listesinin satırına yazılıyordu).
        var route = 1
        /// Okumadan gelen yuva (kilitlendiği ekranın bloğu); false: kilitlendiğinde çizili duran, okumada olmayan kutu.
        var observed = true
        var id: String?
        var item: ScreenTranslation.Item?
        /// Yuvanın yerinde son okunan yazı ve kaç turdur aynı okunduğu.
        var seen: String
        var seenPasses: Int
        /// Okuması henüz kararlı olmadığı için bekletilen yazı güncellemesi.
        var pending: ScreenTranslation.Item?
        /// Yuvanın yeri bu turdan beri okunan hiçbir alanın içinde değil (dedektör alanı bir an önermedi, `unreadMs`).
        var unreadSince: Int?
    }

    private struct Saved {
        var slots: [Slot]
        var frames: [String: Payload]
    }

    private(set) var locked = false
    private(set) var slots: [Slot] = []
    private var previous: [Block]?
    private var emptySince: Int?
    private var changing = 0
    /// Değişen ekranın bir önceki turdaki okuması (değişiklik iki turdur aynıysa yeni ekran açılışta hemen kilitlenir).
    private var changingTo: [Block]?
    private var lockKey = ""
    /// İzleyicinin her alan için son göndermek istediği (kilit açılınca bu gösterilir).
    private var intended: [String: Payload] = [:]
    /// TV'de şu an duran.
    private(set) var displayed: [String: Payload] = [:]
    /// Alanın kutu dışı alanları (birleşik kutu, satır yüksekliği, simgeler) kilitli çizimde.
    private var frames: [String: Payload] = [:]
    private var cache: [String: Saved] = [:]
    private var cacheOrder: [String] = []
    /// Kilidin dışındaki öncelikli yolların (görev kutusu) TV'de duran kutuları (`block`).
    private var blockers: [String: Payload] = [:]
    /// Tanı (#1391): son yazılan yol çakışması ve bir an okunmayan yuva sayısı (değişince bir satır).
    private var routeLogged = ""
    private var unreadLogged = 0
    /// Son çözümde öncelikli yolun altında kalıp çizilmeyen öğe sayısı, alan alan.
    private var hidden: [String: Int] = [:]
    var onLog: ((String) -> Void)?
    /// Sayaçlar (günlük ve denemeler için).
    private(set) var locks = 0
    private(set) var unlocks = 0
    private(set) var cacheHits = 0

    /// Katmanda çizili bir şey var mı (kilitliyken izleyici turu sürdürür).
    var holds: Bool { locked || !displayed.isEmpty }

    static func key(_ text: String) -> String { RegionWatcher.textKey([IconText.plain(text)]) }

    static func similar(_ a: String, _ b: String) -> Bool {
        a == b || TextMatch.isSimilar(a, b, threshold: 0.75)
    }

    /// Küçüğünün alanına oranla örtüşme.
    static func overlap(_ a: TextBox, _ b: TextBox) -> Double {
        let w = min(a.right, b.right) - max(a.left, b.left)
        let h = min(a.bottom, b.bottom) - max(a.top, b.top)
        guard w > 0, h > 0 else { return 0 }
        let small = min((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top))
        return small > 0 ? w * h / small : 0
    }

    /// İki okumanın farkı: gelmeyen, yeni, yerinde başka yazı olan ve başka yere kaymış blok sayısı; pay büyüğüne oranla.
    struct Diff: Equatable {
        var gone = 0
        var fresh = 0
        var changed = 0
        var moved = 0
        var total = 0
        var share: Double { total == 0 ? 0 : Double(gone + fresh + changed) / Double(total) }
    }

    /// Biri ötekinin parçası (#1391: menü durumu bir an kapanınca aynı paragraf satır satır okunuyor, "keep an eye on the
    /// bachelor party" ile "...while searching ... treasure" aynı yazıdır). En az 4 harf.
    static func part(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.contains(short)
    }

    static func diff(_ old: [Block], _ new: [Block]) -> Diff {
        var used = Set<Int>()
        var result = Diff(total: max(old.count, new.count))
        for block in old {
            var best: Int?
            var bestOverlap = samePlace
            for (j, other) in new.enumerated() where !used.contains(j) {
                let o = overlap(block.box, other.box)
                if o >= bestOverlap { best = j; bestOverlap = o }
            }
            if let best {
                used.insert(best)
                if !similar(block.key, new[best].key) && !part(block.key, new[best].key) { result.changed += 1 }
            } else {
                result.gone += 1
                if new.contains(where: { similar($0.key, block.key) }) { result.moved += 1 }
            }
        }
        // Eski bir bloğun yerinde onun parçası olan blok yeni sayılmaz (aynı yazı başka satırlara bölündü).
        result.fresh = new.indices.filter { j in
            !used.contains(j) && !old.contains { overlap($0.box, new[j].box) >= samePlace && part($0.key, new[j].key) }
        }.count
        return result
    }

    /// Ekranın önbellek anahtarı: yazıların sadeleştirilmiş kümesi.
    static func screenKey(_ blocks: [Block]) -> String {
        Set(blocks.map(\.key).filter { !$0.isEmpty }).sorted().joined(separator: "\u{1F}")
    }

    /// İzleyici bir alanı göndermek istiyor (`payload` nil: kutu kalkar). Gönderilecekleri döndürür.
    func offer(id: String, payload: Payload?) -> [Send] {
        intended[id] = payload
        guard locked else {
            // Kilit yokken gönderi geçer; yollar arası çakışmada öncelikli yol kalır (`resolved`).
            guard routes else {
                displayed[id] = payload
                return [Send(id: id, payload: payload)]
            }
            return publish()
        }
        // Kilitliyken kutu kalkmaz; yeni kutu eklenmez; bloksuz gönderi kilidin dışında kalır.
        guard let payload, let items = payload.blocks, !items.isEmpty else { return [] }
        if frames[id] == nil { frames[id] = Payload(text: "", box: payload.box, lineHeight: payload.lineHeight, icons: payload.icons) }
        var touched = Set<String>()
        for item in items {
            guard let s = slot(for: item.box, route: routes ? Self.rank(id) : 0) else { continue }
            if slots[s].item == nil {
                // Kilitli düzenin henüz çevirisi gelmemiş yuvası: bir kez dolar (yeri yuvanın).
                slots[s].item = item
                slots[s].id = id
                touched.insert(id)
                continue
            }
            guard let current = slots[s].item, current.translation != item.translation || current.icons != item.icons else {
                // Yazı aynı; seçim gezdiyse (#1267) yalnız renkler güncellenir, kutu yerinde kalır.
                slots[s].pending = nil
                if let current = slots[s].item, let fresh = Self.recoloured(current, item) {
                    slots[s].item = fresh
                    touched.insert(slots[s].id ?? id)
                }
                continue
            }
            if steady(slots[s], item) {
                apply(item, to: s)
                touched.insert(slots[s].id ?? id)
            } else {
                slots[s].pending = item
            }
        }
        return routes ? renderAll(touched) : touched.sorted().compactMap(render)
    }

    /// Alanın yazısı kesin gitti (hazır alanın arayüz kutusu `panelMissTurns` tur bulunamadı): kilitliyken de kutuları
    /// kalkar, yuvaları düzenden çıkar. Gönderilecekleri döndürür.
    func withdraw(id: String) -> [Send] {
        guard routes else { return offer(id: id, payload: nil) }
        intended[id] = nil
        guard locked else { return publish() }
        slots.removeAll { $0.id == id }
        frames[id] = nil
        var sends: [Send] = []
        if displayed.removeValue(forKey: id) != nil { sends.append(Send(id: id, payload: nil)) }
        // Kilitli ekranın bütün yazısı bu alanındı: kilit açılır.
        guard slots.contains(where: \.observed) else { return sends + unlock(reason: "\(id) alanının yazısı gitti", clear: false) }
        return sends + renderAll([])
    }

    /// Kilidin dışındaki öncelikli yol (görev kutusu) TV'ye gitti ya da kalktı: onunla çakışan ekran yazısı çizilmez,
    /// kalkınca yeniden çizilir. Gönderilecekleri döndürür (öncelikli yolun kendi gönderisi izleyicide).
    func block(id: String, payload: Payload?) -> [Send] {
        guard routes, blockers[id] != payload else { return [] }
        blockers[id] = payload
        return locked ? renderAll([]) : publish()
    }

    /// Turun sonu: bu turda okunan bütün ekran yazısı blokları. Kilitlenir, açılır ya da bekleyen yazı güncellenir.
    /// `read`: bu turda yazı okunan alanların yeri ve yolu (`Block.box`, `Block.route`; nil: bütün ekran okundu). Yuvanın
    /// yeri kendi yolundan ya da daha öncelikli yoldan okunmadıysa yuva `unreadMs` dolana dek ekran değişikliğine sayılmaz.
    func observe(_ blocks: [Block], at now: Int, read: [Block]? = nil) -> [Send] {
        if blocks.isEmpty {
            previous = nil
            let since = emptySince ?? now
            emptySince = since
            guard locked, now - since > Self.emptyMs else { return [] }
            return unlock(reason: "ekran yazısı \(Self.emptyMs / 1000) sn'den uzun yok, katman temizlendi", clear: true)
        }
        emptySince = nil
        if locked {
            for s in slots.indices where slots[s].observed {
                let read = blocks.filter { $0.route <= slots[s].route && Self.overlap($0.box, slots[s].box) >= Self.samePlace }
                    .max { Self.overlap($0.box, slots[s].box) < Self.overlap($1.box, slots[s].box) }
                guard let read else {
                    slots[s].seenPasses = 0
                    continue
                }
                if read.key == slots[s].seen { slots[s].seenPasses += 1 } else {
                    slots[s].seen = read.key
                    slots[s].seenPasses = 1
                }
            }
            for s in slots.indices {
                let unread = read.map { areas in
                    !areas.contains { $0.route <= slots[s].route && Self.overlap(slots[s].box, $0.box) >= Self.samePlace }
                } ?? false
                slots[s].unreadSince = unread ? (slots[s].unreadSince ?? now) : nil
            }
            let layout = slots.filter { $0.observed && $0.unreadSince.map { now - $0 > Self.unreadMs } ?? true }
                .map { Block(key: $0.key, box: $0.box) }
            // Kilitli ekranı kuran yoldan alçak yolun okuması (hazır alanın menü satırından kestiği parça, menü dışı okunan
            // harita tuşu) ekran değişikliğine kanıt sayılmaz (#1391); yalnız kendi yolunun yuvasının üstündeki okuması
            // sayılır. Kuran yol okumazsa yuvaları `unreadMs` sonra gitmiş sayılır.
            let top = slots.filter(\.observed).map(\.route).min() ?? Int.max
            let evidence = routes
                ? blocks.filter { block in
                    block.route <= top || slots.contains {
                        $0.observed && $0.route == block.route && Self.overlap($0.box, block.box) >= Self.samePlace
                    }
                }
                : blocks
            let held = routes ? slots.filter { $0.observed && $0.unreadSince.map { now - $0 <= Self.unreadMs } ?? false }.count : 0
            if held != unreadLogged {
                if held > 0 { onLog?("ekran yazısı yolları: \(held) blok bir an okunmadı (alan önerilmedi ya da boş okundu), kilit korunuyor") }
                unreadLogged = held
            }
            let diff = Self.diff(layout, evidence)
            if diff.share >= Self.changeShare {
                // Ekran değişiyor: bekleyen yazı uygulanmaz; değişiklik sürerse kilit açılır.
                changing += 1
                let settled = changingTo.map { $0.count == blocks.count && Self.diff($0, blocks).share == 0 } ?? false
                changingTo = blocks
                guard changing >= Self.changePasses else { return [] }
                let reason = diff.moved > 0 && diff.moved == diff.gone && diff.fresh == diff.moved
                    ? "yerleşim değişti (\(diff.moved) blok başka yerde)"
                    : "ekran değişti (\(diff.gone) blok gitti, \(diff.fresh) yeni, \(diff.changed) blokta başka yazı)"
                previous = blocks
                return unlock(reason: reason, clear: false, next: blocks, settled: settled)
            }
            changing = 0
            changingTo = nil
            var touched = Set<String>()
            for s in slots.indices {
                if let pending = slots[s].pending, steady(slots[s], pending) {
                    apply(pending, to: s)
                    if let id = slots[s].id { touched.insert(id) }
                }
            }
            save()
            return routes ? renderAll(touched) : touched.sorted().compactMap(render)
        }
        if let saved = cached(blocks) {
            previous = blocks
            return restore(saved, key: Self.screenKey(blocks), count: blocks.count)
        }
        defer { previous = blocks }
        guard let previous, previous.count == blocks.count, Self.diff(previous, blocks).share == 0 else { return [] }
        lock(blocks)
        return []
    }

    /// Kilit dışarıdan bırakıldı (telefon açıldı, ayar değişti): gösterilenler unutulur, önbellek kalır.
    func release(reason: String) {
        if locked {
            unlocks += 1
            onLog?("ekran kilidi açıldı: \(reason), \(slots.count) blok")
            save()
        }
        locked = false
        slots = []
        previous = nil
        emptySince = nil
        changing = 0
        changingTo = nil
        intended.removeAll()
        displayed.removeAll()
        frames.removeAll()
    }

    /// Oturum bitti: önbellek de unutulur.
    func reset() {
        release(reason: "çeviri durdu")
        blockers.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - İç işler

    private func lock(_ blocks: [Block]) {
        locked = true
        locks += 1
        changing = 0
        lockKey = Self.screenKey(blocks)
        slots = blocks.map { Slot(key: $0.key, box: $0.box, route: $0.route, seen: $0.key, seenPasses: Self.steadyPasses) }
        frames.removeAll()
        // Çizili kutular yuvalarına oturur; yuvası olmayan çizili kutu da yerinde kalır (kendi yuvası olur).
        for (id, payload) in displayed.sorted(by: { $0.key < $1.key }) {
            frames[id] = Payload(text: "", box: payload.box, lineHeight: payload.lineHeight, icons: payload.icons)
            for item in payload.blocks ?? [] {
                if let s = slot(for: item.box, route: routes ? Self.rank(id) : 0), slots[s].item == nil {
                    slots[s].item = item
                    slots[s].id = id
                } else {
                    let key = Self.key(item.source)
                    slots.append(Slot(key: key, box: item.box, route: Self.rank(id), observed: false, id: id, item: item, seen: key,
                                      seenPasses: 0))
                }
            }
        }
        onLog?("ekran kilidi: kilitlendi, \(blocks.count) blok (\(slots.filter { $0.item != nil }.count) çevirili)")
        save()
    }

    private func restore(_ saved: Saved, key: String, count: Int) -> [Send] {
        locked = true
        locks += 1
        cacheHits += 1
        changing = 0
        lockKey = key
        slots = saved.slots.map { slot in
            var slot = slot
            slot.seen = slot.key
            slot.seenPasses = Self.steadyPasses
            slot.pending = nil
            slot.unreadSince = nil
            return slot
        }
        frames = saved.frames
        onLog?("ekran kilidi: önbellekten kilitlendi (aynı ekrana dönüldü), \(count) blok")
        var sends: [Send] = []
        let ids = Set(slots.compactMap(\.id))
        for id in displayed.keys.sorted() where !ids.contains(id) {
            displayed[id] = nil
            intended[id] = nil
            sends.append(Send(id: id, payload: nil, forget: true))
        }
        sends += ids.sorted().compactMap(render)
        return sends
    }

    /// Önbellekte bu ekran var ve düzeni tutuyor (aynı yazılar aşağı yukarı aynı yerlerde).
    private func cached(_ blocks: [Block]) -> Saved? {
        guard let saved = cache[Self.screenKey(blocks)], saved.slots.contains(where: { $0.item != nil }) else { return nil }
        let layout = saved.slots.filter(\.observed).map { Block(key: $0.key, box: $0.box) }
        return Self.diff(layout, blocks).share < Self.changeShare ? saved : nil
    }

    /// `settled`: yeni ekran iki turdur aynı okunuyor; çizildikten sonra hemen kilitlenir (tek yeniden kurulum).
    private func unlock(reason: String, clear: Bool, next: [Block] = [], settled: Bool = false) -> [Send] {
        unlocks += 1
        onLog?("ekran kilidi açıldı: \(reason), \(slots.count) blok")
        save()
        locked = false
        slots = []
        frames.removeAll()
        changing = 0
        changingTo = nil
        var sends: [Send] = []
        if clear {
            for id in displayed.keys.sorted() { sends.append(Send(id: id, payload: nil, forget: true)) }
            displayed.removeAll()
            intended.removeAll()
            return sends
        }
        // Yeni ekran daha önce kilitlenmişse (menüye dönüldü) aynı kutular ve çevirilerle hemen çizilir.
        if let saved = cached(next) {
            return restore(saved, key: Self.screenKey(next), count: next.count)
        }
        // İzleyicinin şimdiki durumu çizilir (yeni ekran).
        if routes {
            sends += publish()
        } else {
            for id in Set(displayed.keys).union(intended.keys).sorted() where displayed[id] != intended[id] {
                sends.append(Send(id: id, payload: intended[id]))
            }
            displayed = intended
        }
        if settled, !next.isEmpty { lock(next) }
        return sends
    }

    /// Kilitli ekranın yuvaları önbelleğe yazılır.
    private func save() {
        guard locked, !lockKey.isEmpty, slots.contains(where: { $0.item != nil }) else { return }
        if cache[lockKey] == nil {
            cacheOrder.append(lockKey)
            if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        }
        cache[lockKey] = Saved(slots: slots, frames: frames)
    }

    /// Kutunun yuvası; `route`: gönderen yolun önceliği, daha öncelikli yolun yuvası seçilmez.
    private func slot(for box: TextBox, route: Int) -> Int? {
        var best: Int?
        var bestOverlap = Self.samePlace
        for (s, slot) in slots.enumerated() where slot.route >= route {
            let o = Self.overlap(slot.box, box)
            if o >= bestOverlap { best = s; bestOverlap = o }
        }
        return best
    }

    /// Yuvanın okuması en az `steadyPasses` turdur aynı ve gelen yazı o okumanın yazısı.
    private func steady(_ slot: Slot, _ item: ScreenTranslation.Item) -> Bool {
        slot.seenPasses >= Self.steadyPasses && Self.similar(slot.seen, Self.key(item.source))
    }

    /// Yazı güncellenir; kutu, yer, boy ve çizim ölçüleri yuvanınkidir.
    private func apply(_ item: ScreenTranslation.Item, to s: Int) {
        guard var current = slots[s].item else { return }
        current = Self.recoloured(current, item) ?? current
        current.source = item.source
        current.translation = item.translation
        current.icons = item.icons
        slots[s].item = current
        slots[s].pending = nil
    }

    /// Zeminin parlaklığı bu kadar değiştiyse seçim gezmiştir (açık şerit koyuya ya da tersine); okuma oynaması sayılmaz.
    static let recolourLuma = 60

    /// "#RRGGBB" rengin parlaklığı (0–255).
    static func luma(_ hex: String?) -> Int? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return (299 * ((value >> 16) & 0xff) + 587 * ((value >> 8) & 0xff) + 114 * (value & 0xff)) / 1000
    }

    static func recolours(_ a: String?, _ b: String?) -> Bool {
        guard let x = luma(a), let y = luma(b) else { return false }
        return abs(x - y) >= recolourLuma
    }

    /// Seçim gezdi (#1267): zemin belirgin değiştiyse yazının ve zeminin renkleri yeni okumadan; kutu, yer ve çizim ölçüleri
    /// yuvanınki. Okumanın renk oynaması güncelleme değildir (kutu boşuna yeniden çizilmez). Değişen yoksa nil.
    static func recoloured(_ old: ScreenTranslation.Item, _ new: ScreenTranslation.Item) -> ScreenTranslation.Item? {
        guard recolours(old.style?.background, new.style?.background) || recolours(old.paint?.background, new.paint?.background)
        else { return nil }
        var result = old
        if let style = new.style { result.style = style }
        if var paint = old.paint, let fresh = new.paint {
            paint.background = fresh.background
            paint.background2 = fresh.background2
            paint.direction = fresh.direction
            paint.patterned = fresh.patterned
            result.paint = paint
        }
        return result == old ? nil : result
    }

    /// İzleyicinin istediği (`intended`), yollar arası çakışması çözülmüş hâli: alanlar öncelik sırasıyla yerleşir; daha
    /// öncelikli yolun kutusuyla çakışan öğe çizilmez, bütün öğeleri çakışan alan hiç gönderilmez.
    private func resolved() -> [String: Payload] {
        var result: [String: Payload] = [:]
        hidden = [:]
        var boxes: [(rank: Int, rects: [TextBox])] = blockers.sorted { $0.key < $1.key }
            .flatMap { blocker in Self.footprints(blocker.value).map { (Self.rank(blocker.key), $0) } }
        for id in intended.keys.sorted(by: { (Self.rank($0), $0) < (Self.rank($1), $1) }) {
            guard let payload = intended[id] else { continue }
            let rank = Self.rank(id)
            func free(_ rects: [TextBox]) -> Bool { !boxes.contains { $0.rank < rank && Self.clash($0.rects, rects) } }
            guard let items = payload.blocks, !items.isEmpty else {
                let rects = payload.box.map { [$0] } ?? []
                guard free(rects) else {
                    hidden[id] = 1
                    continue
                }
                boxes.append((rank, rects))
                result[id] = payload
                continue
            }
            let keep = items.filter { free(Self.footprint($0)) }
            if keep.count < items.count { hidden[id] = items.count - keep.count }
            guard !keep.isEmpty else { continue }
            boxes += keep.map { (rank, Self.footprint($0)) }
            if keep.count == items.count {
                result[id] = payload
            } else {
                var trimmed = payload
                trimmed.blocks = keep
                trimmed.text = keep.map(\.translation).joined(separator: "\n")
                result[id] = trimmed
            }
        }
        return result
    }

    /// Kilitsizken TV'ye gidecekler: çakışması çözülmüş istek ile TV'de duran arasındaki fark.
    private func publish() -> [Send] {
        let next = resolved()
        let summary = hidden.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        if summary != routeLogged {
            if !summary.isEmpty { onLog?("ekran yazısı yolları: öncelikli yolun kutusuyla çakışan kutu çizilmedi (\(summary))") }
            routeLogged = summary
        }
        var sends: [Send] = []
        for id in Set(displayed.keys).union(next.keys).sorted() where displayed[id] != next[id] {
            sends.append(Send(id: id, payload: next[id]))
        }
        displayed = next
        return sends
    }

    /// Kilitliyken yazısı değişen (`touched`) ve görünürlüğü değişen alanlar yeniden çizilir: bir yolun yuvası dolunca ya da
    /// görev kutusu gelip gidince alçak yolun çakışan öğesi gizlenir ya da yeniden görünür; kutular yerinde kalır.
    private func renderAll(_ touched: Set<String>) -> [Send] {
        Set(slots.compactMap(\.id)).sorted().compactMap { id in
            let shown = displayed[id]?.blocks?.count ?? 0
            guard touched.contains(id) || shown != visible(id).count else { return nil }
            return render(id)
        }
    }

    /// Alanın kilitli yuvalarından çizilecek öğeler: öncelikli yolun (görev kutusu, kilitli başka alanın yuvası) kutusuyla
    /// çakışan öğe çizilmez.
    private func visible(_ id: String) -> [ScreenTranslation.Item] {
        let all = slots.filter { $0.id == id }.compactMap(\.item)
        guard routes, !all.isEmpty else { return all }
        let rank = Self.rank(id)
        var above = blockers.filter { Self.rank($0.key) < rank }.sorted { $0.key < $1.key }.flatMap { Self.footprints($0.value) }
        for slot in slots {
            guard let owner = slot.id, Self.rank(owner) < rank, let item = slot.item else { continue }
            above.append(Self.footprint(item))
        }
        return all.filter { item in !above.contains { Self.clash($0, Self.footprint(item)) } }
    }

    private func render(_ id: String) -> Send? {
        guard slots.contains(where: { $0.id == id && $0.item != nil }) else { return nil }
        var items = visible(id)
        if items.isEmpty {
            guard displayed[id] != nil else { return nil }
            displayed[id] = nil
            return Send(id: id, payload: nil)
        }
        items.sort { ($0.box.top, $0.box.left) < ($1.box.top, $1.box.left) }
        let frame = frames[id]
        let payload = Payload(text: items.map(\.translation).joined(separator: "\n"), box: frame?.box ?? items[0].box,
                              lineHeight: frame?.lineHeight ?? items[0].lineHeight, icons: frame?.icons, blocks: items)
        guard displayed[id] != payload else { return nil }
        displayed[id] = payload
        return Send(id: id, payload: payload)
    }
}
