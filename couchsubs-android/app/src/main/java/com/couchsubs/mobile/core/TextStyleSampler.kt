// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale
import kotlin.math.sqrt

/** Bloğun zemini ve yazı rengi (#RRGGBB); [flat]: zemin düz (çeviri kutusu tam opak doldurulur). */
data class TextSurface(val background: String, val foreground: String, val flat: Boolean = true)

/** Özgün yazının görünüşü: kalın, dar aile, hizalama ("left", "center", "right"), BÜYÜK HARF. */
data class TextLook(val bold: Boolean, val condensed: Boolean, val align: String, val upper: Boolean)

/**
 * Otomatik bulunan ekran yazısının stili (Google Lens tarzı yerinde çeviri için): blok kutusundaki pikseller parlaklığa
 * göre Otsu eşiğiyle ikiye ayrılır, az olan küme yazı, çok olan zemindir. Android'de çözücünün karesi yalnız parlaklık
 * düzlemidir; renkler bu yüzden gri tonudur (#LLLLLL). Windows ve Mac/iPhone aynı eşikleri uygular (TextStyleSampler).
 */
object TextStyleSampler {
    const val BOLD_INK = 0.28
    const val CONDENSED = 0.45
    const val UPPER_SHARE = 0.80
    const val FLAT_DEVIATION = 12.0
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
    ): Style? {
        val l = left.coerceIn(0, frame.width)
        val r = right.coerceIn(0, frame.width)
        val t = top.coerceIn(0, frame.height)
        val b = bottom.coerceIn(0, frame.height)
        if (r - l < 2 || b - t < 2 || !frame.isValid) return null
        val histogram = IntArray(256)
        for (y in t until b) for (x in l until r) histogram[frame.at(x, y)]++
        val threshold = otsu(histogram)
        var lowCount = 0L; var lowSum = 0L; var lowSquares = 0.0
        var highCount = 0L; var highSum = 0L; var highSquares = 0.0
        for (value in 0..255) {
            val count = histogram[value].toLong()
            if (count == 0L) continue
            if (value <= threshold) {
                lowCount += count; lowSum += count * value; lowSquares += count.toDouble() * value * value
            } else {
                highCount += count; highSum += count * value; highSquares += count.toDouble() * value * value
            }
        }
        if (lowCount == 0L || highCount == 0L) return null
        val textIsHigh = highCount <= lowCount
        val inkCount = if (textIsHigh) highCount else lowCount
        val groundCount = if (textIsHigh) lowCount else highCount
        val ink = (if (textIsHigh) highSum else lowSum).toDouble() / inkCount
        val ground = (if (textIsHigh) lowSum else highSum).toDouble() / groundCount
        val groundSquares = if (textIsHigh) lowSquares else highSquares
        val deviation = sqrt(maxOf(0.0, groundSquares / groundCount - ground * ground))
        // Renkli kare: kümeler parlaklıkla ayrılır, renkleri kümedeki piksellerin ortalamasıdır (iPhone ile aynı).
        var inkHex = hex(ink)
        var groundHex = hex(ground)
        if (color != null) {
            val inkSum = LongArray(3)
            val groundSum = LongArray(3)
            for (y in t until b) for (x in l until r) {
                val rgb = color(x, y)
                val isHigh = frame.at(x, y) > threshold
                val sum = if (isHigh == textIsHigh) inkSum else groundSum
                sum[0] += (rgb shr 16) and 0xff
                sum[1] += (rgb shr 8) and 0xff
                sum[2] += rgb and 0xff
            }
            inkHex = rgbHex(inkSum, inkCount)
            groundHex = rgbHex(groundSum, groundCount)
        }
        val ratio = inkCount.toDouble() / (inkCount + groundCount)
        val longest = source.split('\n').maxOfOrNull { it.trim().length } ?: 0
        val condensed = longest > 0 && lineHeight > 0 && (r - l).toDouble() / longest / lineHeight < CONDENSED
        return Style(
            TextSurface(groundHex, inkHex, deviation < FLAT_DEVIATION),
            TextLook(bold = ratio >= BOLD_INK, condensed = condensed, align = align(edges), upper = isUpper(source)),
        )
    }

    /** Otsu eşiği: iki kümenin arasındaki varyansı en büyük yapan parlaklık (bu değer ve altı koyu küme). */
    fun otsu(histogram: IntArray): Int {
        val total = histogram.sum().toDouble()
        if (total == 0.0) return 127
        var sum = 0.0
        for (i in 0..255) sum += i.toDouble() * histogram[i]
        var backSum = 0.0
        var backCount = 0.0
        var best = 0.0
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

    private fun rgbHex(sum: LongArray, count: Long): String {
        if (count <= 0) return "#000000"
        return String.format(Locale.ROOT, "#%02X%02X%02X", (sum[0] / count).toInt(), (sum[1] / count).toInt(), (sum[2] / count).toInt())
    }

    private fun hex(luma: Double): String {
        val v = luma.toInt().coerceIn(0, 255)
        return String.format(Locale.ROOT, "#%02X%02X%02X", v, v, v)
    }
}
