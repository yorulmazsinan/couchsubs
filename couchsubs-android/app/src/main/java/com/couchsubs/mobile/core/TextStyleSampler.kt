// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

/** Bloğun zemini ve yazı rengi (#RRGGBB); [flat]: zemin düz (çeviri kutusu tam opak doldurulur). */
data class TextSurface(val background: String, val foreground: String, val flat: Boolean = true)

/** Özgün yazının görünüşü: kalın, dar aile, hizalama ("left", "center", "right"), BÜYÜK HARF. */
data class TextLook(val bold: Boolean, val condensed: Boolean, val align: String, val upper: Boolean)

/**
 * Otomatik bulunan ekran yazısının stili (Google Lens tarzı yerinde çeviri için): blok kutusundaki pikseller parlaklığa
 * göre Otsu eşiğiyle ikiye ayrılır, az olan küme yazı, çok olan zemindir. Android'de çözücünün karesi yalnız parlaklık
 * düzlemidir; renk verilmezse renkler gri tonudur (#LLLLLL). Windows ve Mac/iPhone ile aynı algoritma ve eşikler
 * (TextStyleSampler).
 */
object TextStyleSampler {
    const val BOLD_INK = 0.28
    const val CONDENSED = 0.45
    const val UPPER_SHARE = 0.80
    /** Zemin kümesinin renk sapması (üç kanalın sapmasının ortalaması) bundan küçükse düz zemin (Mac/Windows ile aynı). */
    const val FLAT_DEVIATION = 16.0
    private const val SAMPLES_X = 48
    private const val SAMPLES_Y = 10
    private val turkish = Locale.forLanguageTag("tr")

    data class Style(val surface: TextSurface, val look: TextLook)

    /**
     * [frame] içindeki piksel dikdörtgeni ([left], [top], [right], [bottom]; dışlayıcı sağ/alt), satır yüksekliği
     * piksel olarak [lineHeight], özgün metin [source] ("\n" satırları) ve satırların sol/sağ kenarları [edges] (herhangi
     * bir ortak ölçekte). Dikdörtgen boşsa null.
     */
    fun sample(
        frame: GrayFrame, left: Int, top: Int, right: Int, bottom: Int, lineHeight: Double, source: String,
        edges: List<Pair<Double, Double>> = emptyList(),
        /** Aynı karenin (x, y) noktasının rengi (0xRRGGBB); verilirse kümelerin rengi gerçek renktir, yoksa gri ton. */
        color: ((Int, Int) -> Int)? = null,
        /** Düz zemin sayılan en büyük sapma (yarı saydam kart paneli için daha geniş). */
        flatLimit: Double = FLAT_DEVIATION,
    ): Style? {
        val l = left.coerceIn(0, frame.width)
        val r = right.coerceIn(0, frame.width)
        val t = top.coerceIn(0, frame.height)
        val b = bottom.coerceIn(0, frame.height)
        if (r - l < 2 || b - t < 2 || !frame.isValid) return null
        // Mac/iPhone ve Windows ile aynı: kutu 48 × 10 noktalık ızgarayla örneklenir, kümelerin renk sapması (düz zemin)
        // üç renk kanalının sapmasının ortalamasıdır. Eskiden kutunun her pikseli alınıyor, sapma yalnız parlaklıktan ve
        // 12 eşiğiyle ölçülüyordu: haritanın tuş listesinde "ADD MARKER" satırının zemin kümesi (mavi deniz + açık gri
        // harf kenarı) parlaklıkça düz çıkıyor, uzaktaki şeride bakılmıyor, kutu denizin üstünde grimsi (#608096)
        // çiziliyordu (#1268; Mac'te deniz mavisi).
        val pixels = ArrayList<Pixel>(SAMPLES_X * SAMPLES_Y)
        collect(frame, color, l, t, r, b, pixels)
        if (pixels.size < 8) return null
        val histogram = IntArray(256)
        for (pixel in pixels) histogram[pixel.luma]++
        val threshold = otsu(histogram)
        val low = pixels.filter { it.luma <= threshold }
        val high = pixels.filter { it.luma > threshold }
        if (low.isEmpty() || high.isEmpty()) return null
        var ink = if (low.size < high.size) low else high
        var ground = if (low.size < high.size) high else low
        // Zemin, kutunun hemen dışındaki şeride (yazı yok) parlaklıkça yakın olan kümedir: sıkı kutudaki kalın dar yazıda
        // harf noktaları zeminden çok olabiliyor, kutu beyaz çiziliyordu (#860). Çok olan küme kutunun kenarını da
        // dolduruyorsa ([FILLED_EDGE]; seçili menü satırının ters rengi kutunun kendisidir) zemin odur.
        val ring = surrounding(frame, color, l, t, r, b)
        if (ring != null) {
            val around = ring.map { it.luma }.sorted().let { it[it.size / 2].toDouble() }
            val lowFirst = abs(low.map { it.luma }.average() - around) <= abs(high.map { it.luma }.average() - around)
            val groundIsLow = low.size >= high.size
            val edges = pixels.count { it.edge }
            val edgeShare = if (edges == 0) 0.0 else ground.count { it.edge }.toDouble() / edges
            if (lowFirst != groundIsLow && edgeShare < FILLED_EDGE) ink = ground.also { ground = ink }
        }
        val inkCount = ink.size.toLong()
        val groundCount = ground.size.toLong()
        var groundHex = mean(ground)
        var inkHex = mean(ink)
        val flat = deviation(ground) < flatLimit
        var shade = ground.map { it.luma }.average()
        // Düz olmayan zeminde kenarlıklı yazı (GTA 6 haritasındaki tuş ipuçları: beyaz harf, koyu kenarlık, açık mavi deniz):
        // kutunun içinde üç ton var, zemin kümesi harfle denizin karışımı çıkıyor, kutu denizin üstünde açık gri
        // çiziliyordu. Yazının hemen çevresindeki şerit düzse zemin odur.
        // Şeridin yan parçası yazının yanındaki tuş simgesine (RECENTER Ⓛ3, 2D VIEW Ⓡ3), alt/üst parçası kutudan taşan harf
        // konturuna denk gelince şerit düz çıkmıyor, kutu yine açık gri çiziliyordu (#1268): o zaman yalnız yazıdan biraz
        // uzaktaki üst ve alt şeride bakılır (Mac/iPhone, Windows ile aynı).
        val band = if (flat) null else sequenceOf({ ring }, { surrounding(frame, color, l, t, r, b, sides = false) })
            .mapNotNull { it() }
            .firstOrNull { deviation(it) < flatLimit }
        if (band != null) {
            groundHex = mean(band)
            shade = band.map { it.luma }.average()
        }
        if (contrast(groundHex, inkHex) < 3) inkHex = if (shade < 128) "#FFFFFF" else "#000000"
        val ratio = inkCount.toDouble() / (inkCount + groundCount)
        val longest = source.split('\n').maxOfOrNull { characters(it) } ?: 0
        val condensed = isCondensed((r - l).toDouble(), lineHeight, longest)
        return Style(
            TextSurface(groundHex, inkHex, flat),
            TextLook(bold = ratio >= BOLD_INK, condensed = condensed, align = align(edges), upper = isUpper(source)),
        )
    }

    /** Dar yazı ölçüsündeki harf sayısı: baştaki/sondaki boşluklar ve tuş simgesi imleri sayılmaz (Mac/Windows aynı). */
    fun characters(text: String): Int = text.filter { it != ButtonIcons.MARKER }.trim().length

    /**
     * Yazının yalnız harflerinin genişliği (piksel; kutunun ucundaki tuş simgesi çıkarılmış) ve satır yüksekliğiyle dar
     * yazı mı. Tuş çubuğunda simgesi kutuya katılan kısa etiketin ("SELECT ✕", "BACK ○") harf başına genişliği şişip
     * dar sayılmıyordu; Türkçesi geniş yazı tipinde çiziliyordu (#1360).
     */
    fun isCondensed(width: Double, height: Double, characters: Int): Boolean {
        if (characters <= 0 || height <= 0 || width <= 0) return false
        return width / characters / height < CONDENSED
    }

    /** Kutunun dışındaki şeridin kalınlığı: üstte ve altta yüksekliğin dörtte biri, yanlarda aynı genişlikte. */
    const val RING_SHARE = 0.25
    /** Çok olan küme kutunun kenar noktalarının en az bu kadarını dolduruyorsa (seçili satırın zemini) zemindir. */
    const val FILLED_EDGE = 0.7

    private class Pixel(val luma: Int, val r: Int, val g: Int, val b: Int, val edge: Boolean)

    /**
     * Dikdörtgenin 48 × 10 noktalık ızgarası (Mac/Windows ile aynı; noktalar hücre ortasında). Renk verilmezse gri ton.
     * Dikdörtgen 2 pikselden darsa nokta eklenmez.
     */
    private fun collect(frame: GrayFrame, color: ((Int, Int) -> Int)?, l: Int, t: Int, r: Int, b: Int, into: MutableList<Pixel>) {
        if (r - l < 2 || b - t < 2) return
        for (sy in 0 until SAMPLES_Y) {
            val y = minOf(frame.height - 1, (t + (sy + 0.5) * (b - t) / SAMPLES_Y).toInt())
            for (sx in 0 until SAMPLES_X) {
                val x = minOf(frame.width - 1, (l + (sx + 0.5) * (r - l) / SAMPLES_X).toInt())
                val luma = frame.at(x, y)
                val edge = sx == 0 || sy == 0 || sx == SAMPLES_X - 1 || sy == SAMPLES_Y - 1
                if (color == null) {
                    into.add(Pixel(luma, luma, luma, luma, edge))
                } else {
                    val rgb = color(x, y)
                    into.add(Pixel(luma, (rgb shr 16) and 0xff, (rgb shr 8) and 0xff, rgb and 0xff, edge))
                }
            }
        }
    }

    /**
     * Dikdörtgenin hemen dışındaki şeridin noktaları; kareden taşan parça atlanır, nokta azsa null. [sides] false ise
     * yalnız üst ve alt şerit, kutudan bir şerit boyu uzakta (taşan harf konturu girmesin).
     */
    private fun surrounding(
        frame: GrayFrame, color: ((Int, Int) -> Int)?, l: Int, t: Int, r: Int, b: Int, sides: Boolean = true,
    ): List<Pixel>? {
        val d = maxOf(1, ((b - t) * RING_SHARE).toInt())
        val away = if (sides) 0 else d
        val values = mutableListOf<Pixel>()
        fun strip(x0: Int, y0: Int, x1: Int, y1: Int) {
            if (x0 < 0 || y0 < 0 || x1 > frame.width || y1 > frame.height) return
            collect(frame, color, x0, y0, x1, y1, values)
        }
        strip(l, t - away - d, r, t - away)
        strip(l, b + away, r, b + away + d)
        if (sides) {
            strip(l - d, t, l, b)
            strip(r, t, r + d, b)
        }
        return if (values.size < 16) null else values
    }

    private fun mean(pixels: List<Pixel>): String {
        val n = pixels.size
        return String.format(Locale.ROOT, "#%02X%02X%02X", pixels.sumOf { it.r } / n, pixels.sumOf { it.g } / n, pixels.sumOf { it.b } / n)
    }

    /** Üç renk kanalının standart sapmasının ortalaması. */
    private fun deviation(pixels: List<Pixel>): Double {
        fun spread(channel: (Pixel) -> Int): Double {
            val average = pixels.sumOf { channel(it).toDouble() } / pixels.size
            return sqrt(pixels.sumOf { (channel(it) - average) * (channel(it) - average) } / pixels.size)
        }
        return (spread { it.r } + spread { it.g } + spread { it.b }) / 3
    }

    /** WCAG 2 kontrast oranı (1–21). */
    internal fun contrast(a: String, b: String): Double {
        fun luminance(hex: String): Double {
            val v = hex.removePrefix("#").toIntOrNull(16) ?: 0
            fun linear(c: Int): Double {
                val x = c / 255.0
                return if (x <= 0.03928) x / 12.92 else Math.pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear((v shr 16) and 0xff) + 0.7152 * linear((v shr 8) and 0xff) + 0.0722 * linear(v and 0xff)
        }
        val x = luminance(a)
        val y = luminance(b)
        return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
    }

    /** Otsu eşiği: iki kümenin arasındaki varyansı en büyük yapan parlaklık (bu değer ve altı koyu küme). */
    fun otsu(histogram: IntArray): Int {
        val total = histogram.sum().toDouble()
        if (total == 0.0) return 127
        var sum = 0.0
        for (i in 0..255) sum += i.toDouble() * histogram[i]
        var backSum = 0.0
        var backCount = 0.0
        var best = -1.0
        var threshold = 127
        for (i in 0..254) {
            backCount += histogram[i]
            if (backCount == 0.0) continue
            val foreCount = total - backCount
            if (foreCount == 0.0) break
            backSum += i.toDouble() * histogram[i]
            val backMean = backSum / backCount
            val foreMean = (sum - backSum) / foreCount
            val between = backCount * foreCount * (backMean - foreMean) * (backMean - foreMean)
            if (between > best) {
                best = between
                threshold = i
            }
        }
        return threshold
    }

    /** Harflerin en az %80'i büyükse özgün yazı BÜYÜK HARF sayılır. */
    fun isUpper(text: String): Boolean {
        val letters = text.filter { it.isLetter() }
        if (letters.length < 2) return false
        return letters.count { it.isUpperCase() } >= UPPER_SHARE * letters.length
    }

    /** Türkçe kurallarıyla büyük harf (i → İ, ı → I). */
    fun upper(text: String): String = text.uppercase(turkish)

    /** Satırların sol kenarları hizalıysa left, ortaları hizalıysa center, sağ kenarları hizalıysa right. */
    fun align(edges: List<Pair<Double, Double>>): String {
        if (edges.size < 2) return "left"
        val width = edges.maxOf { it.second } - edges.minOf { it.first }
        if (width <= 0) return "left"
        fun spread(values: List<Double>) = (values.max() - values.min()) / width
        val lefts = spread(edges.map { it.first })
        val centers = spread(edges.map { (it.first + it.second) / 2 })
        val rights = spread(edges.map { it.second })
        val tolerance = 0.04
        return when {
            lefts <= tolerance && lefts <= centers -> "left"
            centers <= tolerance && centers <= rights -> "center"
            rights <= tolerance -> "right"
            else -> listOf("left" to lefts, "center" to centers, "right" to rights).minBy { it.second }.first
        }
    }
}
