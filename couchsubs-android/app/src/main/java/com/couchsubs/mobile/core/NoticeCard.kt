// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * GTA 6'nın sağ alttaki bildirim kartı (gelen arama "Withheld Number", mesaj önizlemesi, uyarı): açık renkli, köşesi
 * yuvarlak düz kart; solda simge, üstte kalın başlık, altında koyu yazılı gövde. Kullanıcı bildirimi (GitHub #1443, X'te
 * başkaları da: "sağ alt mesajlar çevrilmiyor"): kartın yalnız başlığı (otomatik ekran yazısı) çevriliyor, gövdesi hiç
 * çevrilmiyordu. İki neden: kenar bildirimi yolu ([ScreenNotices]) yalnız altyazı alanı "Tam ekran"ken çalışıyordu; alt
 * şerit altyazı alanı kartın bir kısmını kesince gövde "koyu yazı açık zeminde (kâğıt/tabela)" ([InkTone]) sayılıp
 * atılıyordu. Otomatik ekran yazısı da menü dışında yalnız koyu zemindeki açık yazıyı bulur.
 *
 * Artık oyun GTA 6 iken (ekran yazısı ya da telefon çevirisi açık) altyazı alanında okunan blok, sahne yazısı
 * süzgeçlerinden ve görev/HUD ayıklamasından önce kart mı diye bakılır ([split]): bloğun kutusu karenin sağında
 * ([isCandidate]) ve karede çevresinde düz, açık renkli, kapalı bir kart bulunuyor ([bounds]). Kart blokları altyazıya
 * girmez; kartın bütün yeri (alan kartı kesse de) "auto-notice-<n>" ek alanı olur ([ScreenNotices.observe]), başlık ve
 * gövde kendi yerinde, kartın üstüne örtülerek çevrilir. Altyazı alanının ortasındaki kâğıt ilan ve tabela kart sayılmaz;
 * onları [InkTone] atmaya devam eder.
 *
 * Kart araması karenin [GRID_WIDTH] × [GRID_HEIGHT] örnek ağında yapılır (karenin çözünürlüğünden bağımsız): kutunun içinin
 * üst çeyreği kartın zemini (en az [LIGHT_GROUND]), kutu her yöne bir örnek satırı/sütunu kadar büyütülür; büyütülen
 * satırın en az [GROUND_SHARE] kadarı zemin, en çok [OTHER_SHARE] kadarı zeminden de mürekkepten de farklıysa satır
 * kartındır. Kart kapalıdır: dört yanının en çok [EDGE_REACH] örnek dışında kart rengi biter, karenin kenarına değmez, boyu
 * sınırlıdır, sağ kenarı karenin sağına yakındır. Kartın kutusunda kendi başına aranamayan blok (simgenin yanındaki kısa
 * başlık) bulunan kartın içindeyse o karta katılır. Mac/iPhone (NoticeCard.swift) ve Windows (NoticeCard.cs) aynı
 * kuralları ve eşikleri uygular; ortak deneme dosyası fixtures/notice-card.json (core/Tests/CouchSubsCoreTests/Fixtures
 * kopyası).
 */
object NoticeCard {
    const val GRID_WIDTH = 480
    const val GRID_HEIGHT = 270
    /** Kartın zemini (kutunun içinin üst çeyreği) en az bu kadar açık. Kart yarı saydam beyazdır: gündüz ~230, gece ~150. */
    const val LIGHT_GROUND = 120
    const val TOLERANCE = 24
    const val INK_GAP = 60
    const val GROUND_SHARE = 0.3
    const val OTHER_SHARE = 0.15
    const val MIN_INK = 0.03
    const val MAX_INK = 0.5
    const val MIN_LEFT = 0.5
    const val MIN_CENTER = 0.6
    const val MIN_RIGHT = 0.85
    const val MAX_RIGHT = 0.995
    const val CARD_LEFT = 0.45
    const val MIN_WIDTH = 0.1
    const val MAX_WIDTH = 0.35
    const val MIN_HEIGHT = 0.04
    const val MAX_HEIGHT = 0.35
    const val EDGE_SHARE = 0.5
    const val EDGE_REACH = 3
    const val MARGIN = 2

    /** Altyazı hattı bildirim kartı arar mı: çeviri sürüyor, oyun GTA 6 ve ekran yazısı ya da telefon çevirisi açık. */
    fun enabled(running: Boolean, game: String?, screenText: Boolean, phone: Boolean): Boolean =
        running && game != null && GameName.key(game) == "gta 6" && (screenText || phone)

    /** Blok kutusu (karede) bildirim kartı adayı mı: karenin sağında. */
    fun isCandidate(box: TextBox): Boolean =
        box.right > box.left && box.bottom > box.top && box.left >= MIN_LEFT && (box.left + box.right) / 2 >= MIN_CENTER

    /** [box] (karede) çevresindeki bildirim kartının karedeki yeri; kart yoksa null. [luma]: karenin (piksel) parlaklığı. */
    fun bounds(box: TextBox, width: Int, height: Int, luma: (Int, Int) -> Int): TextBox? {
        if (width <= 0 || height <= 0 || !isCandidate(box)) return null
        val gw = GRID_WIDTH
        val gh = GRID_HEIGHT
        fun sample(gx: Int, gy: Int): Int {
            val x = min(width - 1, ((gx + 0.5) * width / gw).toInt())
            val y = min(height - 1, ((gy + 0.5) * height / gh).toInt())
            return luma(x, y).coerceIn(0, 255)
        }
        var l = (box.left * gw).toInt().coerceIn(0, gw - 1)
        var r = ((box.right * gw).toInt() - 1).coerceIn(0, gw - 1)
        var t = (box.top * gh).toInt().coerceIn(0, gh - 1)
        var b = ((box.bottom * gh).toInt() - 1).coerceIn(0, gh - 1)
        if (r - l < 2 || b - t < 1) return null
        val inside = ArrayList<Int>()
        for (gy in t..b) for (gx in l..r) inside.add(sample(gx, gy))
        val ground = inside.sorted()[inside.size * 3 / 4]
        if (ground < LIGHT_GROUND) return null
        val ink = inside.count { it <= ground - INK_GAP }.toDouble() / inside.size
        if (ink < MIN_INK || ink > MAX_INK) return null
        fun isCard(values: List<Int>): Boolean {
            var flat = 0
            var other = 0
            for (value in values) {
                if (abs(value - ground) <= TOLERANCE) flat++ else if (value > ground - INK_GAP) other++
            }
            return flat >= GROUND_SHARE * values.size && other <= OTHER_SHARE * values.size
        }
        fun column(gx: Int) = (t..b).map { sample(gx, it) }
        fun row(gy: Int) = (l..r).map { sample(it, gy) }
        val l0 = l
        val t0 = t
        val b0 = b
        var grew = true
        while (grew) {
            grew = false
            if (r + 1 < gw && isCard(column(r + 1))) { r++; grew = true }
            if (l > 0 && isCard(column(l - 1))) { l--; grew = true }
            if (t > 0 && isCard(row(t - 1))) { t--; grew = true }
            if (b + 1 < gh && isCard(row(b + 1))) { b++; grew = true }
        }
        // Kart kapalıdır: karenin kenarına dayanmaz (açık gökyüzü, kar), yazının çevresinde kart payı vardır.
        if (l <= 0 || t <= 0 || r + 1 >= gw || b + 1 >= gh || l0 - l < MARGIN || (t0 - t) + (b - b0) < MARGIN) return null
        fun apart(values: List<Int>) = values.count { abs(it - ground) <= TOLERANCE } <= EDGE_SHARE * values.size
        // Kenarın hemen dışı yumuşak geçiş (kenar çizgisi, gölge) olabilir: en çok EDGE_REACH örnek dışarıda kart rengi biter.
        val reach = 1..EDGE_REACH
        val outside = listOf(
            reach.map { column(max(0, l - it)) }, reach.map { column(min(gw - 1, r + it)) },
            reach.map { row(max(0, t - it)) }, reach.map { row(min(gh - 1, b + it)) },
        )
        if (!outside.all { side -> side.any { apart(it) } }) return null
        val card = TextBox(l.toDouble() / gw, t.toDouble() / gh, (r + 1).toDouble() / gw, (b + 1).toDouble() / gh)
        val w = card.right - card.left
        val h = card.bottom - card.top
        if (card.right < MIN_RIGHT || card.right > MAX_RIGHT || card.left < CARD_LEFT ||
            w < MIN_WIDTH || w > MAX_WIDTH || h < MIN_HEIGHT || h > MAX_HEIGHT) return null
        return card
    }

    /** Okumanın bildirim kartı blokları (karede) ve kalan satırları ([split]). */
    data class Split(val kept: Reading, val cards: List<Pair<Reading, TextBox>>)

    /**
     * Okumanın (satır kutuları [area]'ya oranlı) bildirim kartı blokları ile kalan satırları. [card]: blok kutusu (karede)
     * için kartın karedeki yeri. Aynı karta düşen bloklar (başlık ve gövde) tek karttır. Kart blokları karede (satır
     * kutuları kareye oranlı) döner; kalan satırlar okumadaki sırasıyla.
     */
    fun split(reading: Reading, area: TextBox, card: (TextBox) -> TextBox?): Split {
        val lines = reading.lines
        if (lines.isEmpty() || lines.any { it.box == null }) return Split(reading, emptyList())
        val taken = mutableSetOf<Int>()
        val cards = mutableListOf<Pair<MutableList<Int>, TextBox>>()
        val missed = mutableListOf<Pair<List<Int>, TextBox>>()
        for (block in Reading.blocks(lines, area)) {
            val box = block.map { lines[it].box!!.placedIn(area) }.reduce { a, c -> a.union(c) }
            if (!isCandidate(box)) continue
            val found = card(box)
            if (found == null) {
                missed.add(block to box)
                continue
            }
            val at = cards.indexOfFirst { overlaps(it.second, found) }
            if (at >= 0) {
                cards[at].first.addAll(block)
                cards[at] = cards[at].first to cards[at].second.union(found)
            } else {
                cards.add(block.toMutableList() to found)
            }
            taken.addAll(block)
        }
        if (cards.isEmpty()) return Split(reading, emptyList())
        // Kartın içinde kalan öteki blok (simgenin yanındaki kısa başlık) da o karttır; kendi başına kart aranamasa da.
        for ((block, box) in missed) {
            val at = cards.indexOfFirst { contains(it.second, box) }
            if (at < 0) continue
            cards[at].first.addAll(block)
            taken.addAll(block)
        }
        val kept = Reading(lines.indices.filter { it !in taken }.map { lines[it] })
        return Split(kept, cards.map { (indices, found) ->
            Reading(indices.sorted().map { lines[it].copy(box = lines[it].box?.placedIn(area)) }) to found
        })
    }

    /** Kutu kartın içinde mi (yazı tanımanın kutu payıyla). */
    internal fun contains(card: TextBox, box: TextBox): Boolean {
        val pad = 0.005
        return box.left >= card.left - pad && box.right <= card.right + pad && box.top >= card.top - pad && box.bottom <= card.bottom + pad
    }

    /** İki kart aynı mı: küçüğünün alanının en az yarısı kadar örtüşüyor. */
    internal fun overlaps(a: TextBox, b: TextBox): Boolean {
        val w = min(a.right, b.right) - max(a.left, b.left)
        val h = min(a.bottom, b.bottom) - max(a.top, b.top)
        if (w <= 0 || h <= 0) return false
        val smaller = min((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top))
        return w * h >= 0.5 * smaller
    }

    /**
     * Bütün karenin parlaklığı ([GrayFrame]; video Y düzlemi, sınırlı aralık 16–235) için kart araması ([bounds]); sağda aday
     * blok yoksa kareye hiç bakılmaz.
     */
    fun sampler(frame: GrayFrame): (TextBox) -> TextBox? = { box ->
        if (!isCandidate(box) || !frame.isValid) null
        else bounds(box, frame.width, frame.height) { x, y -> ((frame.at(x, y) - 16) * 255 / 219).coerceIn(0, 255) }
    }

    /**
     * Video karesinin Y düzleminden kart araması için küçük kopya ([GRID_WIDTH] × [GRID_HEIGHT]; kare arabelleği okuma
     * sürerken yeniden kullanılır, OCR iş parçacığı bu kopyaya bakar).
     */
    fun grid(width: Int, height: Int, luma: (Int, Int) -> Int): GrayFrame {
        val bytes = ByteArray(GRID_WIDTH * GRID_HEIGHT)
        for (gy in 0 until GRID_HEIGHT) {
            val y = min(height - 1, ((gy + 0.5) * height / GRID_HEIGHT).toInt())
            for (gx in 0 until GRID_WIDTH) {
                val x = min(width - 1, ((gx + 0.5) * width / GRID_WIDTH).toInt())
                bytes[gy * GRID_WIDTH + gx] = luma(x, y).coerceIn(0, 255).toByte()
            }
        }
        return GrayFrame(bytes, GRID_WIDTH, GRID_HEIGHT)
    }
}
