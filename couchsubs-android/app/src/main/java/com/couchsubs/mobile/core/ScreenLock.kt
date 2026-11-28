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
 * - Hazır alanlar da (#1391, `preset-*`: GTA 6 sol üstteki yardım ve sağdaki mesaj alanı) kilidin altında: harita ve görev
 *   listesi menü durumu bir an kapanınca hazır alandan, sonra yine otomatik alandan okunuyor; hazır alanın kutuları kilitsiz
 *   kalıp her turda yeniden karar veriliyor, otomatik alanın kutularının üstüne biniyordu (beta.108).
 * - Yollar arası çakışma (#1391): aynı yeri iki yol (görev kutusu, otomatik ekran yazısı, hazır alan) birden çizerse sabit
 *   öncelikle ([rank]) yalnız biri kalır: görev kutusu > otomatik ekran yazısı > hazır alan. Kilide giren bloklar da aynı
 *   öncelikle birleşir ([merge]).
 * Yalnız gönderilenleri süzer. Mac/iPhone (ScreenLock.swift) ve Windows (ScreenLock.cs) aynı kurallar. Her çağrı kendi
 * kilidinde.
 */
class ScreenLock {
    /** Okunan blok; [route]: bloğu okuyan yolun önceliği ([rank]; [merge] yazar). */
    data class Block(val key: String, val box: TextBox, val route: Int = 1)

    /** Hazır alanlar kilide girer ve yollar arası çakışma çözülür (#1391). false yalnız denemelerde (beta.108 davranışı). */
    @Volatile var routes = true

    /** Kilidin altındaki alan; [routes] kapalıyken (beta.108, yalnız denemelerin önce/sonra sayısı) hazır alan kilide girmez. */
    fun coversArea(id: String): Boolean = covers(id) && (routes || !GameAreaPresets.isPreset(id))

    /**
     * Turun blokları alan alan: yüksek öncelikli yolun bloğuyla aynı yerdeki alçak yol bloğu atılır (aynı satırı iki yol
     * okudu). Aynı öncelikteki alanlar olduğu gibi kalır.
     */
    fun merge(areas: List<Pair<String, List<Block>>>): List<Block> {
        if (!routes) return areas.flatMap { it.second }
        val kept = mutableListOf<Pair<Int, TextBox>>()
        val result = mutableListOf<Block>()
        for ((id, blocks) in areas.sortedWith(compareBy({ rank(it.first) }, { it.first }))) {
            val rank = rank(id)
            val fresh = blocks.filter { block -> kept.none { it.first < rank && overlap(it.second, block.box) >= ROUTE_OVERLAP } }
            kept += fresh.map { rank to it.box }
            result += fresh.map { it.copy(route = rank) }
        }
        return result
    }

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
        /**
         * Yuvayı okuyan yolun önceliği: daha alçak yol (hazır alan) bu yuvayı doldurmaz, yazısını değiştirmez (#1391: hazır
         * alanın kesik okuması "Keep an eye or" görev listesinin satırına yazılıyordu).
         */
        val route: Int = 1,
        val observed: Boolean = true,
        var id: String? = null,
        var item: ScreenTranslation.Item? = null,
        var seen: String,
        var seenPasses: Int,
        var pending: ScreenTranslation.Item? = null,
        /** Yuvanın yeri bu turdan beri okunan hiçbir alanın içinde değil ([UNREAD_MS]). */
        var unreadSince: Long? = null,
    ) {
        fun copy() = Slot(key, box, route, observed, id, item, seen, seenPasses, pending, unreadSince)
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
    /** Kilidin dışındaki öncelikli yolların (görev kutusu) TV'de duran kutuları ([block]). */
    private val blockers = HashMap<String, Payload>()
    /** Tanı (#1391): son yazılan yol çakışması ve bir an okunmayan yuva sayısı (değişince bir satır). */
    private var routeLogged = ""
    private var unreadLogged = 0
    /** Son çözümde öncelikli yolun altında kalıp çizilmeyen öğe sayısı, alan alan. */
    private val hidden = HashMap<String, Int>()
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
            // Kilit yokken gönderi geçer; yollar arası çakışmada öncelikli yol kalır ([resolved]).
            if (routes) return publish()
            if (payload == null) displayed.remove(id) else displayed[id] = payload
            return listOf(Send(id, payload))
        }
        // Kilitliyken kutu kalkmaz; yeni kutu eklenmez; bloksuz gönderi kilidin dışında kalır.
        val items = payload?.blocks?.takeIf { it.isNotEmpty() } ?: return emptyList()
        if (id !in frames) frames[id] = Payload("", payload.box, payload.lineHeight, payload.icons, null)
        val touched = sortedSetOf<String>()
        for (item in items) {
            val slot = slotFor(item.box, if (routes) rank(id) else 0) ?: continue
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
        return if (routes) renderAll(touched) else touched.mapNotNull(::render)
    }

    /**
     * Alanın yazısı kesin gitti (hazır alanın arayüz kutusu [RegionWatcher.PANEL_MISS_TURNS] tur bulunamadı): kilitliyken de
     * kutuları kalkar, yuvaları düzenden çıkar. Gönderilecekleri döndürür.
     */
    fun withdraw(id: String): List<Send> = synchronized(gate) {
        if (!routes) return offer(id, null)
        intended.remove(id)
        if (!locked) return publish()
        slots.removeAll { it.id == id }
        frames.remove(id)
        val sends = mutableListOf<Send>()
        if (displayed.remove(id) != null) sends.add(Send(id, null))
        // Kilitli ekranın bütün yazısı bu alanındı: kilit açılır.
        if (slots.none { it.observed }) return sends + unlock("$id alanının yazısı gitti", clear = false)
        return sends + renderAll(emptySet())
    }

    /**
     * Kilidin dışındaki öncelikli yol (görev kutusu) TV'ye gitti ya da kalktı: onunla çakışan ekran yazısı çizilmez, kalkınca
     * yeniden çizilir. Gönderilecekleri döndürür (öncelikli yolun kendi gönderisi izleyicide).
     */
    fun block(id: String, payload: Payload?): List<Send> = synchronized(gate) {
        if (!routes || blockers[id] == payload) return emptyList()
        if (payload == null) blockers.remove(id) else blockers[id] = payload
        return if (locked) renderAll(emptySet()) else publish()
    }

    /**
     * Turun sonu: bu turda okunan bütün ekran yazısı blokları. Kilitlenir, açılır ya da bekleyen yazı güncellenir. [read]: bu
     * turda yazı okunan alanların yeri ve yolu ([Block.box], [Block.route]; null: bütün ekran okundu). Yuvanın yeri kendi
     * yolundan ya da daha öncelikli yoldan okunmadıysa yuva [UNREAD_MS] dolana dek ekran değişikliğine sayılmaz.
     */
    fun observe(blocks: List<Block>, now: Long, read: List<Block>? = null): List<Send> = synchronized(gate) {
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
                var seen: Block? = null
                var best = 0.0
                for (block in blocks) {
                    if (block.route > slot.route) continue
                    val o = overlap(block.box, slot.box)
                    if (o >= SAME_PLACE && o > best) { seen = block; best = o }
                }
                if (seen == null) {
                    slot.seenPasses = 0
                    continue
                }
                if (seen.key == slot.seen) slot.seenPasses++ else {
                    slot.seen = seen.key
                    slot.seenPasses = 1
                }
            }
            for (slot in slots) {
                val unread = read != null && read.none { it.route <= slot.route && overlap(slot.box, it.box) >= SAME_PLACE }
                slot.unreadSince = if (unread) slot.unreadSince ?: now else null
            }
            val layout = slots.filter { slot -> slot.observed && slot.unreadSince.let { it == null || now - it > UNREAD_MS } }
                .map { Block(it.key, it.box) }
            // Kilitli ekranı kuran yoldan alçak yolun okuması (hazır alanın menü satırından kestiği parça, menü dışı okunan
            // harita tuşu) ekran değişikliğine kanıt sayılmaz (#1391); yalnız kendi yolunun yuvasının üstündeki okuması
            // sayılır. Kuran yol okumazsa yuvaları [UNREAD_MS] sonra gitmiş sayılır.
            val top = slots.filter { it.observed }.minOfOrNull { it.route } ?: Int.MAX_VALUE
            val evidence = if (routes) blocks.filter { block ->
                block.route <= top || slots.any { it.observed && it.route == block.route && overlap(it.box, block.box) >= SAME_PLACE }
            } else blocks
            val held = if (routes) slots.count { slot -> slot.observed && slot.unreadSince.let { it != null && now - it <= UNREAD_MS } } else 0
            if (held != unreadLogged) {
                if (held > 0) onLog?.invoke("ekran yazısı yolları: $held blok bir an okunmadı (alan önerilmedi ya da boş okundu), kilit korunuyor")
                unreadLogged = held
            }
            val diff = compare(layout, evidence)
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
            return if (routes) renderAll(touched) else touched.mapNotNull(::render)
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
        blockers.clear()
        cache.clear()
        cacheOrder.clear()
    }

    private fun lockOn(blocks: List<Block>) {
        locked = true
        locks++
        changing = 0
        lockKey = screenKey(blocks)
        slots = blocks.map { Slot(it.key, it.box, route = it.route, seen = it.key, seenPasses = STEADY_PASSES) }.toMutableList()
        frames = HashMap()
        // Çizili kutular yuvalarına oturur; yuvası olmayan çizili kutu da yerinde kalır (kendi yuvası olur).
        for ((id, payload) in displayed.toSortedMap()) {
            frames[id] = Payload("", payload.box, payload.lineHeight, payload.icons, null)
            for (item in payload.blocks ?: emptyList()) {
                val slot = slotFor(item.box, if (routes) rank(id) else 0)
                if (slot != null && slot.item == null) {
                    slot.item = item
                    slot.id = id
                } else {
                    val key = key(item.source)
                    slots.add(Slot(key, item.box, route = rank(id), observed = false, id = id, item = item, seen = key, seenPasses = 0))
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
        slots = saved.slots.map {
            it.copy().apply { seen = this.key; seenPasses = STEADY_PASSES; pending = null; unreadSince = null }
        }.toMutableList()
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
        if (routes) {
            sends += publish()
        } else {
            for (id in (displayed.keys + intended.keys).toSortedSet()) {
                if (displayed[id] != intended[id]) sends.add(Send(id, intended[id]))
            }
            displayed = HashMap(intended)
        }
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

    /** Kutunun yuvası; [route]: gönderen yolun önceliği, daha öncelikli yolun yuvası seçilmez. */
    private fun slotFor(box: TextBox, route: Int): Slot? {
        var best: Slot? = null
        var bestOverlap = SAME_PLACE
        for (slot in slots) {
            if (slot.route < route) continue
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

    /**
     * İzleyicinin istediği, yollar arası çakışması çözülmüş hâli: alanlar öncelik sırasıyla yerleşir; daha öncelikli yolun
     * kutusuyla çakışan öğe çizilmez, bütün öğeleri çakışan alan hiç gönderilmez.
     */
    private fun resolved(): HashMap<String, Payload> {
        val result = HashMap<String, Payload>()
        hidden.clear()
        val boxes = mutableListOf<Pair<Int, List<TextBox>>>()
        for (id in blockers.keys.sorted()) boxes += footprints(blockers.getValue(id)).map { rank(id) to it }
        for (id in intended.keys.sortedWith(compareBy({ rank(it) }, { it }))) {
            val payload = intended.getValue(id)
            val rank = rank(id)
            fun free(rects: List<TextBox>) = boxes.none { it.first < rank && clash(it.second, rects) }
            val items = payload.blocks
            if (items.isNullOrEmpty()) {
                val rects = listOfNotNull(payload.box)
                if (!free(rects)) {
                    hidden[id] = 1
                    continue
                }
                boxes += rank to rects
                result[id] = payload
                continue
            }
            val keep = items.filter { free(footprint(it)) }
            if (keep.size < items.size) hidden[id] = items.size - keep.size
            if (keep.isEmpty()) continue
            boxes += keep.map { rank to footprint(it) }
            result[id] = if (keep.size == items.size) payload
            else payload.copy(blocks = keep, text = keep.joinToString("\n") { it.translation })
        }
        return result
    }

    /** Kilitsizken TV'ye gidecekler: çakışması çözülmüş istek ile TV'de duran arasındaki fark. */
    private fun publish(): List<Send> {
        val next = resolved()
        val summary = hidden.toSortedMap().entries.joinToString(", ") { "${it.key} ${it.value}" }
        if (summary != routeLogged) {
            if (summary.isNotEmpty()) onLog?.invoke("ekran yazısı yolları: öncelikli yolun kutusuyla çakışan kutu çizilmedi ($summary)")
            routeLogged = summary
        }
        val sends = mutableListOf<Send>()
        for (id in (displayed.keys + next.keys).toSortedSet()) {
            if (displayed[id] != next[id]) sends.add(Send(id, next[id]))
        }
        displayed = next
        return sends
    }

    /**
     * Kilitliyken yazısı değişen ve görünürlüğü değişen alanlar yeniden çizilir: bir yolun yuvası dolunca ya da görev kutusu
     * gelip gidince alçak yolun çakışan öğesi gizlenir ya da yeniden görünür; kutular yerinde kalır.
     */
    private fun renderAll(touched: Set<String>): List<Send> =
        slots.mapNotNull { it.id }.toSortedSet().mapNotNull { id ->
            val shown = displayed[id]?.blocks?.size ?: 0
            if (id !in touched && shown == visible(id).size) null else render(id)
        }

    /**
     * Alanın kilitli yuvalarından çizilecek öğeler: öncelikli yolun (görev kutusu, kilitli başka alanın yuvası) kutusuyla
     * çakışan öğe çizilmez.
     */
    private fun visible(id: String): List<ScreenTranslation.Item> {
        val all = slots.filter { it.id == id }.mapNotNull { it.item }
        if (!routes || all.isEmpty()) return all
        val rank = rank(id)
        val above = blockers.filterKeys { rank(it) < rank }.toSortedMap().values.flatMap(::footprints).toMutableList()
        for (slot in slots) {
            val owner = slot.id ?: continue
            val item = slot.item ?: continue
            if (rank(owner) < rank) above += footprint(item)
        }
        return all.filter { item -> above.none { clash(it, footprint(item)) } }
    }

    private fun render(id: String): Send? {
        if (slots.none { it.id == id && it.item != null }) return null
        val items = visible(id).sortedWith(compareBy({ it.box.top }, { it.box.left }))
        if (items.isEmpty()) {
            if (displayed.remove(id) == null) return null
            return Send(id, null)
        }
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
        /**
         * Yeri okunmayan yuva (#1391: GTA 6 haritasında menü durumu bir an kapanınca menü alanları kalkıyor, hazır alan
         * okuyordu) bu kadar süre ekran değişikliğine sayılmaz; daha uzun sürerse gitmiş sayılır.
         */
        const val UNREAD_MS = 1500L
        /** Başka yolun kutusuyla (küçüğünün alanına oranla) en az bu kadar örtüşen kutu çakışır. */
        const val ROUTE_OVERLAP = 0.1

        /** Kilidin altındaki alan: otomatik ekran yazısı ve hazır alan; görev kutusu ve kenar bildirimi kendi yuvasında kalır. */
        fun covers(id: String): Boolean =
            (id.startsWith("auto-") || GameAreaPresets.isPreset(id)) && id != MissionLine.AREA_ID && !ScreenNotices.isNotice(id)

        /** Yolun önceliği (küçük olan kalır): görev kutusu, otomatik ekran yazısı, hazır alan, diğer. */
        fun rank(id: String): Int = when {
            id == MissionLine.AREA_ID -> 0
            id.startsWith("auto-") -> 1
            GameAreaPresets.isPreset(id) -> 2
            else -> 3
        }

        /** Kilidin dışında kalıp yine de üstüne çizilmeyecek yol (görev kutusu). */
        fun blocks(id: String): Boolean = id == MissionLine.AREA_ID

        /** Öğenin TV'de kapladığı yerler: özgün yazının kutusu, örtüsü, yanına yazılan ya da ikiz kutusu. */
        fun footprint(item: ScreenTranslation.Item): List<TextBox> =
            listOf(item.box) + listOfNotNull(item.paint?.cover, item.paint?.spot, item.paint?.twin)

        fun footprints(payload: Payload): List<List<TextBox>> {
            val items = payload.blocks
            if (!items.isNullOrEmpty()) return items.map(::footprint)
            return listOfNotNull(payload.box).map { listOf(it) }
        }

        fun clash(a: List<TextBox>, b: List<TextBox>): Boolean = a.any { x -> b.any { overlap(x, it) >= ROUTE_OVERLAP } }

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

        /** Biri ötekinin parçası (#1391: menü durumu bir an kapanınca aynı paragraf satır satır okunuyor). En az 4 harf. */
        fun part(a: String, b: String): Boolean {
            val (shorter, longer) = if (a.length <= b.length) a to b else b to a
            return shorter.length >= 4 && longer.contains(shorter)
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
                    if (!similar(block.key, fresh[best].key) && !part(block.key, fresh[best].key)) changed++
                } else {
                    gone++
                    if (fresh.any { similar(it.key, block.key) }) moved++
                }
            }
            // Eski bir bloğun yerinde onun parçası olan blok yeni sayılmaz (aynı yazı başka satırlara bölündü).
            val added = fresh.indices.count { j ->
                j !in used && old.none { overlap(it.box, fresh[j].box) >= SAME_PLACE && part(it.key, fresh[j].key) }
            }
            return Diff(gone, added, changed, moved, maxOf(old.size, fresh.size))
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
