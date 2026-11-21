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
        /** Karo başına 24×24 nokta: ince yazı (dar başlık, menü etiketi) 12×12'de karodan kaçıyordu (gerçek GTA 6 kareleri). */
        const val POINTS = 24
        const val BRIGHT = 160
        const val DARK = 100
        const val MIN_BRIGHT = 24
        const val MAX_BRIGHT = 288
        const val MIN_DARK = 144
        /** Karo değişti sayılan en küçük fark (576 noktanın; 12×12'deki 6'nın dört katı). */
        const val HAMMING = 24
        const val STABLE_MS = 300L
        const val GONE_MS = 700L
        const val SAMPLE_GAP_MS = 100L
        const val MAX_AREAS = 4
        const val MAX_COVER = 0.35
        /** Aynı karo satırındaki bileşenler arasında en çok bu kadar sütun (iki uç arası) olunca birleşir. */
        const val ROW_REACH = 3
        /** İki bileşen de en az iki karo genişse aynı satırda en çok bu kadar sütun arayla birleşir. */
        const val WIDE_ROW_REACH = 4
        const val NAME = "Screen text"
        /** Menü durumu: en az bu kadar bileşen aynı 300 ms içinde belirip duruyor. */
        const val MENU_COMPONENTS = 3
        /** Menü durumu: bileşenlerin dışındaki karoların en az bu kadarı bulanık/karartılmış (düşük sapmalı). */
        const val MENU_CALM_SHARE = 0.60
        /** Bulanık karo: noktalarının parlaklık sapması bundan küçük. */
        const val CALM_DEVIATION = 18.0
        /** Menüde en çok bu kadar alan (tekerlek menüde 8 etiket, başlık ve alt başlık). */
        const val MAX_MENU_AREAS = 12
        /** Dünya yazısı: kamera hareketi bu süre içinde değişen karolarla ölçülür; arayüz yazısı bu kadar sabit kalmalı. */
        const val WORLD_STABLE_MS = 600L
        /** Bileşenin dışındaki karoların en az bu kadarı değiştiyse kamera hareket ediyor. */
        const val CAMERA_MOVING_SHARE = 0.30
        /** Panel zemini: zemin noktalarının parlaklık sapması en çok bu kadar (çerçeve çizgisi varsa [PANEL_EDGE_DEVIATION]). */
        const val PANEL_DEVIATION = 22.0
        const val PANEL_EDGE_DEVIATION = 30.0
        /** Panel zemini: karoların en az bu kadarının zemin tonu ortak tondan en çok [PANEL_TONE] uzakta. */
        const val PANEL_SAME_TONE = 0.70
        const val PANEL_TONE = 20.0
        private const val WORDS = POINTS * POINTS / 64 // 576 bit maske: 9 × 64
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
    class Sample internal constructor(
        val masks: LongArray, val bright: IntArray, val dark: IntArray, val deviation: FloatArray,
        /** Koyu (<= 100) ve açık (>= 160) noktaların parlaklık toplamları ve kare toplamları (panel zemini kanıtı için). */
        val darkSum: LongArray = LongArray(0), val darkSquares: LongArray = LongArray(0),
        val brightSum: LongArray = LongArray(0), val brightSquares: LongArray = LongArray(0),
        val mean: FloatArray = FloatArray(0),
    )

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

    /** Tanı (yalnız testler): her örneğin bileşenleri. */
    internal var debug: ((String) -> Unit)? = null

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
        val darkSum = LongArray(TILES)
        val darkSquares = LongArray(TILES)
        val brightSum = LongArray(TILES)
        val brightSquares = LongArray(TILES)
        val means = FloatArray(TILES)
        if (width <= 0 || height <= 0) return Sample(masks, bright, dark, deviation, darkSum, darkSquares, brightSum, brightSquares, means)
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
                        brightSum[tile] += value
                        brightSquares[tile] += value.toLong() * value
                    } else if (value <= DARK) {
                        dark[tile]++
                        darkSum[tile] += value
                        darkSquares[tile] += value.toLong() * value
                    }
                    bit++
                }
            }
            val count = (POINTS * POINTS).toDouble()
            val mean = sum / count
            deviation[tile] = kotlin.math.sqrt(maxOf(0.0, squares / count - mean * mean)).toFloat()
            means[tile] = mean.toFloat()
        }
        return Sample(masks, bright, dark, deviation, darkSum, darkSquares, brightSum, brightSquares, means)
    }

    /**
     * Örnek işlenir; önerilen otomatik alanlar döner. [excluded]: altyazı alanı ve kullanıcının ek alanları (oradaki
     * karolar aday olmaz).
     */
    fun update(sample: Sample, excluded: List<CropRegion>, now: Long = clock(), subtitle: CropRegion? = null): List<ExtraArea> = synchronized(lock) {
        val candidate = BooleanArray(TILES)
        val inSubtitle = BooleanArray(TILES)
        val inverse = BooleanArray(TILES)
        for (index in 0 until TILES) {
            val tile = tiles[index]
            val at = index * WORDS
            if (!tile.hasLast || distance(sample.masks, at, tile.last, 0) > HAMMING) tile.stableSince = now
            System.arraycopy(sample.masks, at, tile.last, 0, WORDS)
            tile.hasLast = true
            tile.rejected?.let { if (distance(sample.masks, at, it, 0) > HAMMING) tile.rejected = null }
            val bright = sample.bright[index]
            // Koyu zeminde açık yazı ya da tersi: açık zeminde koyu yazı (menüde seçili satır).
            val dark = sample.dark[index]
            val normal = bright in MIN_BRIGHT..MAX_BRIGHT && dark >= MIN_DARK
            val textLike = normal || (dark in MIN_BRIGHT..MAX_BRIGHT && bright >= MIN_DARK)
            inverse[index] = !normal
            if (!textLike || now - tile.stableSince < STABLE_MS || tile.rejected != null) continue
            val x = (index % COLUMNS + 0.5) / COLUMNS
            val y = (index / COLUMNS + 0.5) / ROWS
            if (excluded.any { x >= it.left && x <= it.right && y >= it.top && y <= it.bottom }) continue
            if (subtitle != null && x >= subtitle.left && x <= subtitle.right && y >= subtitle.top && y <= subtitle.bottom) inSubtitle[index] = true
            candidate[index] = true
        }
        // Açık zeminli karolar (seçili satır) büyük açık nesneleri (kumanda resmi) etiketlerle birleştirip bileşeni
        // %35'i aşırırsa o bileşen yalnız koyu zeminli karolarıyla yeniden kurulur: etiketler kaybolmaz.
        // Ayrılan parçalardan bölgeleri kesişenler yeniden birleşir (bir etiketin karoları tek alan olsun).
        // Hâlâ büyükse (durgun dokulu sahne arayüz kutusuna değiyor) yalnız zemini düz karolarla kurulur.
        fun flat(index: Int): Boolean {
            val n = if (inverse[index]) sample.bright[index] else sample.dark[index]
            if (n <= 0 || sample.darkSum.isEmpty()) return false
            val sum = (if (inverse[index]) sample.brightSum[index] else sample.darkSum[index]).toDouble()
            val squares = (if (inverse[index]) sample.brightSquares[index] else sample.darkSquares[index]).toDouble()
            val mean = sum / n
            // Ara tonlar (ne koyu ne açık) azsa karo yazılı düz zemindir; dokulu sahnede ara ton çoktur.
            val middle = POINTS * POINTS - sample.bright[index] - sample.dark[index]
            return middle <= 0.2 * POINTS * POINTS && kotlin.math.sqrt(maxOf(0.0, squares / n - mean * mean)) <= PANEL_DEVIATION
        }
        fun only(members: List<Int>, keep: (Int) -> Boolean) =
            components(BooleanArray(TILES).also { mask -> members.forEach { if (keep(it)) mask[it] = true } })
        fun split(list: List<List<Int>>): List<List<Int>> = joined(list.flatMap { members ->
            if (regionOf(members) != null) return@flatMap listOf(members)
            val normal = if (members.any { inverse[it] }) only(members) { !inverse[it] } else listOf(members)
            normal.flatMap { part -> if (regionOf(part) != null) listOf(part) else only(part, ::flat) }
        })
        var all = split(components(candidate))
        debug?.invoke("bileşenler: " + all.map { m -> val c = m.map { it % COLUMNS }; val r = m.map { it / COLUMNS }
            "${m.size}k c${c.min()}-${c.max()} r${r.min()}-${r.max()}${if (regionOf(m) == null) " BÜYÜK" else ""}" })
        val wasMenu = menu
        // Menü kanıtı altyazı alanının dışındaki bileşenlerden: iki satırlık altyazı (sakin zeminde) menü sanılıp
        // altyazıyı duraklatmasın.
        menu = isMenu(all.filter { members -> members.any { !inSubtitle[it] } }, sample)
        // Menüde gezinirken seçim çerçevesi kayınca birkaç karo bir an aday olmaktan çıkar: menü alanlarından biri hâlâ
        // görünüyorsa menü sürer (kutular yanıp sönmez, kısa etiketler gürültü sayılmaz).
        if (!menu && wasMenu && autos.any { auto -> auto.menu && auto.tiles.any { candidate[it] } }) menu = true
        // Altyazı alanındaki yazı bulucuya girmez; menü durumunda ise (altyazı duraklar) menünün oradaki etiketleri de alan olur.
        if (!menu && inSubtitle.any { it }) {
            for (index in 0 until TILES) if (inSubtitle[index]) candidate[index] = false
            all = split(components(candidate))
        }
        // Mevcut alanlar: karolarından biri hâlâ adaysa görülmüş sayılır; 700 ms görülmeyen çıkar. Menü kapanınca menü
        // alanı, karoları aday olmaktan çıktığı ilk örnekte hemen kalkar.
        for (auto in autos) if (auto.tiles.any { candidate[it] }) auto.seen = now
        // Menüde gezinirken (seçim çerçevesi kayınca) alanlar 700 ms kuralıyla korunur, kutular yanıp sönmez.
        autos.removeAll { now - it.seen >= GONE_MS || (it.menu && !menu && it.seen != now) }
        // Menüde tek karoluk kısa etiketler ("OFF", "ON") de alan olur.
        var components = all
            .filter { it.size >= if (menu) 1 else 2 }
            .mapNotNull { tilesOf -> regionOf(tilesOf)?.let { tilesOf to it } }
            .sortedByDescending { it.first.size }
        val limit = if (menu) MAX_MENU_AREAS else MAX_AREAS
        // Dünya yazısı elemesi (poster, plaka, tabela): menü dışında bileşen ancak arayüz kanıtıyla alan olur.
        if (!menu) {
            val inside = BooleanArray(TILES)
            components.forEach { (members, _) -> members.forEach { inside[it] = true } }
            var outside = 0
            var moving = 0
            for (index in 0 until TILES) if (!inside[index]) {
                outside++
                if (now - tiles[index].stableSince < WORLD_STABLE_MS) moving++
            }
            val cameraMoving = outside > 0 && moving >= CAMERA_MOVING_SHARE * outside
            components = components.filter { (members, _) ->
                // Kamera hareket ederken yerinde kalan yazı arayüzdür; yeni beliren yazı 600 ms sabit kalmalı.
                (!cameraMoving || members.all { now - tiles[it].stableSince >= WORLD_STABLE_MS }) &&
                    panel(members, inverse, sample)
            }
        }
        // Her alan bir örnekte en çok bir bileşenle eşleşir: en çok ortak karosu olanla (bölge kesişimi yedek). Büyük bir
        // bileşen yanındaki küçük alanı ele geçirip kendi alanı açılamıyordu (kontrol şemasının orta sütunu).
        // Önce ortak karoyla, kalanlar bölge kesişimiyle eşleşir.
        val matched = mutableSetOf<Auto>()
        val owner = HashMap<List<Int>, Auto>()
        for ((members, _) in components) {
            val shared = { auto: Auto -> members.count { it in auto.tiles } }
            autos.filter { it !in matched && shared(it) >= 0.30 * minOf(members.size, it.tiles.size.coerceAtLeast(1)) }
                .maxByOrNull { shared(it) }?.let { matched.add(it); owner[members] = it }
        }
        for ((members, region) in components) {
            if (members in owner) continue
            autos.filter { it !in matched && overlap(it.region, region) >= 0.30 }
                .maxByOrNull { overlap(it.region, region) }?.let { matched.add(it); owner[members] = it }
        }
        for ((members, region) in components) {
            val match = owner[members]
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

    /**
     * Arayüz kanıtı (panel zemini): bileşenin zemin noktaları (koyu zeminde koyu, açık zeminde açık noktalar) düz ya da
     * yarı saydam düzdür: sapması <= 22 ve karoların %70'inin zemin tonu ortak tonun ±20'sinde. Bileşenin çevresi
     * zeminden belirgin farklıysa (kutunun dikdörtgen kenarı) sapma eşiği 30'a gevşer. Doku, harita ya da sahne zemini
     * üstündeki yazı (poster, tabela) kanıt değildir.
     */
    private fun panel(members: List<Int>, inverse: BooleanArray, sample: Sample): Boolean {
        if (sample.mean.isEmpty()) return true
        // Karo başına zemin noktaları: koyu zeminli karoda koyu, açık zeminlide açık noktalar.
        class Ground(val n: Double, val sum: Double, val squares: Double) { val tone get() = sum / n }
        val grounds = members.mapNotNull { index ->
            val n = (if (inverse[index]) sample.bright[index] else sample.dark[index]).toDouble()
            if (n <= 0) null else Ground(n,
                (if (inverse[index]) sample.brightSum[index] else sample.darkSum[index]).toDouble(),
                (if (inverse[index]) sample.brightSquares[index] else sample.darkSquares[index]).toDouble())
        }
        if (grounds.isEmpty()) return false
        // Ortak ton: karoların ortanca tonu. Zemin kümesi bu tondaki karolardır (kutunun kenarına taşan harita ya da
        // yer adı karoları kümeye girmez); sapma bu kümeden ölçülür.
        val median = grounds.map { it.tone }.sorted()[grounds.size / 2]
        val same = grounds.filter { kotlin.math.abs(it.tone - median) <= PANEL_TONE }
        val sameTone = same.size >= PANEL_SAME_TONE * grounds.size
        val count = same.sumOf { it.n }
        val ground = same.sumOf { it.sum } / count
        val deviation = kotlin.math.sqrt(maxOf(0.0, same.sumOf { it.squares } / count - ground * ground))
        val set = members.toHashSet()
        val ring = members.flatMap { index ->
            val column = index % COLUMNS
            listOfNotNull(
                if (column > 0) index - 1 else null, if (column < COLUMNS - 1) index + 1 else null,
                (index - COLUMNS).takeIf { it >= 0 }, (index + COLUMNS).takeIf { it < TILES },
            )
        }.filter { it !in set }.distinct()
        val edge = ring.isNotEmpty() && ring.count { kotlin.math.abs(sample.mean[it] - ground) > 25 } >= 0.6 * ring.size
        debug?.invoke("panel ${members.size}k zemin %.0f sapma %.1f aynıTon %d/%d kenar $edge".format(ground, deviation, same.size, grounds.size))
        return sameTone && deviation <= if (edge) PANEL_EDGE_DEVIATION else PANEL_DEVIATION
    }

    /** Genişletilmiş bölgeleri kesişen bileşenler birleşir; birleşimi çok büyük olan ayrı kalır. */
    internal fun joined(list: List<List<Int>>): List<List<Int>> {
        val groups = list.map { it.toMutableList() }.toMutableList()
        var changed = true
        while (changed) {
            changed = false
            loop@ for (i in groups.indices) for (j in i + 1 until groups.size) {
                val a = regionOf(groups[i]) ?: continue
                val b = regionOf(groups[j]) ?: continue
                if ((a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top) &&
                    !sameRow(groups[i], groups[j])) continue
                val union = groups[i] + groups[j]
                if (regionOf(union) == null) continue
                groups[i] = union.toMutableList()
                groups.removeAt(j)
                changed = true
                break@loop
            }
        }
        return groups
    }

    /**
     * Aynı karo satırındaki bileşenler (menü şeridinin sekmeleri) iki boş karoya kadar birleşir: seçili sekme renkli olduğu
     * için aday olmuyor, iki yanındaki alanlar onu ortadan kesiyordu ("MAP" → "M", #859). İki bileşen de en az iki karo
     * genişse (sekme adları; seçili sekme üç karo olabilir) üç boş karoya kadar ([WIDE_ROW_REACH]); tek karoluk tekerlek
     * etiketleri ayrı kalır.
     */
    internal fun sameRow(a: List<Int>, b: List<Int>): Boolean {
        val aRows = a.map { it / COLUMNS }
        val bRows = b.map { it / COLUMNS }
        if (aRows.min() > bRows.max() || bRows.min() > aRows.max()) return false
        val aColumns = a.map { it % COLUMNS }
        val bColumns = b.map { it % COLUMNS }
        val wide = aColumns.max() - aColumns.min() >= 1 && bColumns.max() - bColumns.min() >= 1
        val reach = if (wide) WIDE_ROW_REACH else ROW_REACH
        return aColumns.min() <= bColumns.max() + reach && bColumns.min() <= aColumns.max() + reach
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
            // Yatayda bir karo: satırın ucu (son harf, tuş simgesi) karonun dışına taşabiliyor.
            left = ((columns.min() - 1.0) / COLUMNS).coerceIn(0.0, 1.0),
            right = ((columns.max() + 2.0) / COLUMNS).coerceIn(0.0, 1.0),
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

/**
 * Otomatik ekran yazısının satır temizliği (gerçek GTA 6 karelerinden; Windows ve Mac ile aynı kurallar):
 * - Kiril/Yunan benzer harfler Latin'e döner ("Мар" → "Map"; yazı tanıma menüde böyle okuyor).
 * - Güveni 0,5'ten düşük ya da harflerinin %30'undan fazlası tuhaf (Latin dışı) satır çevrilmez.
 * - Satır başındaki menü simgesi okuması ("• Store", "? Help", "pi Settings") ve kısa etiketin sonundaki simge çöpü
 *   ("ADD MARKER O", "RADIO CONTROLS •") çeviriye taşınmaz; tuş adları (L3, R1) kalır.
 * - Menü dışında: yalnız büyük harfli, kısa ve gövdesiz satırlar (yer adı "KELI", yayıncı logosu "GAMING",
 *   "REPUBLIC OF") atılır; küçük harfli gövdesi olan kutunun başlığı ("ROB VICKI'S BOSS") kalır.
 */
object AutoText {
    private val homoglyphs = mapOf(
        'А' to 'A', 'В' to 'B', 'Е' to 'E', 'К' to 'K', 'М' to 'M', 'Н' to 'H', 'О' to 'O', 'Р' to 'P', 'С' to 'C',
        'Т' to 'T', 'Х' to 'X', 'а' to 'a', 'е' to 'e', 'о' to 'o', 'р' to 'p', 'с' to 'c', 'у' to 'y', 'х' to 'x',
        'Α' to 'A', 'Β' to 'B', 'Ε' to 'E', 'Η' to 'H', 'Ι' to 'I', 'Κ' to 'K', 'Μ' to 'M', 'Ν' to 'N', 'Ο' to 'O',
        'Ρ' to 'P', 'Τ' to 'T', 'Χ' to 'X', 'Υ' to 'Y', 'ο' to 'o',
    )
    private val keyNames = Regex("^(?:[LR][123]?|[LR]B|[LR]T|△|□|○|✕)$")
    private val dimension = Regex("^[0-9][A-Za-z]$")
    private val shortWords = setOf("OF", "TO", "ON", "UP", "IN", "IT", "AT", "BY", "OR", "GO", "NO", "MY", "ME", "US", "WE",
        "BE", "DO", "SO", "AN", "AS", "IS", "A", "I")

    fun clean(reading: Reading, menu: Boolean): Reading {
        val lines = reading.lines.mapNotNull { line(it, menu) }
        val body = lines.any { l -> l.text.any { it.isLowerCase() } && l.text.count { it.isLetter() } >= 8 }
        // Alandaki satırların yarısından alçak, büyük harfli satır logo ya da marka yazısıdır ("REPUBLIC OF GAMERS").
        val heights = lines.mapNotNull { l -> l.box?.let { it.bottom - it.top } }.sorted()
        val median = if (heights.size >= 3) heights[heights.size / 2] else null
        return Reading(lines.filter { l ->
            val small = median != null && l.box != null && l.box.bottom - l.box.top < 0.5 * median && l.text.none { it.isLowerCase() }
            !small && keep(l.text, menu, body)
        })
    }

    private fun isLatin(c: Char) = c in 'A'..'Z' || c in 'a'..'z' || c in "ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝàáâãäåçèéêëìíîïñòóôõöùúûüýÿĞğİıŞş"

    private fun line(line: TextLine, menu: Boolean): TextLine? {
        // Eğik ya da perspektifli satır (sözcüklerin dikey ortaları kayıyor) oyun dünyasındadır (poster, tabela). Menüde
        // aranmaz (Mac ve Windows gibi): menü arayüzdür, yazı tanıma uzun satırın sözcük kutularını biraz oynatır (GTA 6
        // haritasındaki görev açıklamasının orta satırı eğik sayılıp atılıyordu).
        val words = line.words
        if (!menu && words != null && words.size >= 2) {
            val first = words.minBy { it.box.left }.box
            val last = words.maxBy { it.box.right }.box
            val height = words.map { it.box.bottom - it.box.top }.sorted()[words.size / 2]
            if (height > 0 && kotlin.math.abs((first.top + first.bottom) / 2 - (last.top + last.bottom) / 2) > 0.15 * height) return null
        }
        var text = line.text.map { homoglyphs[it] ?: it }.joinToString("")
        val letters = text.filter { it.isLetter() }
        if (letters.isNotEmpty() && letters.count { !isLatin(it) } > 0.3 * letters.length) return null
        val tokens = text.split(' ').filter { it.isNotEmpty() }.toMutableList()
        var before = 0
        var after = 0
        // Baştaki simge okuması: en çok iki karakter, ardından büyük harfle başlayan sözcük; kısa etikette. Rakamla başlayan
        // harfli parça ("2D VIEW", "3D") sözcüktür.
        if (tokens.size in 2..6 && tokens[0].length <= 2 && ButtonIcons.MARKER !in tokens[0] && !keyNames.matches(tokens[0]) &&
            !dimension.matches(tokens[0]) &&
            tokens[0].uppercase() !in shortWords && tokens[1].first().isUpperCase()) {
            before = text.indexOf(tokens[1])
            tokens.removeAt(0)
        }
        // Sondaki simge çöpü: en çok iki karakter, tuş adı ya da kısa sözcük değil, önünde büyük harfli etiket.
        if (tokens.size >= 2) {
            val last = tokens.last()
            val label = tokens.dropLast(1).joinToString(" ")
            if (last.length <= 2 && ButtonIcons.MARKER !in last && !keyNames.matches(last) && last.uppercase() !in shortWords &&
                label.filter { it.isLetter() }.let { it.isNotEmpty() && it.all { c -> c.isUpperCase() } }) {
                after = text.length - text.lastIndexOf(last)
                tokens.removeAt(tokens.size - 1)
            }
        }
        val cleaned = tokens.joinToString(" ")
        // Güveni düşük okuma çevrilmez; arayüz sözlüğünde birebir olan kısa etiket ("1 Мар" → "Map") yine de kalır.
        if ((line.confidence ?: 1f) < 0.5f && UiCommands.translateLabelLoosely(cleaned) == null) return null
        if (before == 0 && after == 0) return line.copy(text = text)
        // Kutunun atılan kısmı karakter oranıyla daraltılır (stil örneklemesi simgeyi yazı saymasın).
        val box = line.box?.let { b ->
            val total = text.length.coerceAtLeast(1)
            val w = b.right - b.left
            TextBox(b.left + w * before / total, b.top, b.right - w * after / total, b.bottom)
        }
        text = cleaned
        return line.copy(text = text, box = box, words = null, icons = null)
    }

    private fun keep(text: String, menu: Boolean, body: Boolean): Boolean {
        val plain = text.filter { it != ButtonIcons.MARKER }
        // Menüde kısa etiketler çevrilir; ama zaten Türkçe olan tek sözcük (yayın arayüzündeki "Canli") çevrilmez.
        if (menu) return !ScreenTextNoise.isNoise(plain, menu = true) && !TurkishText.isKnownWord(plain.trim('•', ' ', '·'))
        if (plain.any { it.isLowerCase() }) return true
        val letters = plain.count { it.isLetter() }
        val words = plain.split(Regex("\\s+")).count { token -> token.count { it.isLetter() } >= 2 }
        return letters >= 8 && words >= 2 && (words >= 3 || body)
    }
}
