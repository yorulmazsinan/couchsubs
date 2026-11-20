// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.max
import kotlin.math.min

/**
 * Ekranda beliren yazı kutularını (görev, yardım, mesaj) oyundan bağımsız bulur ve geçici ek alan ([ExtraArea.auto])
 * olarak [RegionWatcher]'a verir; okuma, paket/canlı çeviri, önbellek ve yerinde gösterme orada. Sabit bölge yoktur.
 *
 * Kare 32×18 karoya bölünür; her karoda 12×12 nokta örneklenir (parlaklık). Koyu/yarı saydam zeminde açık renk yazı
 * gibi görünen ve 300 ms kıpırdamayan karolar birleşip alan olur. Okunup yazı bulunamayan (ya da gürültü: sayaç, harita,
 * kısa etiket) alanın karoları [rejected] ile işaretlenir; görüntüsü değişmedikçe yeniden okunmaz.
 * Windows (ScreenTextDetector.cs) ve Mac/iPhone (ScreenTextDetector.swift) aynı kuralları ve eşikleri uygular.
 */
class ScreenTextDetector(private val clock: () -> Long = monotonicClock) {
    companion object {
        const val COLUMNS = 32
        const val ROWS = 18
        const val POINTS = 12
        const val BRIGHT = 160
        const val DARK = 100
        const val MIN_BRIGHT = 6
        const val MAX_BRIGHT = 72
        const val MIN_DARK = 36
        const val HAMMING = 6
        const val STABLE_MS = 300L
        const val GONE_MS = 700L
        const val SAMPLE_GAP_MS = 100L
        const val MAX_AREAS = 4
        const val MAX_COVER = 0.35
        const val NAME = "Screen text"
        /** Menü durumu: en az bu kadar bileşen aynı 300 ms içinde belirip duruyor. */
        const val MENU_COMPONENTS = 3
        /** Menü durumu: bileşenlerin dışındaki karoların en az bu kadarı bulanık/karartılmış (düşük sapmalı). */
        const val MENU_CALM_SHARE = 0.60
        /** Bulanık karo: noktalarının parlaklık sapması bundan küçük. */
        const val CALM_DEVIATION = 18.0
        /** Menüde en çok bu kadar alan (tekerlek menüde 8 etiket, başlık ve alt başlık). */
        const val MAX_MENU_AREAS = 12
        private const val WORDS = 3 // 144 bit maske: 3 × 64
        private const val TILES = COLUMNS * ROWS

        private fun distance(a: LongArray, aAt: Int, b: LongArray, bAt: Int): Int {
            var bits = 0
            for (i in 0 until WORDS) bits += java.lang.Long.bitCount(a[aAt + i] xor b[bAt + i])
            return bits
        }

        /** İki bölgenin kesişimi, küçük olanın alanına oranla. */
        internal fun overlap(a: CropRegion, b: CropRegion): Double {
            val w = min(a.right, b.right) - max(a.left, b.left)
            val h = min(a.bottom, b.bottom) - max(a.top, b.top)
            if (w <= 0 || h <= 0) return 0.0
            val smaller = min((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top))
            return if (smaller <= 0) 0.0 else w * h / smaller
        }
    }

    /** Bir karenin karo izleri: maskeler (karo başına 3 Long), açık ve koyu nokta sayıları. */
    class Sample internal constructor(val masks: LongArray, val bright: IntArray, val dark: IntArray, val deviation: FloatArray)

    private class Tile {
        val last = LongArray(WORDS)
        var hasLast = false
        var stableSince = 0L
        var rejected: LongArray? = null
    }

    private class Auto(val id: String, var region: CropRegion, var seen: Long, val tiles: MutableSet<Int>, var menu: Boolean = false)

    private val lock = Any()
    private val tiles = Array(TILES) { Tile() }
    private var autos = mutableListOf<Auto>()
    private var counter = 0
    private var lastSample: Long? = null
    private var busy = false

    /** Şu an önerilen otomatik alanlar. */
    val areas: List<ExtraArea>
        get() = synchronized(lock) { autos.map { it.area() } }

    /** Son örnekte menü durumu vardı (tekerlek ya da duraklatma menüsü: kısa etiketler de çevrilir). */
    var menu = false
        private set

    private fun Auto.area() = ExtraArea(id, NAME, region, auto = true, menu = menu)

    /**
     * Örnek alma zamanı geldiyse (son örnekten 100 ms geçti ve önceki örnek bitti) true; çağıran örneği alıp
     * [update]'e verir, sonunda [finished]'ı çağırır. Tek uçuş: süren örnek varken gelen kare atlanır.
     */
    fun begin(now: Long = clock()): Boolean = synchronized(lock) {
        if (busy) return false
        lastSample?.let { if (now - it < SAMPLE_GAP_MS) return false }
        lastSample = now
        busy = true
        true
    }

    fun finished(): Unit = synchronized(lock) { busy = false }

    /**
     * Karenin karo izleri. [luma] (x, y) noktasının parlaklığını (0–255) verir; kare iş parçacığında çağrılır ve yalnız
     * 32×18×144 nokta okur (çözücünün arabelleği bundan sonra saklanmaz).
     */
    fun sample(width: Int, height: Int, luma: (Int, Int) -> Int): Sample {
        val masks = LongArray(TILES * WORDS)
        val bright = IntArray(TILES)
        val dark = IntArray(TILES)
        val deviation = FloatArray(TILES)
        if (width <= 0 || height <= 0) return Sample(masks, bright, dark, deviation)
        val xs = IntArray(COLUMNS * POINTS) { ((it + 0.5) * width / (COLUMNS * POINTS)).toInt().coerceIn(0, width - 1) }
        val ys = IntArray(ROWS * POINTS) { ((it + 0.5) * height / (ROWS * POINTS)).toInt().coerceIn(0, height - 1) }
        for (row in 0 until ROWS) for (column in 0 until COLUMNS) {
            val tile = row * COLUMNS + column
            var bit = 0
            var sum = 0L
            var squares = 0L
            for (py in 0 until POINTS) {
                val y = ys[row * POINTS + py]
                for (px in 0 until POINTS) {
                    val value = luma(xs[column * POINTS + px], y)
                    sum += value
                    squares += value.toLong() * value
                    if (value >= BRIGHT) {
                        masks[tile * WORDS + (bit shr 6)] = masks[tile * WORDS + (bit shr 6)] or (1L shl (bit and 63))
                        bright[tile]++
                    } else if (value <= DARK) {
                        dark[tile]++
                    }
                    bit++
                }
            }
            val count = (POINTS * POINTS).toDouble()
            val mean = sum / count
            deviation[tile] = kotlin.math.sqrt(maxOf(0.0, squares / count - mean * mean)).toFloat()
        }
        return Sample(masks, bright, dark, deviation)
    }

    /**
     * Örnek işlenir; önerilen otomatik alanlar döner. [excluded]: altyazı alanı ve kullanıcının ek alanları (oradaki
     * karolar aday olmaz).
     */
    fun update(sample: Sample, excluded: List<CropRegion>, now: Long = clock()): List<ExtraArea> = synchronized(lock) {
        val candidate = BooleanArray(TILES)
        for (index in 0 until TILES) {
            val tile = tiles[index]
            val at = index * WORDS
            if (!tile.hasLast || distance(sample.masks, at, tile.last, 0) > HAMMING) tile.stableSince = now
            System.arraycopy(sample.masks, at, tile.last, 0, WORDS)
            tile.hasLast = true
            tile.rejected?.let { if (distance(sample.masks, at, it, 0) > HAMMING) tile.rejected = null }
            val bright = sample.bright[index]
            val textLike = bright in MIN_BRIGHT..MAX_BRIGHT && sample.dark[index] >= MIN_DARK
            if (!textLike || now - tile.stableSince < STABLE_MS || tile.rejected != null) continue
            val x = (index % COLUMNS + 0.5) / COLUMNS
            val y = (index / COLUMNS + 0.5) / ROWS
            if (excluded.any { x >= it.left && x <= it.right && y >= it.top && y <= it.bottom }) continue
            candidate[index] = true
        }
        val all = components(candidate)
        menu = isMenu(all, sample)
        // Mevcut alanlar: karolarından biri hâlâ adaysa görülmüş sayılır; 700 ms görülmeyen çıkar. Menü kapanınca menü
        // alanı, karoları aday olmaktan çıktığı ilk örnekte hemen kalkar.
        for (auto in autos) if (auto.tiles.any { candidate[it] }) auto.seen = now
        // Menüde gezinirken (seçim çerçevesi kayınca) alanlar 700 ms kuralıyla korunur, kutular yanıp sönmez.
        autos.removeAll { now - it.seen >= GONE_MS || (it.menu && !menu && it.seen != now) }
        // Menüde tek karoluk kısa etiketler ("OFF", "ON") de alan olur.
        val components = all
            .filter { it.size >= if (menu) 1 else 2 }
            .mapNotNull { tilesOf -> regionOf(tilesOf)?.let { tilesOf to it } }
            .sortedByDescending { it.first.size }
        val limit = if (menu) MAX_MENU_AREAS else MAX_AREAS
        for ((members, region) in components) {
            val match = autos.firstOrNull { overlap(it.region, region) >= 0.30 }
            if (match != null) {
                if (moved(match.region, region)) match.region = region
                match.tiles.clear()
                match.tiles.addAll(members)
                match.seen = now
                match.menu = menu
            } else if (autos.size < limit) {
                autos.add(Auto("auto-${++counter}", region, now, members.toMutableSet(), menu))
            }
        }
        autos.map { it.area() }
    }

    /**
     * [RegionWatcher] alanı okudu ama yazı bulamadı ya da yazı gürültüydü: karoları bu görüntüyle reddedilir (görüntü
     * değişmedikçe aday olmaz), alan çıkar.
     */
    fun rejected(id: String): Unit = synchronized(lock) {
        val auto = autos.firstOrNull { it.id == id } ?: return
        val region = auto.region
        for (index in 0 until TILES) {
            val x = (index % COLUMNS + 0.5) / COLUMNS
            val y = (index / COLUMNS + 0.5) / ROWS
            if (index in auto.tiles || (x >= region.left && x <= region.right && y >= region.top && y <= region.bottom)) {
                tiles[index].rejected = tiles[index].last.copyOf()
            }
        }
        autos.remove(auto)
    }

    /** Çeviri durdu ya da oturum yenilendi: alanlar ve karo durumu sıfırlanır. */
    fun reset(): Unit = synchronized(lock) {
        for (index in 0 until TILES) tiles[index] = Tile()
        autos.clear()
        menu = false
        lastSample = null
        busy = false
    }

    /**
     * Menü durumu: en az [MENU_COMPONENTS] aday bileşen aynı 300 ms içinde belirip duruyor ve bileşenlerin dışındaki
     * karoların en az %60'ı bulanık/karartılmış (menü arkasındaki oyun sahnesi). Net, hareketli sahnede kısa etiketler
     * gürültü sayılmaya devam eder.
     */
    private fun isMenu(components: List<List<Int>>, sample: Sample): Boolean {
        if (components.size < MENU_COMPONENTS) return false
        val settled = components.map { members -> members.maxOf { tiles[it].stableSince } }.sorted()
        val together = (0..settled.size - MENU_COMPONENTS).any { settled[it + MENU_COMPONENTS - 1] - settled[it] <= STABLE_MS }
        if (!together) return false
        val inside = BooleanArray(TILES)
        components.forEach { members -> members.forEach { inside[it] = true } }
        var outside = 0
        var calm = 0
        for (index in 0 until TILES) if (!inside[index]) {
            outside++
            if (sample.deviation[index] < CALM_DEVIATION) calm++
        }
        return outside > 0 && calm >= MENU_CALM_SHARE * outside
    }

    private fun moved(old: CropRegion, new: CropRegion): Boolean {
        val dx = 1.0 / COLUMNS - 1e-9
        val dy = 1.0 / ROWS - 1e-9
        return kotlin.math.abs(old.left - new.left) >= dx || kotlin.math.abs(old.right - new.right) >= dx ||
            kotlin.math.abs(old.top - new.top) >= dy || kotlin.math.abs(old.bottom - new.bottom) >= dy
    }

    /** Sınır kutusu yarım karo genişletilmiş bölge; ekranın %35'inden büyük bileşen (sahne dokusu) için null. */
    private fun regionOf(members: List<Int>): CropRegion? {
        val columns = members.map { it % COLUMNS }
        val rows = members.map { it / COLUMNS }
        val width = columns.max() - columns.min() + 1
        val height = rows.max() - rows.min() + 1
        if (width.toDouble() * height / TILES > MAX_COVER) return null
        return CropRegion(
            top = ((rows.min() - 0.5) / ROWS).coerceIn(0.0, 1.0),
            bottom = ((rows.max() + 1.5) / ROWS).coerceIn(0.0, 1.0),
            left = ((columns.min() - 0.5) / COLUMNS).coerceIn(0.0, 1.0),
            right = ((columns.max() + 1.5) / COLUMNS).coerceIn(0.0, 1.0),
        )
    }

    /** Aday karoların bileşenleri: 4-komşuluk, ayrıca aynı satırda arada en çok bir boş karo. */
    private fun components(candidate: BooleanArray): List<List<Int>> {
        val seen = BooleanArray(TILES)
        val result = mutableListOf<List<Int>>()
        val stack = ArrayDeque<Int>()
        for (start in 0 until TILES) {
            if (!candidate[start] || seen[start]) continue
            val members = mutableListOf<Int>()
            seen[start] = true
            stack.addLast(start)
            while (stack.isNotEmpty()) {
                val index = stack.removeLast()
                members.add(index)
                val column = index % COLUMNS
                val row = index / COLUMNS
                val next = intArrayOf(
                    if (column > 0) index - 1 else -1, if (column < COLUMNS - 1) index + 1 else -1,
                    if (column > 1) index - 2 else -1, if (column < COLUMNS - 2) index + 2 else -1,
                    if (row > 0) index - COLUMNS else -1, if (row < ROWS - 1) index + COLUMNS else -1,
                )
                for (n in next) if (n >= 0 && candidate[n] && !seen[n]) {
                    seen[n] = true
                    stack.addLast(n)
                }
            }
            result.add(members)
        }
        return result
    }
}

/** Otomatik alanda okunan yazı gürültü mü (sayaç, saat, para, tek sözcüklük etiket). Windows ve Mac ile aynı kurallar. */
object ScreenTextNoise {
    /**
     * [menu]: menü durumunda kısa etiketler ("OFF", "Map") de çevrilir; yalnız sayı/simge/noktalama olan etiketler
     * ("40", "0", "x3", "100%") her durumda gürültüdür.
     */
    fun isNoise(text: String, menu: Boolean = false): Boolean {
        val plain = text.filter { it != ButtonIcons.MARKER }
        val letters = plain.count { it.isLetter() }
        if (menu) return letters == 0 || (letters <= 1 && plain.any { it.isDigit() })
        if (letters < 8) return true
        if (plain.count { it.isDigit() } > letters / 2) return true
        val words = plain.split(Regex("\\s+")).count { token -> token.count { it.isLetter() } >= 2 }
        if (words < 2) return true
        if (plain.none { it.isLowerCase() } && words < 3) return true
        return false
    }
}
