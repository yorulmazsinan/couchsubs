// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.max
import kotlin.math.min

/**
 * Menü ekranında çevirinin biçimi ayardan gelir, her okumada yeniden seçilmez (#1365, Ayarlar › Ekran yazıları ›
 * "Menülerde İngilizcenin üstünü ört"). beta.105 testinde GTA 6 haritasında aynı satır art arda okumalarda örtü, yan,
 * üst/alt ya da haritada yüzen ikiz kutu oluyordu (5 dakikada 237 yan, 139 örtü, 37 ikiz): [TextPainter] kipi satırın
 * çevresindeki boş alana ve zemin desenine göre seçiyor, kayan harita ve seçim çubuğu bunları her karede değiştiriyordu.
 *
 * Menüdeki otomatik alanın çizimleri [TextPainter]'ın ölçtüğü örtü kutusu, zemin ve yazı rengiyle kalır; yalnız yerleşim
 * kilitlenir. Yerleşim yalnız yazıların kutularından çıkar (kare noktalarına bakılmaz): aynı ekran her okumada aynı çizilir.
 * - **B, üstünü ört (`cover`):** her yazı kendi yerinde, ölçülen zemin renginde örtülür; kartın başlığı ve metni ayrı
 *   ayrı örtülür, kişi resmi ve simgeler açıkta kalır.
 * - **A, yanına yaz (varsayılan):** her satırın Türkçesi İngilizcesinin hemen yanına, koyu zeminli etikete (`label`)
 *   yazılır: sola yaslı satırda sağına, sağa yaslı satırda (tuş çubuğu) soluna; satırın simgesi ve komşu yazılar
 *   örtülmez. Yanına sığmayan etiket (sekme şeridi, sıkışık tuş çubuğu) altına, olmazsa üstüne yazılır; şeridin bir
 *   sekmesi altına yazıldıysa öbür sekmeler de altına, biri hiçbir yere sığmazsa şeridin hepsi örtülür (şerit bir bütün).
 *   Listede Türkçeler tek sütunda başlar (sola yaslı listede en uzun satırın sağında). Hiçbir yere sığmayan satır örtülür.
 *   Haritanın görev kartının (`cards`) çevirisi kartın hemen altına (yer yoksa üstüne), kartın zemininde, kişi
 *   resmiyle ikiz kart olarak gelir; ikisine de yer yoksa ya da kart bir listenin parçasıysa (Görevler ekranı: sol kenarı
 *   kartla hizalı başka yazılar) kartın satırları da yanına yazılır.
 * - İki biçimde de satırın üstüne/altına küçük yazma, haritaya uzak ikiz kutu ve iki satırı tek kutuda birleştirme olmaz;
 *   etiketler başka yazının ya da ikiz kartın üstüne binmez.
 *
 * Kutular kareye oranla (0…1); `aspect`: karenin genişlik/yükseklik oranı. Mac (MenuLayout.swift) ve Windows
 * (MenuLayout.cs) aynı kuralı, aynı eşikleri kullanır; ortak deneme dosyası fixtures/menu-layout.json.
 */
object MenuLayout {
    /** Yanına yazılan Türkçenin etiket zemini (TV yarı saydam çizer, yazı açık renk). */
    const val LABEL_COLOR = "#121419"
    /** Türkçe ile İngilizce (ya da satırın simgesi) arası, satır yüksekliğinin katı. */
    const val GAP_LINES = 0.4
    /** Satırın yanındaki simge okunan kutuda değilse simge için bırakılan yer, satır yüksekliğinin katı. */
    const val ICON_LINES = 1.2
    /** Yanına yazılan Türkçenin en çok uzayabileceği yer: İngilizcenin [BESIDE_MAX] katı artı bir satır, en az [REACH_LINES]. */
    const val BESIDE_MAX = 1.6
    const val REACH_LINES = 12.0
    /** Yanında bu kadar yer (İngilizcenin genişliğinin payı) yoksa Türkçe altına/üstüne yazılır. */
    const val ROOM_SHARE = 0.6
    /** Aynı satırda sayılmak için dikey örtüşme (kısa kutunun payı). */
    const val SAME_ROW = 0.3
    /**
     * Etiket bir yazıya ancak etiketin boyunun bu payından çok binerse çakışır (sıkışık listede komşu satırların okunan
     * kutuları birkaç nokta örtüşür).
     */
    const val TOUCH_SHARE = 0.25
    /** Aynı satırda bu kadar yakın (satır yüksekliğinin katı) iki yazı tek şerittir: biri altına/üstüne yazıldıysa öbürü de. */
    const val STRIP_GAP_LINES = 4.0
    /** Ekran kenarından bırakılan pay, satır yüksekliğinin katı. */
    const val EDGE_LINES = 0.2
    /** İkiz kartın kart yazılarının çevresindeki iç boşluğu ve kartla arası, satır yüksekliğinin katı. */
    const val CARD_PAD_LINES = 0.5
    const val CARD_GAP_LINES = 0.3
    /** Kart dışı bir yazının sol kenarı kartınkine bu kadar yakınsa (satır yüksekliğinin katı) kart bir listenin parçasıdır. */
    const val COLUMN_LINES = 1.0
    /** Alt alta iki satır bu kadar (satır yüksekliğinin katı) aralıkla aynı listenin sütunundadır. */
    const val COLUMN_GAP_LINES = 1.5

    /**
     * Menüdeki çizimler ayardaki biçime kilitlenir. [cards]: görev kartlarının parçaları (her kart için [paints] sıraları);
     * [cover]: B (üstünü ört), false: A (yanına yaz). [portrait]: ikiz kurulacak kartın parçalarında kişi resmi yoksa
     * kartın parçaları ve zemini verilip resim (kutusu ve kesilmiş görüntüsü) kareden aranır ([TextPainter.cardPortrait];
     * ikiz kart resimsiz kalmasın).
     */
    fun locked(paints: List<TextPaint>, targets: List<TextPainter.Target>, cards: List<List<Int>>, cover: Boolean,
               aspect: Double, portrait: ((List<Int>, String) -> Pair<TextBox, String?>?)? = null): List<TextPaint> {
        if (paints.size != targets.size || paints.isEmpty()) return paints
        val result = paints.map(::plain).toMutableList()
        if (cover) return result
        val taken = paints.indices.map { paints[it].cover.union(targets[it].box) }
        val done = HashSet<Int>()
        val twins = ArrayList<TextBox>()
        for (raw in cards) {
            // Kutusu boş (genişliği ya da yüksekliği olmayan) parça ikize girmez.
            val card = raw.filter {
                it >= 0 && it < paints.size && it !in done &&
                    paints[it].cover.right - paints[it].cover.left > 1e-9 && paints[it].cover.bottom - paints[it].cover.top > 1e-9
            }
            if (card.isEmpty()) continue
            val made = cardTwin(card, paints, targets, taken, twins, aspect, portrait) ?: continue
            for ((m, paint) in made) result[m] = paint
            done.addAll(card)
            twins.add(made[0].second.twin!!)
        }
        val vertical = HashSet<Int>()
        val base = result.toList()
        for (i in paints.indices) {
            if (i in done) continue
            val (paint, below) = beside(i, paints, targets, taken, twins, aspect, base[i], side = true)
            result[i] = paint
            if (below) vertical.add(i)
        }
        val free = paints.indices.filter { it !in done }
        // Şerit bir bütün: aynı satırda yakın yazılar (sekme şeridi, tuş çubuğu) tek biçimde çizilir. Hepsi yanına sığıyorsa
        // yanına; değilse hepsi altına/üstüne; biri de sığmazsa hepsi örtülür (şeritte kimi Türkçe yanında, kimi altında, kimi
        // örtülü kalıyordu).
        for (strip in strips(free, paints, targets, taken, aspect)) {
            if (strip.size < 2 || strip.all { result[it].mode == TextPaint.MODE_BESIDE && it !in vertical }) continue
            val tried = strip.map { beside(it, paints, targets, taken, twins, aspect, base[it], side = false) }
            val below = tried.all { it.second }
            for ((k, i) in strip.withIndex()) {
                result[i] = if (below) tried[k].first else base[i]
                if (below) vertical.add(i) else vertical.remove(i)
            }
        }
        // Liste bir sütun: alt alta, aynı yana yaslı satırların yanına yazılan Türkçeleri tek sütunda başlar (sola yaslı
        // listede en uzun satırın sağında, sağa yaslı listede en uzun satırın solunda). Bir satıra orada yer yoksa liste
        // her satırın yanında kalır.
        val side = free.filter { result[it].mode == TextPaint.MODE_BESIDE && it !in vertical && result[it].spot != null }
        for (right in listOf(false, true)) {
            val members = side.filter { (targets[it].align == "right") == right }
                .sortedWith(compareBy<Int>({ paints[it].cover.top }, { it }))
            val used = HashSet<Int>()
            for (start in members) {
                if (!used.add(start)) continue
                val column = mutableListOf(start)
                for (b in members) {
                    if (b in used) continue
                    val last = column.last()
                    val line = max(targets[last].lineHeight, targets[b].lineHeight)
                    val edgeA = if (right) taken[start].right else taken[start].left
                    val edgeB = if (right) taken[b].right else taken[b].left
                    if (kotlin.math.abs(edgeA - edgeB) <= COLUMN_LINES * line / max(0.1, aspect) &&
                        paints[b].cover.top >= paints[last].cover.top &&
                        paints[b].cover.top - paints[last].cover.bottom <= COLUMN_GAP_LINES * line) {
                        used.add(b)
                        column.add(b)
                    }
                }
                if (column.size < 2) continue
                val x = if (right) column.minOf { result[it].spot!!.right } else column.maxOf { result[it].spot!!.left }
                val aligned = column.map { besideAt(it, x, right, paints, targets, taken, twins, aspect, result[it]) }
                if (aligned.any { it == null }) continue
                for ((k, i) in column.withIndex()) result[i] = aligned[k]!!
            }
        }
        return result
    }

    /**
     * Aynı satırda birbirine yakın (aralarında en çok [STRIP_GAP_LINES] satır) yazıların şeritleri; zincirleme (sekme
     * şeridinin bütün sekmeleri). Sıra [free] sırası.
     */
    internal fun strips(free: List<Int>, paints: List<TextPaint>, targets: List<TextPainter.Target>, taken: List<TextBox>,
                        aspect: Double): List<List<Int>> {
        val strips = ArrayList<List<Int>>()
        val seen = HashSet<Int>()
        for (start in free) {
            if (!seen.add(start)) continue
            val strip = mutableListOf(start)
            var q = 0
            while (q < strip.size) {
                val a = strip[q++]
                for (b in free) {
                    if (b in seen) continue
                    val ca = paints[a].cover
                    val cb = paints[b].cover
                    val lineX = max(1e-6, min(targets[a].lineHeight, targets[b].lineHeight)) / max(0.1, aspect)
                    if (overlapY(ca, cb) >= SAME_ROW * min(ca.bottom - ca.top, cb.bottom - cb.top) &&
                        max(0.0, max(taken[a].left, taken[b].left) - min(taken[a].right, taken[b].right)) <= STRIP_GAP_LINES * lineX) {
                        seen.add(b)
                        strip.add(b)
                    }
                }
            }
            strips.add(strip)
        }
        return strips
    }

    /** Satırın kendi kutusu simgesiyle birlikte (okunan kutu); simge okunmadıysa simge tarafına simge kadar yer. */
    internal fun own(i: Int, paints: List<TextPaint>, taken: List<TextBox>, lineX: Double): TextBox {
        val c = paints[i].cover
        var own = taken[i]
        if (paints[i].iconSide == "left" && c.left - own.left < 0.5 * ICON_LINES * lineX) own = own.copy(left = c.left - ICON_LINES * lineX)
        if (paints[i].iconSide == "right" && own.right - c.right < 0.5 * ICON_LINES * lineX) own = own.copy(right = c.right + ICON_LINES * lineX)
        return own
    }

    /** Satırın engelleri: öbür yazıların kutuları (sırasıyla) ve ikiz kartlar (sıra -1). */
    internal fun others(i: Int, taken: List<TextBox>, twins: List<TextBox>): List<Pair<Int, TextBox>> =
        taken.indices.filter { it != i }.map { it to taken[it] } + twins.map { -1 to it }

    /**
     * Yanına yazılan Türkçenin [start]'tan (sola yaslıda sol kenarı, sağa yaslıda sağ kenarı) uzayabileceği son nokta:
     * ekranın kenarı, en çok erişim, satırdaki yazı ya da ikiz kart. Karşıdan bakan komşu (sola yaslı satırın sağında sağa
     * yaslı değer, "STYLE … SOUVENIR") arayı ortadan böler; ikisinin Türkçesi üst üste binmez.
     */
    internal fun limit(i: Int, start: Double, right: Boolean, own: TextBox, paints: List<TextPaint>,
                       targets: List<TextPainter.Target>, others: List<Pair<Int, TextBox>>, aspect: Double): Double {
        val c = paints[i].cover
        val lineX = max(1e-6, targets[i].lineHeight) / max(0.1, aspect)
        val gap = GAP_LINES * lineX
        val edge = EDGE_LINES * lineX
        val eps = 1e-9
        val w = c.right - c.left
        val reach = max(BESIDE_MAX * w + lineX, REACH_LINES * lineX)
        val touch = TOUCH_SHARE * (c.bottom - c.top)
        if (!right) {
            var limit = min(1 - edge, start + reach)
            for ((j, o) in others) {
                if (overlapY(o, c) <= touch || o.right <= start) continue
                val facing = j >= 0 && targets[j].align == "right" && o.left >= own.right - eps
                limit = min(limit, if (facing) (own.right + o.left - gap) / 2 else o.left - gap)
            }
            return limit
        }
        var low = max(edge, start - reach)
        for ((j, o) in others) {
            if (overlapY(o, c) <= touch || o.left >= start) continue
            val facing = j >= 0 && targets[j].align != "right" && o.right <= own.left + eps
            low = max(low, if (facing) (o.right + own.left + gap) / 2 else o.right + gap)
        }
        return low
    }

    /**
     * Yanına yazma, Türkçe [x]'te başlarken (sola yaslıda sol kenarı, sağa yaslıda sağ kenarı; listenin sütunu): engeller
     * [limit] ile aynı; yer yoksa null.
     */
    internal fun besideAt(i: Int, x: Double, right: Boolean, paints: List<TextPaint>, targets: List<TextPainter.Target>,
                          taken: List<TextBox>, twins: List<TextBox>, aspect: Double, current: TextPaint): TextPaint? {
        val c = paints[i].cover
        val lineX = max(1e-6, targets[i].lineHeight) / max(0.1, aspect)
        val w = c.right - c.left
        val reach = max(BESIDE_MAX * w + lineX, REACH_LINES * lineX)
        val limit = limit(i, x, right, own(i, paints, taken, lineX), paints, targets, others(i, taken, twins), aspect)
        if (kotlin.math.abs(limit - x) < ROOM_SHARE * min(w, reach) || (if (right) limit > x else limit < x)) return null
        return if (right) current.copy(spot = TextBox(max(limit, x - w), c.top, x, c.bottom), spotRoom = TextBox(limit, c.top, x, c.bottom))
        else current.copy(spot = TextBox(x, c.top, min(limit, x + w), c.bottom), spotRoom = TextBox(x, c.top, limit, c.bottom))
    }

    /** Ölçülen örtü, zemin ve yazı rengi kalır; kip örtmeye döner, yanına yazma ve ikiz alanları silinir. */
    fun plain(paint: TextPaint): TextPaint = paint.copy(
        mode = TextPaint.MODE_COVER, spot = null, spotRoom = null, twin = null, radius = 0.0, scale = 1.0, tail = null,
        portrait = null, portraitTwin = null, portraitImage = null, portraitSquare = false, edge = null, label = null,
    )

    internal fun overlapY(a: TextBox, b: TextBox): Double = max(0.0, min(a.bottom, b.bottom) - max(a.top, b.top))

    internal fun overlaps(a: TextBox, b: TextBox): Boolean =
        min(a.right, b.right) > max(a.left, b.left) && min(a.bottom, b.bottom) > max(a.top, b.top)

    internal fun shifted(box: TextBox, dy: Double): TextBox = box.copy(top = box.top + dy, bottom = box.bottom + dy)

    /**
     * A: satırın Türkçesi yanında (yer yoksa altında ya da üstünde), koyu etikette; hiçbir yere sığmazsa örtü ([base]).
     * [side]: false ise yanı denenmez (şeridin öbür sekmeleri). İkinci değer: Türkçe altına/üstüne yazıldı.
     */
    internal fun beside(i: Int, paints: List<TextPaint>, targets: List<TextPainter.Target>, taken: List<TextBox>,
                        twins: List<TextBox>, aspect: Double, base: TextPaint, side: Boolean): Pair<TextPaint, Boolean> {
        val c = paints[i].cover
        val lineY = max(1e-6, targets[i].lineHeight)
        val lineX = lineY / max(0.1, aspect)
        val gap = GAP_LINES * lineX
        val edge = EDGE_LINES * lineX
        val eps = 1e-9
        val w = c.right - c.left
        val h = c.bottom - c.top
        // Genişliği ya da yüksekliği olmayan kutu (bozuk okuma) yanına yazılmaz.
        if (w <= eps || h <= eps) return base to false
        val reach = max(BESIDE_MAX * w + lineX, REACH_LINES * lineX)
        val own = own(i, paints, taken, lineX)
        val others = others(i, taken, twins)
        val p = base.copy(mode = TextPaint.MODE_BESIDE, label = LABEL_COLOR)
        val touch = TOUCH_SHARE * h
        if (side && targets[i].align != "right") {
            val left = own.right + gap
            val limit = limit(i, left, false, own, paints, targets, others, aspect)
            if (limit - left >= ROOM_SHARE * min(w, reach)) {
                return p.copy(spot = TextBox(left, c.top, min(limit, left + w), c.bottom),
                    spotRoom = TextBox(left, c.top, limit, c.bottom)) to false
            }
        } else if (side) {
            val right = own.left - gap
            val limit = limit(i, right, true, own, paints, targets, others, aspect)
            if (right - limit >= ROOM_SHARE * min(w, reach)) {
                return p.copy(spot = TextBox(max(limit, right - w), c.top, right, c.bottom),
                    spotRoom = TextBox(limit, c.top, right, c.bottom)) to false
            }
        }
        // Yanına sığmayan etiket (sekme şeridinin sekmesi, sıkışık tuş çubuğu) altına, olmazsa üstüne; aynı satırdaki
        // komşularla arasının ortasını geçmez (komşunun etiketiyle arada boşluk kalır), başka yazının üstüne binmez, uzadığı
        // alan da o bantta başka yazıya varmaz.
        val mates = paints.indices.filter { j ->
            j != i && overlapY(c, paints[j].cover) >= SAME_ROW * min(h, paints[j].cover.bottom - paints[j].cover.top)
        }
        var l = max(edge, own.left - 0.5 * w)
        var r = min(1 - edge, own.right + 0.5 * w)
        for (j in mates) {
            val o = taken[j]
            if (o.left >= own.right - eps) r = min(r, (own.right + o.left) / 2 - gap)
            else if (o.right <= own.left + eps) l = max(l, (o.right + own.left) / 2 + gap)
        }
        val step = GAP_LINES * lineY
        for (top in doubleArrayOf(own.bottom + step, own.top - step - h)) {
            val spot = TextBox(c.left, top, c.right, top + h)
            if (spot.top < 0 || spot.bottom > 1) continue
            if (others.any { (_, o) -> min(o.right, spot.right) > max(o.left, spot.left) && overlapY(o, spot) > touch }) continue
            var bandLeft = l
            var bandRight = r
            for ((_, o) in others) {
                if (overlapY(o, spot) <= touch) continue
                if (o.right <= c.left + eps) bandLeft = max(bandLeft, o.right + gap)
                else if (o.left >= c.right - eps) bandRight = min(bandRight, o.left - gap)
            }
            return p.copy(spot = spot, spotRoom = TextBox(min(bandLeft, c.left), top, max(bandRight, c.right), top + h)) to true
        }
        return base to false
    }

    /**
     * A: görev kartının ikizi kartın hemen altında (yer yoksa üstünde), kartın zemininde; başka yazının ya da ikizin
     * üstüne binmez. İkisine de yer yoksa ya da kart bir listenin parçasıysa null (kartın satırları yanına yazılır; Görevler
     * ekranında son görev ikiz kart, öbürleri yanında çiziliyordu).
     */
    internal fun cardTwin(card: List<Int>, paints: List<TextPaint>, targets: List<TextPainter.Target>, taken: List<TextBox>,
                          twins: List<TextBox>, aspect: Double,
                          portrait: ((List<Int>, String) -> Pair<TextBox, String?>?)? = null): List<Pair<Int, TextPaint>>? {
        val heights = card.map { targets[it].lineHeight }.sorted()
        val line = max(1e-6, heights[heights.size / 2])
        val padY = CARD_PAD_LINES * line
        val padX = padY / max(0.1, aspect)
        val left = card.minOf { taken[it].left }
        if (paints.indices.any { it !in card && kotlin.math.abs(taken[it].left - left) <= COLUMN_LINES * line / max(0.1, aspect) }) return null
        // Kartın zemini: en büyük parçanın (açıklama) ölçülen zemini.
        fun area(b: TextBox) = (b.right - b.left) * (b.bottom - b.top)
        val largest = card.maxByOrNull { area(paints[it].cover) }!!
        val fill = paints[largest].background
        // Kişi resmi: ölçümün bulduğu ya da kareden aranan; ikizde kartın bütün parçalarında aynı (TV ilkinden çizer).
        var face = card.firstNotNullOfOrNull { paints[it].portrait }
        var image = card.firstNotNullOfOrNull { paints[it].portraitImage }
        if (face == null) portrait?.invoke(card, fill)?.let { (found, cut) ->
            face = found
            image = cut
        }
        var union = taken[card[0]]
        for (m in card) union = union.union(taken[m])
        face?.let { union = union.union(it) }
        val box = TextBox(union.left - padX, union.top - padY, union.right + padX, union.bottom + padY)
        val step = (box.bottom - box.top) + CARD_GAP_LINES * line
        val blockers = paints.indices.filter { it !in card }.map { taken[it] } + twins
        fun free(b: TextBox) = b.top >= 0 && b.bottom <= 1 && b.left >= 0 && b.right <= 1 && blockers.none { overlaps(it, b) }
        val dy = when {
            free(shifted(box, step)) -> step
            free(shifted(box, -step)) -> -step
            else -> return null
        }
        val twin = shifted(box, dy)
        val picture = face
        return card.map { m ->
            val spot = shifted(paints[m].cover, dy)
            var p = plain(paints[m]).copy(
                mode = TextPaint.MODE_TWIN, twin = twin, radius = paints[m].radius, background = fill, background2 = null,
                direction = null, patterned = false, spot = spot,
                spotRoom = TextBox(spot.left, spot.top, max(spot.right, twin.right - padX), spot.bottom),
                edge = paints[m].edge,
            )
            if (picture != null) {
                p = p.copy(portrait = picture, portraitTwin = shifted(picture, dy), portraitImage = image, portraitSquare = true)
            }
            m to p
        }
    }
}
