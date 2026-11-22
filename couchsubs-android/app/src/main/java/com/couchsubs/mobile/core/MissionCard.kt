// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * GTA 6 haritasında bir göreve ya da konuma basınca açılan bilgi kartı: BÜYÜK HARFLİ görev adı, altında (varsa) kısa
 * alt başlık satırları, bir iki cümlelik açıklama ve en altta kısa ayrıntı satırları (ödül, uzaklık). Kart yazıların
 * dizilişinden tanınır: başlığın hemen altında, aynı sol kenarda başlayan cümle satırları; kart ekranın bir parçası
 * kadar dardır, yardım kutularının durduğu sol üst köşede değildir ve (kare varsa) düz bir panelin üstündedir.
 *
 * Tanınan kartın parçaları ayrı ayrı çevrilir ve kendi yerlerinde, özgün stilde çizilir (başlık büyük harfle): başlık
 * açıklamanın ilk cümlesine katılmaz, uzun başlık da ayrı kalır. Otomatik ekran yazısında kart "Görev ve hedef yazısı"
 * türündendir ([ScreenTextKind.MISSION]), menüde açılsa da. Mac/iPhone (MissionCard.swift) ve Windows (MissionCard.cs)
 * aynı kuralları ve eşikleri uygular; ortak deneme dosyası fixtures/mission-card.json.
 */
object MissionCard {
    /** Başlık en çok bu kadar sözcük. */
    const val TITLE_WORDS = 7
    /** Açıklamanın ilk satırı başlığın altından en çok başlık yüksekliğinin bu katı aşağıda başlar. */
    const val TITLE_GAP = 1.4
    /** Açıklama satırları arasında en çok satır yüksekliğinin bu katı boşluk; paragraf arası [PARAGRAPH_GAP]. */
    const val LINE_GAP = 1.0
    const val PARAGRAPH_GAP = 2.2
    /** Ayrıntı satırları (ödül, uzaklık) açıklamanın altından en çok bu kat aşağıda ve en çok [DETAIL_WORDS] sözcük. */
    const val DETAIL_GAP = 1.8
    const val DETAIL_WORDS = 5
    /** Sol kenarların hizası, satır yüksekliğinin bu katı (kare 16:9 sayılır; yatayda ~1 harf). */
    const val ALIGNMENT = 0.9
    /** Kart ekranın en çok bu kadarı genişliğindedir (tam genişlik yazı kart değildir). */
    const val MAX_WIDTH = 0.55
    /** Açıklama en az bu kadar sözcük. */
    const val BODY_WORDS = 6
    /** Başlığın solundaki görev resmi en çok başlık yüksekliğinin bu katı genişliktedir; açıklama resmin altından başlar. */
    const val PICTURE_WIDTH = 2.5

    /** Bulunan kart: satırların sırası (verilen listede), yukarıdan aşağı. */
    data class Card(val title: List<Int>, val subtitles: List<Int>, val body: List<Int>, val details: List<Int>) {
        val all: List<Int> get() = title + subtitles + body + details
    }

    /**
     * Satırlardaki kartlar. [lines] kareye oranla yerleşmiş (kutusu olmayan satır atlanır); [place] verilirse kutular o
     * alana oranlıdır ve önce kareye taşınır.
     */
    fun find(lines: List<TextLine>, place: TextBox? = null): List<Card> {
        val boxes = lines.map { line -> line.box?.let { if (place != null) it.placedIn(place) else it } }
        val order = lines.indices.filter { boxes[it] != null }.sortedBy { boxes[it]!!.top }
        val used = mutableSetOf<Int>()
        val cards = mutableListOf<Card>()
        fun height(i: Int) = boxes[i]!!.bottom - boxes[i]!!.top
        fun aligned(i: Int, j: Int, h: Double) = abs(boxes[i]!!.left - boxes[j]!!.left) <= h * ALIGNMENT * 9 / 16
        for ((position, start) in order.withIndex()) {
            if (start in used || !isTitle(lines[start].text)) continue
            val title = mutableListOf(start)
            val subtitles = mutableListOf<Int>()
            val details = mutableListOf<Int>()
            // Kartın sütunu: başlığın sol kenarının tümüyle solunda biten ya da kart genişliğinden sağda başlayan satır
            // (haritada kartın yanındaki uzaklık "124 ft", simge kırıntısı, yan menü) karta ait değildir; kartın satırları
            // arasına girip kartı bölüyordu (X: chiaki, harita kartı tanınmıyor, çevirisi sola kayıyordu).
            fun inColumn(i: Int) = boxes[i]!!.right > boxes[start]!!.left && boxes[i]!!.left < boxes[start]!!.left + MAX_WIDTH
            val rest = ArrayDeque(order.drop(position + 1).filter { it !in used && inColumn(it) })
            // Açıklamanın ilk satırı: cümle satırı ya da sözcükleri cümle gibi yazılmış kısa satır ("Nautical-themed
            // souvenir") ki altında küçük harfle süren cümle satırı var; böyle satır alt başlık değildir.
            fun opensBody(i: Int, next: Int?): Boolean {
                if (isSentence(lines[i].text)) return true
                return sentenceCased(lines[i].text, 2) && next != null && aligned(next, i, height(i)) &&
                    lines[next].text.firstOrNull()?.isLowerCase() == true && isSentence(lines[next].text) &&
                    abs(height(next) - height(i)) <= height(i) * 0.3 && boxes[next]!!.top - boxes[i]!!.bottom <= height(i) * LINE_GAP
            }
            // Başlık iki satıra sarılmış olabilir.
            rest.firstOrNull()?.let { next ->
                if (isTitle(lines[next].text) && aligned(next, start, height(start)) &&
                    boxes[next]!!.top - boxes[start]!!.bottom <= height(start) * 0.6) {
                    title.add(next)
                    rest.removeFirst()
                }
            }
            var last = title.last()
            val titleHeight = height(start)
            while (true) {
                val next = rest.firstOrNull() ?: break
                if (opensBody(next, rest.getOrNull(1)) || words(lines[next].text) > DETAIL_WORDS || isTitle(lines[next].text) ||
                    !aligned(next, start, titleHeight) || boxes[next]!!.top - boxes[last]!!.bottom > titleHeight * TITLE_GAP) break
                subtitles.add(next)
                last = next
                rest.removeFirst()
            }
            // Başlığın solunda görev resmi (portre) olabilir: açıklama resmin altından, başlıktan daha solda başlar (#856).
            fun underTitle(i: Int) = aligned(i, start, titleHeight) || (boxes[i]!!.left < boxes[start]!!.left &&
                boxes[start]!!.left - boxes[i]!!.left <= titleHeight * PICTURE_WIDTH * 9 / 16)
            val first = rest.firstOrNull() ?: continue
            if (!opensBody(first, rest.getOrNull(1)) || !underTitle(first) ||
                boxes[first]!!.top - boxes[last]!!.bottom > titleHeight * TITLE_GAP || height(first) > titleHeight * 1.1) continue
            val line = height(first)
            val body = mutableListOf(first)
            last = first
            rest.removeFirst()
            while (true) {
                val next = rest.firstOrNull() ?: break
                // Alt satır cümlenin devamı: yazı boyu benzer; küçük harfle başlayan kısa son satır ("treasure.") harfleri
                // kısa diye daha alçak okunabilir. Sıradaki görevin BÜYÜK HARFLİ başlığı açıklamaya katılmaz (görev listesi).
                val continuation = lines[next].text.firstOrNull()?.isLowerCase() == true && height(next) <= line * 1.5 &&
                    !SubtitleStabilizer.endsSentence(lines[last].text.trim())
                if (!aligned(next, first, line) || isTitle(lines[next].text) ||
                    (abs(height(next) - line) > line * 0.3 && !continuation)) break
                val gap = boxes[next]!!.top - boxes[last]!!.bottom
                // Satır ya cümlenin devamı (dar boşluk) ya da yeni bir açıklama paragrafı: daha geniş boşluk, önceki satır
                // cümleyi bitirmiş ve yeni satır ayrıntı satırından uzun bir cümle ("Distance 2.4 mi" ayrıntıdır).
                val paragraph = gap <= line * PARAGRAPH_GAP && isSentence(lines[next].text) && words(lines[next].text) > 3 &&
                    SubtitleStabilizer.endsSentence(lines[last].text.trim())
                if (gap > line * LINE_GAP && !paragraph) break
                body.add(next)
                last = next
                rest.removeFirst()
            }
            val right = body.maxOf { boxes[it]!!.right }
            // Altında cümle olan BÜYÜK HARFLİ satır ayrıntı değil, sıradaki görevin başlığıdır.
            fun nextTitle(i: Int): Boolean {
                if (!isTitle(lines[i].text)) return false
                val after = order.firstOrNull { it != i && boxes[it]!!.top > boxes[i]!!.bottom - 1e-9 } ?: return false
                return isSentence(lines[after].text) && boxes[after]!!.top - boxes[i]!!.bottom <= height(i) * TITLE_GAP
            }
            while (true) {
                val next = rest.firstOrNull() ?: break
                if (nextTitle(next) || words(lines[next].text) > DETAIL_WORDS || height(next) > line * 1.3 ||
                    boxes[next]!!.top - boxes[last]!!.bottom > line * DETAIL_GAP ||
                    !(aligned(next, first, line) || abs(boxes[next]!!.right - right) <= line * ALIGNMENT * 9 / 16)) break
                details.add(next)
                last = next
                rest.removeFirst()
            }
            val card = Card(title, subtitles, body, details)
            val span = card.all.map { boxes[it]!! }
            if (body.sumOf { words(lines[it].text) } < BODY_WORDS || span.maxOf { it.right } - span.minOf { it.left } > MAX_WIDTH) continue
            used.addAll(card.all)
            cards.add(card)
        }
        return cards
    }

    /** Başlık: en az üç harf, harflerinin çoğu büyük, en çok [TITLE_WORDS] sözcük, nokta ile bitmez. */
    fun isTitle(text: String): Boolean {
        val plain = IconText.plain(text).trim()
        return plain.count { it.isLetter() } >= 3 && TextStyleSampler.isUpper(plain) && words(plain) in 1..TITLE_WORDS &&
            !plain.endsWith(".")
    }

    /**
     * Cümle satırı: en az üç sözcük, harflerinin en az %40'ı küçük ve ilkinden sonra küçük harfle başlayan bir sözcüğü
     * var (her sözcüğü büyük harfle başlayan "Lucia · Story Mission" alt başlıktır).
     */
    fun isSentence(text: String): Boolean = sentenceCased(text, 3)

    /** En az [words] sözcük, harflerin en az %40'ı küçük, ilkinden sonra küçük harfle başlayan sözcük var. */
    fun sentenceCased(text: String, words: Int): Boolean {
        val letters = text.filter { it.isLetter() }
        val parts = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return parts.size >= words && letters.isNotEmpty() && letters.count { it.isLowerCase() } >= 0.4 * letters.length &&
            parts.drop(1).any { it.first().isLowerCase() }
    }

    private fun words(text: String) = text.split(Regex("\\s+")).count { it.isNotEmpty() }

    /** Kartın kutusu yardım kutularının durduğu sol üst köşede mi (oradaki başlıklı kutu bir ipucudur, görev kartı değil). */
    fun inHelpCorner(box: TextBox): Boolean = box.left < 0.25 && box.top < 0.3

    /** Kart paneli düz zemin sayılırken izin verilen sapma, düz zemin eşiğinin bu katı. */
    const val PANEL_SLACK = 1.5

    /**
     * Kartın yazıları düz bir panelin üstünde mi (harita ya da oyun dünyasının dokulu zemininde duran yazı kart değildir).
     * Harita kartı yarı saydamdır: arkadaki harita zemini satırdan satıra biraz değiştirir, sıkıştırılmış görüntüde harf
     * kenarları da zemine karışır; kart bu yüzden düz zemin eşiğinin [PANEL_SLACK] katına kadar paneldir (X: chiaki,
     * harita kartı tanınmıyordu). Dokulu dünya zemini bu sınırın çok üstündedir.
     */
    fun onPanel(frame: GrayFrame, lines: List<TextLine>): Boolean {
        val boxes = lines.mapNotNull { it.box }
        if (boxes.isEmpty()) return false
        val box = boxes.reduce { a, b -> a.union(b) }
        val heights = boxes.map { it.bottom - it.top }.sorted()
        val style = TextStyleSampler.sample(
            frame, (box.left * frame.width).toInt(), (box.top * frame.height).toInt(),
            kotlin.math.ceil(box.right * frame.width).toInt(), kotlin.math.ceil(box.bottom * frame.height).toInt(),
            heights[heights.size / 2] * frame.height, lines.joinToString(" ") { it.text },
            boxes.map { it.left to it.right }, flatLimit = TextStyleSampler.FLAT_DEVIATION * PANEL_SLACK,
        ) ?: return false
        return style.surface.flat
    }

    /** Kartın çeviri grupları: başlık (sarılmışsa tek parça), alt başlıklar ve ayrıntılar tek tek, açıklama paragraflarıyla. */
    fun groups(card: Card, lines: List<TextLine>): List<ScreenTranslation.Group> {
        fun group(indices: List<Int>, joined: Boolean): ScreenTranslation.Group {
            val own = indices.map { lines[it] }
            val boxes = own.map { it.box!! }
            val heights = boxes.map { it.bottom - it.top }.sorted()
            val icons = ScreenText.paragraphIcons(own)
            val paragraphs = if (joined) listOf(own.joinToString(" ") { it.text.trim() }) else ScreenText.paragraphs(own)
            val slots = if (joined) listOf(icons.flatten()) else icons
            return ScreenTranslation.Group(paragraphs, boxes.reduce { a, b -> a.union(b) }, heights[heights.size / 2],
                if (slots.any { it.isNotEmpty() }) slots else null)
        }
        return listOf(group(card.title, true)) + card.subtitles.map { group(listOf(it), true) } +
            listOf(group(card.body, false)) + card.details.map { group(listOf(it), true) }
    }
}
