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
/// Yalnız gönderilenleri süzer: okuma, çeviri ve çizim ölçümü `RegionWatcher`'da olduğu gibi sürer. Windows
/// (ScreenLock.cs) ve Android (ScreenLock.kt) aynı kurallar.
@MainActor
final class ScreenLock {
    /// Kilidin altındaki alan: otomatik ekran yazısı; görev kutusu ve kenar bildirimi kendi yuvasında kalır.
    static func covers(_ id: String) -> Bool {
        id.hasPrefix("auto-") && id != MissionLine.areaId && !ScreenNotices.isNotice(id: id)
    }

    /// Okunan blok: sadeleştirilmiş yazısı ve karedeki yeri.
    struct Block: Equatable {
        var key: String
        var box: TextBox
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

    struct Slot: Equatable {
        var key: String
        var box: TextBox
        /// Okumadan gelen yuva (kilitlendiği ekranın bloğu); false: kilitlendiğinde çizili duran, okumada olmayan kutu.
        var observed = true
        var id: String?
        var item: ScreenTranslation.Item?
        /// Yuvanın yerinde son okunan yazı ve kaç turdur aynı okunduğu.
        var seen: String
        var seenPasses: Int
        /// Okuması henüz kararlı olmadığı için bekletilen yazı güncellemesi.
        var pending: ScreenTranslation.Item?
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
                if !similar(block.key, new[best].key) { result.changed += 1 }
            } else {
                result.gone += 1
                if new.contains(where: { similar($0.key, block.key) }) { result.moved += 1 }
            }
        }
        result.fresh = new.count - used.count
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
            // Kilit yokken gönderi olduğu gibi geçer.
            displayed[id] = payload
            return [Send(id: id, payload: payload)]
        }
        // Kilitliyken kutu kalkmaz; yeni kutu eklenmez; bloksuz gönderi kilidin dışında kalır.
        guard let payload, let items = payload.blocks, !items.isEmpty else { return [] }
        if frames[id] == nil { frames[id] = Payload(text: "", box: payload.box, lineHeight: payload.lineHeight, icons: payload.icons) }
        var touched = Set<String>()
        for item in items {
            guard let s = slot(for: item.box) else { continue }
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
        return touched.sorted().compactMap(render)
    }

    /// Turun sonu: bu turda okunan bütün ekran yazısı blokları. Kilitlenir, açılır ya da bekleyen yazı güncellenir.
    func observe(_ blocks: [Block], at now: Int) -> [Send] {
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
                let read = blocks.filter { Self.overlap($0.box, slots[s].box) >= Self.samePlace }
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
            let layout = slots.filter(\.observed).map { Block(key: $0.key, box: $0.box) }
            let diff = Self.diff(layout, blocks)
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
            return touched.sorted().compactMap(render)
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
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - İç işler

    private func lock(_ blocks: [Block]) {
        locked = true
        locks += 1
        changing = 0
        lockKey = Self.screenKey(blocks)
        slots = blocks.map { Slot(key: $0.key, box: $0.box, seen: $0.key, seenPasses: Self.steadyPasses) }
        frames.removeAll()
        // Çizili kutular yuvalarına oturur; yuvası olmayan çizili kutu da yerinde kalır (kendi yuvası olur).
        for (id, payload) in displayed.sorted(by: { $0.key < $1.key }) {
            frames[id] = Payload(text: "", box: payload.box, lineHeight: payload.lineHeight, icons: payload.icons)
            for item in payload.blocks ?? [] {
                if let s = slot(for: item.box), slots[s].item == nil {
                    slots[s].item = item
                    slots[s].id = id
                } else {
                    let key = Self.key(item.source)
                    slots.append(Slot(key: key, box: item.box, observed: false, id: id, item: item, seen: key, seenPasses: 0))
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
        for id in Set(displayed.keys).union(intended.keys).sorted() where displayed[id] != intended[id] {
            sends.append(Send(id: id, payload: intended[id]))
        }
        displayed = intended
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

    private func slot(for box: TextBox) -> Int? {
        var best: Int?
        var bestOverlap = Self.samePlace
        for (s, slot) in slots.enumerated() {
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

    private func render(_ id: String) -> Send? {
        let items = slots.filter { $0.id == id }.compactMap(\.item)
            .sorted { ($0.box.top, $0.box.left) < ($1.box.top, $1.box.left) }
        guard !items.isEmpty else { return nil }
        let frame = frames[id]
        let payload = Payload(text: items.map(\.translation).joined(separator: "\n"), box: frame?.box ?? items[0].box,
                              lineHeight: frame?.lineHeight ?? items[0].lineHeight, icons: frame?.icons, blocks: items)
        guard displayed[id] != payload else { return nil }
        displayed[id] = payload
        return Send(id: id, payload: payload)
    }
}
