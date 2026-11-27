// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Ekran kilidi (Sinan Bey: "stabil olsun artık"). Bütün ekran okuması (250–500 ms'de bir) her turda her bloğun kutusuna
 * yeniden karar veriyordu: kutular titriyor, yer değiştiriyor, kalkıp geliyor, yazılar birbirinin yerine geçiyordu. Ekran
 * yazısı katmanı (otomatik ekran yazısı; altyazı, görev kutusu [MissionLine.AREA_ID], kenar bildirimi ve telefon hariç)
 * artık kilitlenir:
 * - Kilit: blokların kümesi art arda [STEADY_PASSES] turda aynı (aynı yazılar aşağı yukarı aynı yerlerde) okununca o
 *   ekranın düzeni kilitlenir. Her blok bir yuvadır; kutusu, yeri, boyu ve çevirisi sabittir.
 * - Küçük değişiklik (imleç gezdi, sayaç/saat ilerledi, bir bloğun yazısı biraz değişti): kutu taşınmaz, eklenmez, kalkmaz.
 *   Yalnız var olan kutunun yazısı güncellenir, o da yuvanın okuması [STEADY_PASSES] tur aynı kaldıysa.
 * - Açılma: blokların [CHANGE_SHARE] kadarı gitti/yeni geldi/yerinde başka yazı oldu, ya da düzen tutmuyor; art arda
 *   [CHANGE_PASSES] turda. Ekran yazısı [EMPTY_MS]'ten uzun kalkınca da açılır, katman temizlenir.
 * - Ekran önbelleği: kilitli ekranın yuvaları yazılarının sadeleştirilmiş kümesiyle saklanır; aynı ekrana dönülünce aynı
 *   çeviriler aynı kutularda hemen çizilir.
 * - Her kilit ve açılış günlüğe nedeni ve blok sayısıyla bir satır yazılır.
 * Yalnız gönderilenleri süzer. Mac/iPhone (ScreenLock.swift) ve Windows (ScreenLock.cs) aynı kurallar. Her çağrı kendi
 * kilidinde.
 */
class ScreenLock {
    data class Block(val key: String, val box: TextBox)

    data class Payload(
        val text: String, val box: TextBox?, val lineHeight: Double?, val icons: List<IconPlacement>?,
        val blocks: List<ScreenTranslation.Item>?,
    )

    /** Gönderilecek alan; [payload] null ise kutu kalkar. [forget]: izleyici alanın gösterilen durumunu unutmalı. */
    data class Send(val id: String, val payload: Payload?, val forget: Boolean = false)

    data class Diff(val gone: Int, val fresh: Int, val changed: Int, val moved: Int, val total: Int) {
        val share: Double get() = if (total == 0) 0.0 else (gone + fresh + changed).toDouble() / total
    }

    class Slot(
        val key: String,
        val box: TextBox,
        val observed: Boolean = true,
        var id: String? = null,
        var item: ScreenTranslation.Item? = null,
        var seen: String,
        var seenPasses: Int,
        var pending: ScreenTranslation.Item? = null,
    ) {
        fun copy() = Slot(key, box, observed, id, item, seen, seenPasses, pending)
    }

    private class Saved(val slots: List<Slot>, val frames: Map<String, Payload>)

    private val gate = Any()
    private var locked = false
    private var slots = mutableListOf<Slot>()
    private var previous: List<Block>? = null
    private var emptySince: Long? = null
    private var changing = 0
    private var changingTo: List<Block>? = null
    private var lockKey = ""
    private val intended = HashMap<String, Payload>()
    private var displayed = HashMap<String, Payload>()
    private var frames = HashMap<String, Payload>()
    private val cache = HashMap<String, Saved>()
    private val cacheOrder = ArrayList<String>()
    @Volatile var onLog: ((String) -> Unit)? = null
    var locks = 0
        private set
    var unlocks = 0
        private set
    var cacheHits = 0
        private set

    val isLocked: Boolean get() = synchronized(gate) { locked }
    /** Katmanda çizili bir şey var mı (kilitliyken izleyici turu sürdürür). */
    val holds: Boolean get() = synchronized(gate) { locked || displayed.isNotEmpty() }
    val displayedIds: Set<String> get() = synchronized(gate) { displayed.keys.toSet() }
    fun displayed(id: String): Payload? = synchronized(gate) { displayed[id] }

    /** İzleyici bir alanı göndermek istiyor ([payload] null: kutu kalkar). Gönderilecekleri döndürür. */
    fun offer(id: String, payload: Payload?): List<Send> = synchronized(gate) {
        if (payload == null) intended.remove(id) else intended[id] = payload
        if (!locked) {
            // Kilit yokken gönderi olduğu gibi geçer.
            if (payload == null) displayed.remove(id) else displayed[id] = payload
            return listOf(Send(id, payload))
        }
        // Kilitliyken kutu kalkmaz; yeni kutu eklenmez; bloksuz gönderi kilidin dışında kalır.
        val items = payload?.blocks?.takeIf { it.isNotEmpty() } ?: return emptyList()
        if (id !in frames) frames[id] = Payload("", payload.box, payload.lineHeight, payload.icons, null)
        val touched = sortedSetOf<String>()
        for (item in items) {
            val slot = slotFor(item.box) ?: continue
            val current = slot.item
            if (current == null) {
                slot.item = item
                slot.id = id
                touched.add(id)
                continue
            }
            if (current.translation == item.translation && current.icons == item.icons) {
                // Yazı aynı; seçim gezdiyse (#1267) yalnız renkler güncellenir, kutu yerinde kalır.
                slot.pending = null
                recoloured(current, item)?.let {
                    slot.item = it
                    touched.add(slot.id ?: id)
                }
                continue
            }
            if (steady(slot, item)) {
                apply(item, slot)
                touched.add(slot.id ?: id)
            } else {
                slot.pending = item
            }
        }
        return touched.mapNotNull(::render)
    }

    /** Turun sonu: bu turda okunan bütün ekran yazısı blokları. Kilitlenir, açılır ya da bekleyen yazı güncellenir. */
    fun observe(blocks: List<Block>, now: Long): List<Send> = synchronized(gate) {
        if (blocks.isEmpty()) {
            previous = null
            val since = emptySince ?: now
            emptySince = since
            if (!locked || now - since <= EMPTY_MS) return emptyList()
            return unlock("ekran yazısı ${EMPTY_MS / 1000} sn'den uzun yok, katman temizlendi", clear = true)
        }
        emptySince = null
        if (locked) {
            for (slot in slots) {
                if (!slot.observed) continue
                var read: Block? = null
                var best = 0.0
                for (block in blocks) {
                    val o = overlap(block.box, slot.box)
                    if (o >= SAME_PLACE && o > best) { read = block; best = o }
                }
                if (read == null) {
                    slot.seenPasses = 0
                    continue
                }
                if (read.key == slot.seen) slot.seenPasses++ else {
                    slot.seen = read.key
                    slot.seenPasses = 1
                }
            }
            val layout = slots.filter { it.observed }.map { Block(it.key, it.box) }
            val diff = compare(layout, blocks)
            if (diff.share >= CHANGE_SHARE) {
                // Ekran değişiyor: bekleyen yazı uygulanmaz; değişiklik sürerse kilit açılır.
                changing++
                val settled = changingTo?.let { it.size == blocks.size && compare(it, blocks).share == 0.0 } ?: false
                changingTo = blocks.toList()
                if (changing < CHANGE_PASSES) return emptyList()
                val reason = if (diff.moved > 0 && diff.moved == diff.gone && diff.fresh == diff.moved)
                    "yerleşim değişti (${diff.moved} blok başka yerde)"
                else "ekran değişti (${diff.gone} blok gitti, ${diff.fresh} yeni, ${diff.changed} blokta başka yazı)"
                previous = blocks.toList()
                return unlock(reason, clear = false, next = blocks, settled = settled)
            }
            changing = 0
            changingTo = null
            val touched = sortedSetOf<String>()
            for (slot in slots) {
                val pending = slot.pending ?: continue
                if (steady(slot, pending)) {
                    apply(pending, slot)
                    slot.id?.let { touched.add(it) }
                }
            }
            save()
            return touched.mapNotNull(::render)
        }
        cached(blocks)?.let { saved ->
            previous = blocks.toList()
            return restore(saved, screenKey(blocks), blocks.size)
        }
        val last = previous
        previous = blocks.toList()
        if (last == null || last.size != blocks.size || compare(last, blocks).share != 0.0) return emptyList()
        lockOn(blocks)
        return emptyList()
    }

    /** Kilit dışarıdan bırakıldı (telefon açıldı, ayar değişti): gösterilenler unutulur, önbellek kalır. */
    fun release(reason: String): Unit = synchronized(gate) {
        if (locked) {
            unlocks++
            onLog?.invoke("ekran kilidi açıldı: $reason, ${slots.size} blok")
            save()
        }
        locked = false
        slots = mutableListOf()
        previous = null
        emptySince = null
        changing = 0
        changingTo = null
        intended.clear()
        displayed = HashMap()
        frames = HashMap()
    }

    /** Oturum bitti: önbellek de unutulur. */
    fun reset(): Unit = synchronized(gate) {
        release("çeviri durdu")
        cache.clear()
        cacheOrder.clear()
    }

    private fun lockOn(blocks: List<Block>) {
        locked = true
        locks++
        changing = 0
        lockKey = screenKey(blocks)
        slots = blocks.map { Slot(it.key, it.box, seen = it.key, seenPasses = STEADY_PASSES) }.toMutableList()
        frames = HashMap()
        // Çizili kutular yuvalarına oturur; yuvası olmayan çizili kutu da yerinde kalır (kendi yuvası olur).
        for ((id, payload) in displayed.toSortedMap()) {
            frames[id] = Payload("", payload.box, payload.lineHeight, payload.icons, null)
            for (item in payload.blocks ?: emptyList()) {
                val slot = slotFor(item.box)
                if (slot != null && slot.item == null) {
                    slot.item = item
                    slot.id = id
                } else {
                    val key = key(item.source)
                    slots.add(Slot(key, item.box, observed = false, id = id, item = item, seen = key, seenPasses = 0))
                }
            }
        }
        onLog?.invoke("ekran kilidi: kilitlendi, ${blocks.size} blok (${slots.count { it.item != null }} çevirili)")
        save()
    }

    /** Önbellekte bu ekran var ve düzeni tutuyor (aynı yazılar aşağı yukarı aynı yerlerde). */
    private fun cached(blocks: List<Block>): Saved? {
        val saved = cache[screenKey(blocks)] ?: return null
        if (saved.slots.none { it.item != null }) return null
        val layout = saved.slots.filter { it.observed }.map { Block(it.key, it.box) }
        return if (compare(layout, blocks).share < CHANGE_SHARE) saved else null
    }

    private fun restore(saved: Saved, key: String, count: Int): List<Send> {
        locked = true
        locks++
        cacheHits++
        changing = 0
        lockKey = key
        slots = saved.slots.map { it.copy().apply { seen = this.key; seenPasses = STEADY_PASSES; pending = null } }.toMutableList()
        frames = HashMap(saved.frames)
        onLog?.invoke("ekran kilidi: önbellekten kilitlendi (aynı ekrana dönüldü), $count blok")
        val sends = mutableListOf<Send>()
        val ids = slots.mapNotNull { it.id }.toSet()
        for (id in displayed.keys.filter { it !in ids }.sorted()) {
            displayed.remove(id)
            intended.remove(id)
            sends.add(Send(id, null, forget = true))
        }
        sends += ids.sorted().mapNotNull(::render)
        return sends
    }

    private fun unlock(reason: String, clear: Boolean, next: List<Block> = emptyList(), settled: Boolean = false): List<Send> {
        unlocks++
        onLog?.invoke("ekran kilidi açıldı: $reason, ${slots.size} blok")
        save()
        locked = false
        slots = mutableListOf()
        frames = HashMap()
        changing = 0
        changingTo = null
        val sends = mutableListOf<Send>()
        if (clear) {
            for (id in displayed.keys.sorted()) sends.add(Send(id, null, forget = true))
            displayed = HashMap()
            intended.clear()
            return sends
        }
        // Yeni ekran daha önce kilitlenmişse (menüye dönüldü) aynı kutular ve çevirilerle hemen çizilir.
        cached(next)?.let { return restore(it, screenKey(next), next.size) }
        // İzleyicinin şimdiki durumu çizilir (yeni ekran).
        for (id in (displayed.keys + intended.keys).toSortedSet()) {
            if (displayed[id] != intended[id]) sends.add(Send(id, intended[id]))
        }
        displayed = HashMap(intended)
        if (settled && next.isNotEmpty()) lockOn(next)
        return sends
    }

    /** Kilitli ekranın yuvaları önbelleğe yazılır. */
    private fun save() {
        if (!locked || lockKey.isEmpty() || slots.none { it.item != null }) return
        if (lockKey !in cache) {
            cacheOrder.add(lockKey)
            if (cacheOrder.size > CACHE_LIMIT) cache.remove(cacheOrder.removeAt(0))
        }
        cache[lockKey] = Saved(slots.map { it.copy() }, HashMap(frames))
    }

    private fun slotFor(box: TextBox): Slot? {
        var best: Slot? = null
        var bestOverlap = SAME_PLACE
        for (slot in slots) {
            val o = overlap(slot.box, box)
            if (o >= bestOverlap) { best = slot; bestOverlap = o }
        }
        return best
    }

    /** Yazı güncellenir; kutu, yer, boy ve çizim ölçüleri yuvanınkidir. */
    private fun apply(item: ScreenTranslation.Item, slot: Slot) {
        val current = slot.item ?: return
        slot.item = (recoloured(current, item) ?: current).copy(source = item.source, translation = item.translation, icons = item.icons)
        slot.pending = null
    }

    private fun render(id: String): Send? {
        val items = slots.filter { it.id == id }.mapNotNull { it.item }
            .sortedWith(compareBy({ it.box.top }, { it.box.left }))
        if (items.isEmpty()) return null
        val frame = frames[id]
        val payload = Payload(items.joinToString("\n") { it.translation }, frame?.box ?: items[0].box,
            frame?.lineHeight ?: items[0].lineHeight, frame?.icons, items)
        if (displayed[id] == payload) return null
        displayed[id] = payload
        return Send(id, payload)
    }

    companion object {
        const val STEADY_PASSES = 2
        const val CHANGE_SHARE = 0.35
        const val CHANGE_PASSES = 2
        const val EMPTY_MS = 1000L
        const val SAME_PLACE = 0.5
        const val CACHE_LIMIT = 16

        /** Kilidin altındaki alan: otomatik ekran yazısı; görev kutusu ve kenar bildirimi kendi yuvasında kalır. */
        fun covers(id: String): Boolean =
            id.startsWith("auto-") && id != MissionLine.AREA_ID && !ScreenNotices.isNotice(id)

        fun key(text: String): String = RegionWatcher.textKey(listOf(IconText.plain(text)))

        fun similar(a: String, b: String): Boolean = a == b || TextMatch.isSimilar(a, b, 0.75)

        /** Küçüğünün alanına oranla örtüşme. */
        fun overlap(a: TextBox, b: TextBox): Double {
            val w = minOf(a.right, b.right) - maxOf(a.left, b.left)
            val h = minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)
            if (w <= 0 || h <= 0) return 0.0
            val small = minOf((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top))
            return if (small > 0) w * h / small else 0.0
        }

        fun compare(old: List<Block>, fresh: List<Block>): Diff {
            val used = HashSet<Int>()
            var gone = 0
            var changed = 0
            var moved = 0
            for (block in old) {
                var best: Int? = null
                var bestOverlap = SAME_PLACE
                for (j in fresh.indices) {
                    if (j in used) continue
                    val o = overlap(block.box, fresh[j].box)
                    if (o >= bestOverlap) { best = j; bestOverlap = o }
                }
                if (best != null) {
                    used.add(best)
                    if (!similar(block.key, fresh[best].key)) changed++
                } else {
                    gone++
                    if (fresh.any { similar(it.key, block.key) }) moved++
                }
            }
            return Diff(gone, fresh.size - used.size, changed, moved, maxOf(old.size, fresh.size))
        }

        /** Zeminin parlaklığı bu kadar değiştiyse seçim gezmiştir (açık şerit koyuya ya da tersine). */
        const val RECOLOUR_LUMA = 60

        /** "#RRGGBB" rengin parlaklığı (0–255). */
        fun luma(hex: String?): Int? {
            if (hex == null || hex.length != 7 || hex[0] != '#') return null
            val value = hex.substring(1).toIntOrNull(16) ?: return null
            return (299 * ((value shr 16) and 0xff) + 587 * ((value shr 8) and 0xff) + 114 * (value and 0xff)) / 1000
        }

        fun recolours(a: String?, b: String?): Boolean {
            val x = luma(a) ?: return false
            val y = luma(b) ?: return false
            return kotlin.math.abs(x - y) >= RECOLOUR_LUMA
        }

        /** Seçim gezdi (#1267): yazının ve zeminin renkleri yeni okumadan; kutu, yer ve çizim ölçüleri yuvanınki. Değişen yoksa null. */
        fun recoloured(old: ScreenTranslation.Item, fresh: ScreenTranslation.Item): ScreenTranslation.Item? {
            // Okumanın renk oynaması güncelleme değildir (kutu boşuna yeniden çizilmez).
            if (!recolours(old.surface?.background, fresh.surface?.background) &&
                !recolours(old.paint?.background, fresh.paint?.background)) return null
            val surface = fresh.surface ?: old.surface
            val p = old.paint
            val f = fresh.paint
            val paint = if (p != null && f != null)
                p.copy(background = f.background, background2 = f.background2, direction = f.direction, patterned = f.patterned)
            else p
            if (surface == old.surface && paint == old.paint) return null
            return old.copy(surface = surface, paint = paint)
        }

        /** Ekranın önbellek anahtarı: yazıların sadeleştirilmiş kümesi. */
        fun screenKey(blocks: List<Block>): String =
            blocks.map { it.key }.filter { it.isNotEmpty() }.toSortedSet().joinToString("\u001F")

        /** Yuvanın okuması en az [STEADY_PASSES] turdur aynı ve gelen yazı o okumanın yazısı. */
        private fun steady(slot: Slot, item: ScreenTranslation.Item): Boolean =
            slot.seenPasses >= STEADY_PASSES && similar(slot.seen, key(item.source))
    }
}
