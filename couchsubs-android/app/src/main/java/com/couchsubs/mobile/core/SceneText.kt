// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale
import kotlin.math.abs

/**
 * Oyun dünyasındaki yazı (tabela, tişört, plaka, afiş) altyazı alanına düşse de altyazı değildir. Alt bölge karenin
 * üçte birinden büyüktür (yükseklikte %35, genişlikte %72); GTA 6'da yürüyen karakterin tişörtü ya da sokaktaki tabela
 * o alana girince altyazı bloğu seçiliyor, ekranda altyazı yokken tek başına çevriliyordu (X bildirimleri, beta.73).
 * Altyazı bloğu seçilirken ([Reading.subtitleBlock]) şu bloklar atılır; konuşan adı taşıyan blok hep altyazıdır:
 * - eğik satır (en az üç sözcük; perspektifli tabela: sözcüklerin dikey ortası satır boyunca tek yöne kayıyor ya da
 *   satır kutusu sözcük boyunun [TILTED_LINE_HEIGHT] katından yüksek),
 * - düşük güvenli kısa blok (en çok [LOW_CONFIDENCE_WORDS] sözcük, ortalama güven [LOW_CONFIDENCE]'tan az),
 * - karenin ortasındaki kısa, noktalamasız tek satır (en çok üç sözcük; altyazı ve görev satırı karenin alt ya da üst
 *   kenarına yakındır, [EDGE_BAND]).
 *
 * Gerçek altyazı asla atılmaz (GitHub #822): altyazısı alttaki %22'lik şeridin biraz üstünde duran oyunlarda kısa
 * altyazıların hepsi "ortadaki kısa satır" sayılıp atılıyordu. Altyazı biçimindeki blok (ortalanmış, alt şeritte, en az
 * iki sözcük) düşük güvenle de atılmaz; bu oturumda kesin altyazı okunan yükseklikteki blok ([SubtitleBand]) yalnız
 * eğikse atılır. Atılan bloğun nedeni altyazı günlüğüne yazılır ([reason]).
 * Mac/iPhone (SceneText.swift) ve Windows (SceneText.cs) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
 * fixtures/scene-text.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası).
 */
object SceneText {
    /** Sözcüklerin dikey ortası ilk sözcükten sonuncuya bu kadar sözcük boyu kayarsa satır eğiktir. */
    const val TILT_SHIFT = 0.6
    /** Satır kutusu sözcüklerin ortanca boyunun bu katından yüksekse satır eğiktir. */
    const val TILTED_LINE_HEIGHT = 1.8
    const val LOW_CONFIDENCE = 0.4
    const val LOW_CONFIDENCE_WORDS = 5
    /** Kısa ve noktalamasız tek satır en çok bu kadar sözcüktür. */
    const val SHORT_WORDS = 3
    /** Karenin alt ve üst kenarından bu kadarı (karenin yüksekliğine oranla) altyazı şerididir. */
    const val EDGE_BAND = 0.22
    /** Ortalanmış sayılmak için bloğun yatay ortasının karenin ortasından en çok uzaklığı. */
    const val CENTER_TOLERANCE = 0.12

    /** [block] bir sahne yazısı mı. Satır kutuları [area]'ya oranlıdır; [area] okunan alanın karedeki yeridir. */
    fun isSceneText(block: Reading, area: TextBox, band: SubtitleBand? = null): Boolean = reason(block, area, band) != null

    /** Blok sahne yazısıysa atılma nedeni (altyazı günlüğü için), değilse null. */
    fun reason(block: Reading, area: TextBox, band: SubtitleBand? = null): String? {
        val first = block.lines.firstOrNull() ?: return null
        if (SpeakerPrefix.split(first.text) != null || block.lines.any { it.box == null }) return null
        val box = block.box?.placedIn(area) ?: return null
        val words = wordCount(block.text)
        val middle = (box.top + box.bottom) / 2
        // Bu oturumda altyazının okunduğu yükseklik: yalnız eğik tabela atılır.
        val learned = band?.contains(box) == true
        // Altyazı biçimi: ortalanmış, karenin alt şeridinde, en az iki sözcük.
        val subtitleLike = isCentered(box) && middle >= 1 - EDGE_BAND && words >= 2
        if (block.lines.any { isTilted(it) } && !subtitleLike) return "eğik satır (tabela)"
        if (learned || subtitleLike) return null
        val confidences = block.lines.mapNotNull { it.confidence?.toDouble() }
        if (confidences.isNotEmpty() && confidences.average() < LOW_CONFIDENCE && words <= LOW_CONFIDENCE_WORDS) {
            return "düşük tanıma güveni (${String.format(Locale.ROOT, "%.2f", confidences.average())})"
        }
        if (block.lines.size == 1 && words <= SHORT_WORDS && !looksSpoken(first.text) && middle > EDGE_BAND && middle < 1 - EDGE_BAND) {
            return "karenin ortasında kısa satır"
        }
        return null
    }

    /** Sözcük yerleri biliniyorsa satır eğik mi (perspektifli tabela, yan duran tişört). Altyazı yatay yazılır. */
    internal fun isTilted(line: TextLine): Boolean {
        val words = line.words ?: return false
        val box = line.box ?: return false
        if (words.size < 3) return false
        val heights = words.map { it.box.bottom - it.box.top }.sorted()
        val median = heights[heights.size / 2]
        if (median <= 0) return false
        if (box.bottom - box.top > TILTED_LINE_HEIGHT * median) return true
        val middles = words.sortedBy { it.box.left }.map { (it.box.top + it.box.bottom) / 2 }
        val shift = middles.last() - middles.first()
        if (abs(shift) <= TILT_SHIFT * median) return false
        // Tek yöne kayma: aradaki sözcükler geri dönmez (yazı tanımanın kutu oynaması sözcük boyunun %15'i kadar).
        val direction = if (shift > 0) 1.0 else -1.0
        return middles.zipWithNext().all { (a, b) -> (b - a) * direction >= -0.15 * median }
    }

    internal fun isCentered(box: TextBox) = abs((box.left + box.right) / 2 - 0.5) <= CENTER_TOLERANCE

    /** Konuşma izi: cümle sonu noktalaması, virgül, noktalı virgül ya da tırnak. */
    internal fun looksSpoken(text: String) = SubtitleStabilizer.endsSentence(text) || text.any { it in ",;\"“”" }

    internal fun wordCount(text: String) = text.split(Regex("\\s+")).count { word -> word.any { it.isLetter() } }
}

/**
 * Bu oturumda kesin altyazı okunan yükseklikler (karenin yüksekliğine oranla). Altyazı her oyunda kendi yerinde durur;
 * orada okunan kısa satır ("Let's go") tabela sayılmaz ([SceneText.reason]). Kesin altyazı: ortalanmış, sahne yazısı
 * sayılmayan ve en az dört sözcüklü, konuşma noktalamalı ya da konuşan adlı blok. Hat sıfırlanınca unutulur (Mac ve
 * Windows: SubtitleBand).
 */
class SubtitleBand {
    private data class Span(val top: Double, val bottom: Double, val line: Double)

    private val spans = ArrayList<Span>()

    /** Kutunun (karede) dikey ortası hatırlanan bir altyazı yüksekliğine ([MARGIN] satır boyu payla) düşüyor mu. */
    fun contains(box: TextBox): Boolean {
        val middle = (box.top + box.bottom) / 2
        return spans.any { middle >= it.top - MARGIN * it.line && middle <= it.bottom + MARGIN * it.line }
    }

    /** Seçilen altyazı bloğu kesin altyazıysa yüksekliği hatırlanır. Satır kutuları [area]'ya oranlıdır. */
    fun record(block: Reading, area: TextBox) {
        val first = block.lines.firstOrNull() ?: return
        val box = block.box?.placedIn(area) ?: return
        if (!SceneText.isCentered(box)) return
        val sure = SpeakerPrefix.split(first.text) != null || SceneText.wordCount(block.text) >= SURE_WORDS ||
            block.lines.any { SceneText.looksSpoken(it.text) }
        if (!sure || SceneText.isSceneText(block, area)) return
        val line = (box.bottom - box.top) / block.lines.size
        spans.removeAll { abs(it.top - box.top) < line / 2 && abs(it.bottom - box.bottom) < line / 2 }
        spans.add(Span(box.top, box.bottom, line))
        while (spans.size > CAPACITY) spans.removeAt(0)
    }

    fun reset() = spans.clear()

    companion object {
        /** En çok bu kadar yükseklik hatırlanır (en eskisi düşer). */
        const val CAPACITY = 6
        /** Kesin altyazı sayılmak için en az sözcük (noktalaması ya da konuşan adı yoksa). */
        const val SURE_WORDS = 4
        /**
         * Hatırlanan yüksekliğin her yanındaki pay (satır boyuna oranla). GTA 6'da görev satırı ("Follow the plane")
         * altyazının hemen altında belirir; pencere kaynağında orta noktası bir satır payının hemen dışında kalıyordu
         * (Mac/Windows: aynı).
         */
        const val MARGIN = 1.5
    }
}
