// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Açık zemin üzerindeki koyu yazı (duvardaki kâğıt ilan, tabela, afiş) altyazı değildir. Kullanıcı bildirimi (GitHub
 * #1124, GTA 6): altyazı alanına denk gelen otel odasındaki kâğıt ilan ("SOILED SHEETS, … WILL BE BILLED TO YOUR ROOM";
 * beyaz kâğıt, siyah yazı) altyazı sanılıp çevriliyordu; plaka/tabela kuralı ([SceneText.isSign], #1052) uzun cümleli
 * ilanı yakalamıyor. Oyun altyazısı açık renkli yazıdır (beyaz/sarı), koyu dış çizgiyle ya da yarı saydam koyu zeminde.
 *
 * Satır kutusunun içindeki ve hemen dışındaki şeridin parlaklığına bakılır ([isDarkOnLight]). Zemin satır boyunca
 * değişen bir çizgidir: üst ve alt şeridin her sütunu için komşu sütunların ortancası ([PROFILE_REACH]), kutunun içinde
 * üst ile alt arasında doğrusal; kâğıda vuran ışık şeridi ve satır boyunca kararan kâğıt zemin sayılır (#1124, beta.89:
 * açık mavi kâğıtta lacivert yazı, çapraz ışık şeridi). Zemin açık (pastel kâğıt da), yumuşak ve düz; kutunun içindeki
 * koyu küme (Otsu eşiği, zemine göre) zeminden belirgin koyu ve zeminin en çok [INK_SHADE] katı (renkli mürekkep
 * kontrastıyla koyu sayılır), yazı payı makul ve kutuda zeminden parlak harf yoksa yazı koyu, zemin açıktır. Bloğun
 * satırlarının yarıdan çoğu böyleyse blok sahne yazısıdır ([isDarkBlock]); konuşan adlı blok hep altyazıdır. Koyu altyazılı
 * oyun bozulmasın diye kural oturumda kendini kapatır ([DarkInkStyle]). Mac/iPhone (InkTone.swift) ve Windows
 * (InkTone.cs) aynı kuralları ve eşikleri uygular; ortak deneme dosyası fixtures/dark-ink.json
 * (core/Tests/CouchSubsCoreTests/Fixtures kopyası).
 */
object InkTone {
    /** Yerel zemin (zemin çizgisinin ortancası) en az bu kadarsa açıktır (açık mavi kâğıt #BFE0F0 ≈ 216). */
    const val LIGHT_GROUND = 140
    /** Yazı kümesinin ortalama parlaklığı, altındaki zeminin en çok bu katıysa koyudur (kontrast; lacivert mürekkep de). */
    const val INK_SHADE = 0.66
    /** Yazı kümesi zeminden en az bu kadar koyu olmalı. */
    const val INK_GAP = 70
    /** Kutudaki yazı noktalarının payı bu aralıkta olmalı. */
    const val MIN_INK = 0.04
    const val MAX_INK = 0.5
    /** Zeminden bu kadar (en çok [GLOW_CEILING]'e kadar) parlak nokta harftir; payı [GLOW_SHARE]'i aşarsa yazı açık renklidir. */
    const val GLOW = 20
    const val GLOW_CEILING = 250
    const val GLOW_SHARE = 0.03
    /** Yerel zemin düz olmalı: şeridin zemin çizgisinden sapmasının çeyrekler açıklığı en çok bu kadar. */
    const val GROUND_SPREAD = 40
    /** Zemin çizgisi yumuşak olmalı: komşu iki sütun arasındaki fark en çok bu kadar. */
    const val GROUND_STEP = 40
    /** Zemin çizgisinin bir sütunu, iki yanındaki bu kadar sütunla birlikte şeridin ortancasıdır. */
    const val PROFILE_REACH = 4
    /** Kutunun dışındaki şeridin kalınlığı (satır yüksekliğine oranla). */
    const val RING_SHARE = 0.3
    /** Altyazı günlüğündeki atılma nedeni. */
    const val REASON = "koyu yazı açık zeminde (kâğıt/tabela)"

    private const val SAMPLES_X = 48
    private const val SAMPLES_Y = 10
    private const val RING_SAMPLES = 2
    private const val MIN_SAMPLES = 16

    /** [box] (görüntüye oranla) açık zemin üzerinde koyu yazı mı. [luma]: (x, y) pikselinin parlaklığı, 0–255. */
    fun isDarkOnLight(box: TextBox, width: Int, height: Int, luma: (Int, Int) -> Int): Boolean {
        if (width <= 0 || height <= 0) return false
        val w = width.toDouble()
        val h = height.toDouble()
        val left = box.left.coerceIn(0.0, 1.0) * w
        val right = box.right.coerceIn(0.0, 1.0) * w
        val top = box.top.coerceIn(0.0, 1.0) * h
        val bottom = box.bottom.coerceIn(0.0, 1.0) * h
        if (right - left < 2 || bottom - top < 2) return false
        val inside = grid(left, top, right, bottom, SAMPLES_X, SAMPLES_Y, width, height, luma)
        val d = (bottom - top) * RING_SHARE
        // Şeritler: üst ve alt (SAMPLES_X × RING_SAMPLES), sol ve sağ (RING_SAMPLES × SAMPLES_Y); görüntüden taşan şerit yok.
        val strips = arrayOfNulls<List<Int>>(4)
        if (d >= 1) {
            val bounds = listOf(
                Strip(left, top - d, right, top, SAMPLES_X, RING_SAMPLES),
                Strip(left, bottom, right, bottom + d, SAMPLES_X, RING_SAMPLES),
                Strip(left - d, top, left, bottom, RING_SAMPLES, SAMPLES_Y),
                Strip(right, top, right + d, bottom, RING_SAMPLES, SAMPLES_Y),
            )
            for ((i, s) in bounds.withIndex()) {
                if (s.l >= 0 && s.t >= 0 && s.r <= w && s.b <= h) strips[i] = grid(s.l, s.t, s.r, s.b, s.nx, s.ny, width, height, luma)
            }
        }
        return decide(inside, strips[0], strips[1], strips[2], strips[3])
    }

    private class Strip(val l: Double, val t: Double, val r: Double, val b: Double, val nx: Int, val ny: Int)

    /** Kutunun içindeki ([inside], SAMPLES_X × SAMPLES_Y) ve dışındaki şeritlerin parlaklıklarıyla karar. */
    internal fun decide(inside: List<Int>, top: List<Int>?, bottom: List<Int>?, left: List<Int>?, right: List<Int>?): Boolean {
        val ringCount = listOf(top, bottom, left, right).sumOf { it?.size ?: 0 }
        if (inside.size != SAMPLES_X * SAMPLES_Y || ringCount < MIN_SAMPLES) return false
        // Zemin çizgisi: üst ve alt şeridin sütun sütun ortancası; biri yoksa öteki, ikisi de yoksa yan şeritlerin ortancası.
        var upper = top?.let(::profile)
        val lower = bottom?.let(::profile)
        if (upper == null && lower == null) {
            val sides = ((left ?: emptyList()) + (right ?: emptyList())).sorted()
            upper = List(SAMPLES_X) { sides[sides.size / 2] }
        }
        val up = upper ?: lower!!
        val down = lower ?: upper!!
        fun ground(column: Int, row: Int) = up[column] + (down[column] - up[column]) * (2 * row + 1) / (2 * SAMPLES_Y)
        val line = (up + down).sorted()
        if (line[line.size / 2] < LIGHT_GROUND || line[0] < LIGHT_GROUND - GROUND_SPREAD) return false
        for (p in listOf(up, down)) {
            for (c in 1 until SAMPLES_X) if (kotlin.math.abs(p[c] - p[c - 1]) > GROUND_STEP) return false
        }
        val residuals = mutableListOf<Int>()
        top?.let { s -> s.indices.mapTo(residuals) { s[it] - up[it % SAMPLES_X] } }
        bottom?.let { s -> s.indices.mapTo(residuals) { s[it] - down[it % SAMPLES_X] } }
        left?.let { s -> s.indices.mapTo(residuals) { s[it] - ground(0, it / RING_SAMPLES) } }
        right?.let { s -> s.indices.mapTo(residuals) { s[it] - ground(SAMPLES_X - 1, it / RING_SAMPLES) } }
        residuals.sort()
        if (residuals[residuals.size * 3 / 4] - residuals[residuals.size / 4] > GROUND_SPREAD) return false
        val grounds = inside.indices.map { ground(it % SAMPLES_X, it / SAMPLES_X) }
        // Zemine göre parlaklık (128 zemin); Otsu eşiğinin altı yazıdır.
        val relative = inside.indices.map { (inside[it] - grounds[it] + 128).coerceIn(0, 255) }
        val threshold = otsu(relative)
        val ink = inside.indices.filter { relative[it] <= threshold }
        if (ink.isEmpty() || ink.size == inside.size) return false
        val share = ink.size.toDouble() / inside.size
        if (share < MIN_INK || share > MAX_INK) return false
        val inkMean = ink.sumOf { inside[it] }.toDouble() / ink.size
        val groundMean = ink.sumOf { grounds[it] }.toDouble() / ink.size
        if (groundMean - inkMean < INK_GAP || inkMean > groundMean * INK_SHADE) return false
        val glowing = inside.indices.count { inside[it] >= minOf(grounds[it] + GLOW, GLOW_CEILING) }
        return glowing.toDouble() / inside.size < GLOW_SHARE
    }

    /** Şeridin (SAMPLES_X × RING_SAMPLES) zemin çizgisi: her sütun için [PROFILE_REACH] komşusuyla birlikte ortanca. */
    private fun profile(strip: List<Int>): List<Int> = List(SAMPLES_X) { c ->
        val values = mutableListOf<Int>()
        for (r in 0 until RING_SAMPLES) {
            for (k in maxOf(0, c - PROFILE_REACH)..minOf(SAMPLES_X - 1, c + PROFILE_REACH)) values += strip[r * SAMPLES_X + k]
        }
        values.sort()
        values[values.size / 2]
    }

    /** Bloğun kutulu satırlarının yarıdan çoğu açık zeminde koyu yazı mı. */
    fun isDarkBlock(block: Reading, dark: (TextBox) -> Boolean): Boolean {
        val boxes = block.lines.mapNotNull { it.box }
        if (boxes.isEmpty()) return false
        return boxes.count(dark) * 2 > boxes.size
    }

    /**
     * Okunan alanın parlaklık düzlemi için satır kutusu denetimi (kutular görüntüye oranla). NV21 parlaklığı sınırlı
     * aralıktadır (16–235); Mac ve Windows'un RGB parlaklığıyla aynı eşikler için tam aralığa açılır.
     */
    fun sampler(frame: GrayFrame): (TextBox) -> Boolean = { box ->
        frame.isValid && isDarkOnLight(box, frame.width, frame.height) { x, y ->
            ((frame.at(x, y) - 16) * 255 / 219).coerceIn(0, 255)
        }
    }

    private fun grid(
        left: Double, top: Double, right: Double, bottom: Double, nx: Int, ny: Int, width: Int, height: Int,
        luma: (Int, Int) -> Int,
    ): List<Int> {
        val values = ArrayList<Int>(nx * ny)
        for (sy in 0 until ny) {
            val y = minOf(height - 1, (top + (sy + 0.5) * (bottom - top) / ny).toInt())
            for (sx in 0 until nx) {
                val x = minOf(width - 1, (left + (sx + 0.5) * (right - left) / nx).toInt())
                values += luma(x, y).coerceIn(0, 255)
            }
        }
        return values
    }

    private fun otsu(values: List<Int>): Int {
        val histogram = IntArray(256)
        for (value in values) histogram[value]++
        val total = values.size.toDouble()
        var sum = 0.0
        for (i in 0 until 256) sum += (i * histogram[i]).toDouble()
        var below = 0.0
        var belowSum = 0.0
        var best = -1.0
        var threshold = 127
        for (t in 0 until 255) {
            below += histogram[t]
            if (below == 0.0) continue
            val above = total - below
            if (above == 0.0) break
            belowSum += (t * histogram[t]).toDouble()
            val gap = belowSum / below - (sum - belowSum) / above
            val between = below * above * gap * gap
            if (between > best) {
                best = between
                threshold = t
            }
        }
        return threshold
    }
}

/**
 * Oturumun koyu yazılı altyazı biçimi: ortalanmış, birbirinden farklı (biri ötekini içermeyen, benzemeyen) en az
 * [DISTINCT_BLOCKS] koyu yazılı blok atılınca oyunun altyazısı koyu yazı sayılır ve [InkTone] kuralı o oturumda kapanır.
 * Duvardaki ilan hep aynı yazıdır (kısmi okunsa da), sayılmaz. Hat sıfırlanınca unutulur (Mac/iPhone ve Windows:
 * DarkInkStyle).
 */
class DarkInkStyle {
    companion object {
        const val DISTINCT_BLOCKS = 4
    }

    private val texts = mutableListOf<String>()

    /**
     * Oyunun altyazısı bilinen açık renkli yazı (GTA 6: beyaz): kural hiç kapanmaz, koyu bloklar sayılmaz. Kullanıcı
     * bildirimi (X, beta-104): telefon bulunamadığı anlarda sohbet balonları atılıyor, dört farklı mesaj sayılınca kural
     * kapanıyor, sonraki balonlar altyazı sanılıp telefonun ortasından geçen satır olarak ya da balonların üstüne üst üste
     * çiziliyordu (Mac/iPhone ve Windows ile aynı).
     */
    var lightInk = false

    val isGameStyle: Boolean get() = !lightInk && texts.size >= DISTINCT_BLOCKS

    /** Koyu yazılı diye atılan blok (satır kutuları [area]'ya oranlı). Kural bu blokla kapandıysa true. */
    fun observe(block: Reading, area: TextBox): Boolean {
        if (lightInk || isGameStyle) return false
        val box = block.box?.placedIn(area) ?: return false
        if (!SceneText.isCentered(box)) return false
        val text = TextMatch.normalize(block.text)
        if (text.isEmpty() || texts.any { it.contains(text) || text.contains(it) || TextMatch.isSimilar(it, text) }) return false
        texts += text
        return isGameStyle
    }

    fun reset() = texts.clear()
}
