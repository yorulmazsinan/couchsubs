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
 *   kenarına yakındır, [EDGE_BAND]),
 * - plaka/tabela: alt alta kısa, büyük harfli satırlar ([isSign]) ve harfsiz sayı ([isNumber]); altyazının yerinde de.
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

    /**
     * Blok sahne yazısıysa atılma nedeni (altyazı günlüğü için), değilse null. [darkInk]: satır kutusu (okunan alanın
     * görüntüsüne oranla) açık zeminde koyu yazı mı ([InkTone.sampler]); verilmezse renge bakılmaz.
     */
    fun reason(block: Reading, area: TextBox, band: SubtitleBand? = null, darkInk: ((TextBox) -> Boolean)? = null): String? {
        val first = block.lines.firstOrNull() ?: return null
        if (SpeakerPrefix.split(first.text) != null || block.lines.any { it.box == null }) return null
        val box = block.box?.placedIn(area) ?: return null
        // Kâğıt ilan altyazının yerinde de atılır (GitHub #1124).
        if (darkInk != null && InkTone.isDarkBlock(block, darkInk)) return InkTone.REASON
        val words = wordCount(block.text)
        val middle = (box.top + box.bottom) / 2
        // Plaka ve tabela altyazının yerinde de atılır (GitHub #1052).
        if (isSign(block)) return SIGN_REASON
        if (isNumber(block.text)) return NUMBER_REASON
        // Plaka numarası ("HV85.", "BN25 32."; #1411) altyazının yerinde de atılır.
        if (isPlateNumber(block.text)) return PLATE_NUMBER_REASON
        // Bu oturumda altyazının okunduğu yükseklik: yalnız eğik tabela ve tuş simgeli menü eylemi atılır.
        val learned = band?.contains(box) == true
        // Silah çarkı, mağaza ve menü satırı (GitHub #1285, #1293); rakamlı büyük harfli ad yalnız altyazının yüksekliği
        // dışında (beta.103 kaçan altyazı).
        if (isMenuItem(block, learned)) return MENU_ITEM_REASON
        // Altyazı biçimi: ortalanmış, karenin alt şeridinde, en az iki sözcük.
        val subtitleLike = isCentered(box) && middle >= 1 - EDGE_BAND && words >= 2
        if (block.lines.any { isTilted(it) } && !subtitleLike) return TILTED_REASON
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

    /**
     * Plaka ya da tabela: en az iki satır ve her satır [isSignLine]; noktalama yalnız son satırın sonunda ve o satır tek
     * sözcükse olabilir (yazı tanıma plakanın kenarını "." ya da "!" okuyor: "AKB / GLORIANA.", "AK8 / FLORIA!").
     * Kullanıcı bildirimi (GitHub #1052, GTA 6, beta.84): plaka iki-üç satır okunduğu için tek satır kuralına takılmıyor,
     * altyazının yerinde durduğu için de ([SubtitleBand]) çevriliyordu ("AKB / FLORIANA", "DISCOVER 28 / AKB /
     * GLORIANA."). Altyazı satırı en çok üç sözcükken sarılmaz; kısa bağırma replikleri ("NO! / GET DOWN!") ilk satırda
     * noktalama taşıdığı için kalır, konuşan adlı blok hep altyazıdır (Mac: SceneText.isSign, Windows: SceneText.IsSign).
     */
    internal fun isSign(block: Reading): Boolean {
        if (block.lines.size < 2 || !block.lines.all { isSignLine(it.text) }) return false
        if (block.lines.dropLast(1).any { looksSpoken(it.text) }) return false
        val last = block.lines.last().text
        return !looksSpoken(last) || wordCount(last) <= 1
    }

    /**
     * Plaka/tabela satırı: kısa (en çok [SIGN_LINE_LENGTH] karakter ve en çok [SHORT_WORDS] sözcük), küçük harfsiz, en az
     * bir büyük harf; soru işareti, tire ile başlayan karşılıklı konuşma ve konuşan adı yok. Büyük/küçük harfi olmayan
     * yazıya (Japonca) dokunulmaz.
     */
    internal fun isSignLine(text: String): Boolean {
        val line = text.trim()
        if (line.isEmpty() || line.length > SIGN_LINE_LENGTH || !line.any { it.isUpperCase() } || line.any { it.isLowerCase() }) return false
        if ('?' in line || line[0] in "-–—" || SpeakerPrefix.split(line) != null) return false
        return wordCount(line) <= SHORT_WORDS
    }

    /** Plaka/tabela satırının en çok karakteri ("C118 DISCOVER 76"). */
    const val SIGN_LINE_LENGTH = 20

    internal const val MENU_ITEM_REASON = "menü/mağaza satırı (tuş simgeli eylem ya da rakamlı büyük harfli ad)"
    internal const val SIGN_REASON = "plaka/tabela (kısa büyük harfli satırlar)"
    internal const val NUMBER_REASON = "harfsiz sayı"
    internal const val PLATE_NUMBER_REASON = "plaka numarası (harfli rakamlı kısa yazı)"
    internal const val TILTED_REASON = "eğik satır (tabela)"

    /**
     * Silah çarkı, mağaza ve menü satırı (GitHub #1285, #1293; GTA 6, ekran yazısı çevirisi kapalıyken): altyazı alanına
     * düşen "srow LONGARMS O TAKE AMMO", "SHOW SHIRT (1/3) A BUY O BU", "IN LJ TYPE 9 SMG" konuşma sanılıp bozuk
     * çevriliyordu. Hiçbir satırı konuşma izi ([looksSpoken]) taşımayan blokta: tuş simgesinin okunuşunun ("O", "X", "A",
     * "•", simge) hemen ardından menü eylemi ([MENU_ACTIONS]) ya da küçük harfsiz, en az bir sözcüklü ve rakamlı yazı
     * (ürün/silah adı, fiyat). Konuşan adlı blok ve noktalamalı bağırma altyazı kalır (Mac: SceneText.isMenuItem,
     * Windows: SceneText.IsMenuItem). Rakamlı büyük harfli yazı yalnız kanıtla atılır (beta.103, iki kullanıcı: "bazı
     * altyazıları kaçırıyor"): bu oturumda altyazının okunduğu yükseklikteyse ([learned]) ya da kişi zamiri taşıyorsa
     * ("I NEED 50 GRAND") noktalamasız bağırma altyazıdır. Tuş simgesi + menü eylemi her yerde atılır.
     */
    internal fun isMenuItem(block: Reading, learned: Boolean = false): Boolean {
        if (block.lines.any { looksSpoken(it.text) }) return false
        val tokens = block.lines.flatMap { line -> line.text.split(Regex("\\s+")).filter { it.isNotEmpty() } }
        if (tokens.zipWithNext().any { (a, b) -> isGlyph(a) && b in MENU_ACTIONS }) return true
        if (learned || tokens.any { it.replace('\u2019', '\'') in PRONOUNS }) return false
        val text = block.text
        return text.any { it.isUpperCase() } && text.none { it.isLowerCase() } && tokens.any { token -> token.any { it.isDigit() } } &&
            tokens.any { token -> token.count { it.isLetter() } >= 2 }
    }

    /** Menünün tuş eylemleri ("△ BUY", "○ TAKE AMMO", "□ ADD TO TRUNK"); büyük harfle yazılır. */
    internal val MENU_ACTIONS = setOf("BUY", "SELL", "TAKE", "EQUIP", "ADD", "REMOVE", "RENAME", "DELETE", "CUSTOMIZE", "PREVIEW", "PURCHASE")

    /**
     * Tuş simgesinin yazı tanımadaki okunuşu: "O" (○), "X" (✕), "A" (△) ya da harf ve rakam olmayan tek karakter
     * ("•", "□", [ButtonIcons.MARKER]).
     */
    internal fun isGlyph(token: String): Boolean {
        if (token == "O" || token == "X" || token == "A") return true
        return token.codePointCount(0, token.length) == 1 && token.none { it.isLetterOrDigit() || it in "-–—" }
    }

    /** Büyük harfli konuşmanın kişi zamirleri: ürün, silah ve menü adında geçmez ([isMenuItem]). */
    internal val PRONOUNS = setOf(
        "I", "I'M", "I'LL", "I'VE", "I'D", "ME", "MY", "YOU", "YOU'RE", "YOUR", "WE", "WE'RE", "US", "OUR",
        "HE", "SHE", "HIM", "HER", "THEY", "THEM",
    )

    /** Harfsiz sayı ("82403610."): plaka numarası, sayaç; altyazı değildir. */
    internal fun isNumber(text: String) = !text.any { it.isLetter() } && text.any { it.isDigit() }

    /**
     * Plaka numarası: en çok [PLATE_TOKENS] parça, harfleri yalnız büyük Latin harfi (A–Z) ve en az bir parçada hem harf
     * hem rakam ("HV85.", "EN25.", "BN25 32.", "A80 3."). Kullanıcı bildirimi (#1411, GTA 6, Mac, beta-105): arabanın
     * plakası altyazı alanına girince numarası tek satır okunuyor, noktalı okunduğu için konuşma sanılıp çevriliyordu.
     * Küçük harfli satır ("855, on scene now."), dört ve daha çok parçalı bağırma ("I NEED 50 GRAND") ve Latin dışı yazı
     * (Japonca "あと3分だ") altyazı kalır (Mac: SceneText.isPlateNumber, Windows: SceneText.IsPlateNumber).
     */
    internal fun isPlateNumber(text: String): Boolean {
        val tokens = text.trim().split(Regex("\\s+")).map { token -> token.filter { it.isLetterOrDigit() } }.filter { it.isNotEmpty() }
        if (tokens.isEmpty() || tokens.size > PLATE_TOKENS) return false
        if (!tokens.all { token -> token.all { it in 'A'..'Z' || it in '0'..'9' } }) return false
        return tokens.any { token -> token.any { it in 'A'..'Z' } && token.any { it in '0'..'9' } }
    }

    /** Plaka numarasının en çok parçası ([isPlateNumber]). */
    internal const val PLATE_TOKENS = 3

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
    private data class Span(val top: Double, val bottom: Double, val line: Double, val texts: List<String>)

    private val spans = ArrayList<Span>()

    /** Bu oturumda hiç altyazı yüksekliği öğrenilmedi. */
    val isEmpty: Boolean get() = spans.isEmpty()

    /** Kutunun (karede) dikey ortası hatırlanan bir altyazı yüksekliğine ([MARGIN] satır boyu payla) düşüyor mu. */
    fun contains(box: TextBox): Boolean {
        val middle = (box.top + box.bottom) / 2
        return spans.any { middle >= it.top - MARGIN * it.line && middle <= it.bottom + MARGIN * it.line }
    }

    /**
     * Kutunun tamamı (üstü ve altı) oyunun konuşma altyazısının okunduğu tek bir yüksekliğin içinde mi ([MARGIN] satır boyu
     * payla; [SceneTextMemory.filter]). Yalnız konuşma izi taşıyan (konuşan adı ya da konuşma noktalaması,
     * [SceneText.looksSpoken]) bloktan öğrenilen yükseklik sayılır: noktalamasız dört sözcük ("A LIBERTY CITY MEMOIR")
     * altyazı sanılıp öğrenilebiliyor. Satırlarından biri [sceneText] olan yükseklik de sayılmaz (altyazı sanılıp
     * öğrenilen telefon/tabela yazısı). Mac/Windows aynı.
     */
    fun holds(box: TextBox, sceneText: ((String) -> Boolean)? = null): Boolean = spans.any { span ->
        box.top >= span.top - MARGIN * span.line && box.bottom <= span.bottom + MARGIN * span.line &&
            span.texts.any { SpeakerPrefix.split(it) != null || SceneText.looksSpoken(it) } &&
            (sceneText == null || span.texts.none(sceneText))
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
        spans.add(Span(box.top, box.bottom, line, block.lines.map { it.text }))
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
