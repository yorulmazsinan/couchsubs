// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * GTA 6 telefonunun sohbet dışı ekranları (sosyal akış gönderisi, haber listesi ve makale, hava, fitness, ayarlar,
 * eklenti sayfası). Sinan Bey (beta.100, 3416–3425): bu ekranların Türkçesi ya telefonun üstüne kutularla yazılıyor ya da
 * sohbet balonu sanılıp dev balonlarla çiziliyordu; gönderinin açıklaması üç balona bölünüyor, yer adı ve kaynak adı
 * çevriliyordu. Artık ekranın türü çıkarılır ([kind]) ve sohbet dışı ekranın yazıları telefondaki yapının Türkçe kopyası
 * olarak kartlara ayrılır ([cards]): her satır kartı, makale başlığı ya da gövdesi, gönderinin açıklaması tek kart; kartlar
 * telefonun yanındaki panelde, mesaj listesi kartlarıyla aynı görünüşte ([ScreenPhoneCard.Role.CARD]). Çevrilmeyenler:
 * kullanıcı adı (@…), saat ("7PM"), geri düğmesi, gönderinin konum satırı ve fotoğrafın içindeki yazı, haberin kaynak
 * adı. Mac/iPhone (PhoneScreen.swift) ve Windows (PhoneScreen.cs) ile aynı kurallar ve eşikler; ortak deneme dosyası
 * fixtures/phone-screens.json.
 */
object PhoneScreen {
    enum class Kind(val wire: String) {
        /** Sohbet (balonlar) ya da tanınmayan ekran: eski kurallar. */
        CHAT("chat"),
        /** Uygulama ekranı (haber, makale, hava, fitness, ayarlar, eklenti): satırlar kart. */
        APP("app"),
        /** Sosyal akış gönderisi: kullanıcı adının altındaki açıklama tek kart, gerisi çevrilmez. */
        POST("post"),
    }

    /** Ekrandaki bir satır: yazısı ve düz ekrandaki yeri (0–1). */
    data class Line(val text: String, val spot: TextBox) {
        val height: Double get() = spot.bottom - spot.top
        val words: Int get() = words(text).size
    }

    /** Satırın kartı ([TextLine.phoneCard]). */
    data class Mark(val card: Int, val title: Boolean = false, val bold: Boolean = false)

    /**
     * Bir kart: satırlarının sırası ([cards]'a verilen satırlar içindeki yerleri, yukarıdan aşağı) ve başlığı. [titled]:
     * ilk satır kartın kalın başlığı ("Strength Workout" / "Level 3/4"); [bold]: kartın tamamı başlık (makale başlığı).
     */
    data class Card(val lines: List<Int>, val titled: Boolean = false, val bold: Boolean = false)

    /**
     * Uygulama ekranı için en az bu kadar kısa satır (en çok [SHORT_WORDS] sözcük, cümle sonu yok) ve satırların en az
     * [SHORT_SHARE]'i kısa olmalı (sohbette mesajlar cümledir).
     */
    const val SHORT_ROWS = 3
    const val SHORT_WORDS = 3
    const val SHORT_SHARE = 0.5
    /** "…" ile kesilmiş en az bu kadar satır (haber listesi): uygulama ekranı. */
    const val CUT_ROWS = 2
    /**
     * Karttaki iki satır arasındaki boşluk satır yüksekliğinin bu kadarından azsa aynı karttır; sol kenarlar [LEFT_ALIGN]
     * içinde hizalı ve yükseklikler en çok [HEIGHT_RATIO] katı farklı olmalı.
     */
    const val ROW_GAP = 0.7
    const val LEFT_ALIGN = 0.06
    const val HEIGHT_RATIO = 1.35
    /** Kartın satır yüksekliği sayfanın ortancasının bu katından büyükse kart başlıktır (makale başlığı, kalın). */
    const val TITLE_HEIGHT = 1.25
    /** Gönderinin açıklaması kullanıcı adının en çok bu kadar satır altında başlar; açıklama satırları arası [ROW_GAP]. */
    const val CAPTION_GAP = 1.6
    /** Açıklama satırları kullanıcı adının (ya da ilk açıklama satırının) sol kenarına bu kadar hizalı. */
    const val CAPTION_ALIGN = 0.12

    private val TIME = Regex("^\\d{1,2}(?::\\d{2})?\\s?(?:[AaPp]\\.?\\s?[Mm]\\.?|ᴬᴹ|ᴾᴹ)$")

    /** Boşluklardan bölünmüş sözcükler (boşlar atılır). */
    private fun words(text: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        for (c in text) {
            if (c.isWhitespace()) {
                if (current.isNotEmpty()) result.add(current.toString())
                current.setLength(0)
            } else {
                current.append(c)
            }
        }
        if (current.isNotEmpty()) result.add(current.toString())
        return result
    }

    /** Saat ("7PM", "10 PM", "6:15PM"): çevrilmez. */
    fun isTime(text: String): Boolean = TIME.matches(text.trim())

    /** Geri düğmesi ("< Back", "‹ Back"). */
    fun isBack(text: String): Boolean = text.dropWhile { !it.isLetter() }.trim().lowercase() == "back"

    /** Yalnız kullanıcı adı ya da etiket ("@offthehook_magazine", "@Cal_zone ✓"). */
    fun isHandle(text: String): Boolean {
        val words = words(text)
        return words.any { it.first() == '@' && it.length >= 3 } &&
            words.all { word -> word.first() == '@' || word.none { it.isLetterOrDigit() } }
    }

    /** Çevrilecek yazı mı: en az iki harf, saat, geri düğmesi ve kullanıcı adı değil. */
    fun isWords(text: String): Boolean =
        text.count { it.isLetter() } >= 2 && !isTime(text) && !isBack(text) && !isHandle(text)

    fun endsSentence(text: String): Boolean = text.trim().lastOrNull()?.let { it in ".!?" } ?: false

    fun isCut(text: String): Boolean = GamePhoneText.isCut(text)

    /** Kısa satır: en çok [SHORT_WORDS] sözcük, cümle sonu ve "…" yok ("Wallpaper", "Cardio Workout", "Level 1/4"). */
    fun isShort(text: String): Boolean {
        val count = words(text).size
        return count in 1..SHORT_WORDS && !endsSentence(text) && !isCut(text)
    }

    /**
     * Ad gibi (kaynak adı, yer adı): bir-üç sözcük, her biri büyük harfle başlar, rakam ve cümle sonu yok
     * ("Vice City Horn", "Weazel News", "Okchiloha Bay").
     */
    fun isName(text: String): Boolean {
        val words = words(text)
        if (words.size !in 1..3 || endsSentence(text) || isCut(text) || text.any { it.isDigit() }) return false
        return words.all { word -> word.first().isUpperCase() && word.all { it.isLetter() || it in "-'&." } }
    }

    /**
     * Ekranın türü. [lines]: telefondaki bütün satırlar (kullanıcı adları ve harfsiz satırlar da). Sohbet listesi ve ana
     * ekran önce ayrılır ([GamePhoneText.forTranslation], [PhoneChat.isHome]); burada yalnız sohbet / uygulama / gönderi.
     * - Gönderi: sol yarıda bir kullanıcı adı satırı ("@THE_DONDIDDLER") ve altında yazı.
     * - Uygulama: üstte geri düğmesi (makale), "…" ile kesilmiş en az [CUT_ROWS] satır (haber listesi) ya da en az
     *   [SHORT_ROWS] kısa satır ve satırların en az [SHORT_SHARE]'i kısa, sağa yaslı (giden mesaj) balon yok.
     * - Değilse sohbet.
     */
    fun kind(lines: List<Line>): Kind {
        val words = lines.filter { isWords(it.text) }
        if (lines.any { line ->
                isHandle(line.text) && line.spot.left < 0.5 && words.any { it.spot.top >= line.spot.top + line.height * 0.5 }
            }) return Kind.POST
        if (lines.any { isBack(it.text) && (it.spot.top + it.spot.bottom) / 2 < 0.15 }) return Kind.APP
        if (words.isEmpty()) return Kind.CHAT
        if (words.count { isCut(it.text) } >= CUT_ROWS) return Kind.APP
        val short = labels(words)
        // Sağa yaslı, iki yanı da dolu olmayan çok sözcüklü satır: oyuncunun mesajı (sohbet).
        val outgoing = words.any { line ->
            val left = maxOf(0.0, line.spot.left)
            val right = maxOf(0.0, 1 - line.spot.right)
            line.words >= 2 && left >= 0.2 && right < left * PhoneChat.SIDE_RATIO
        }
        if (short >= SHORT_ROWS && short.toDouble() >= words.size * SHORT_SHARE && !outgoing) return Kind.APP
        return Kind.CHAT
    }

    /**
     * Kısa etiket satırlarının sayısı ([isShort]): alt satıra sarılmış cümlenin parçası sayılmaz. Satır, hemen altındaki
     * hizalı satır küçük harfle başlıyorsa (cümle sürüyor: "Dropped that stuff" / "off for you") ya da kendisi küçük
     * harfle başlıyorsa ya da hemen üstündeki hizalı satır uzun bir cümle parçasıysa ("anything else AND I" / "MEAN
     * ANYTHING u") etiket değildir.
     */
    fun labels(words: List<Line>): Int {
        val sorted = words.sortedBy { it.spot.top }
        fun joined(a: Line, b: Line): Boolean =
            b.spot.top - a.spot.bottom <= ROW_GAP * maxOf(a.height, b.height) && abs(a.spot.left - b.spot.left) <= LEFT_ALIGN
        fun lower(line: Line): Boolean = line.text.firstOrNull { it.isLetter() }?.isLowerCase() == true
        return sorted.indices.count { index ->
            val line = sorted[index]
            if (!isShort(line.text) || lower(line)) return@count false
            if (index + 1 < sorted.size && joined(line, sorted[index + 1]) && lower(sorted[index + 1])) return@count false
            if (index > 0 && joined(sorted[index - 1], line) && sorted[index - 1].words > SHORT_WORDS &&
                !endsSentence(sorted[index - 1].text)) return@count false
            true
        }
    }

    /** Sohbet dışı ekranın kartları (yukarıdan aşağı). Çevrilmeyen satırlar hiçbir karta girmez. */
    fun cards(lines: List<Line>, kind: Kind): List<Card> {
        val order = lines.indices.sortedBy { lines[it].spot.top }
        val heights = order.filter { isWords(lines[it].text) }.map { lines[it].height }.sorted()
        if (heights.isEmpty()) return emptyList()
        val median = heights[(heights.size - 1) / 2]
        return when (kind) {
            Kind.CHAT -> emptyList()
            Kind.POST -> captions(lines, order, median)
            Kind.APP -> appCards(lines, order, median)
        }
    }

    /**
     * Gönderinin açıklaması: her kullanıcı adının altında, ona hizalı ve aralıksız satırlar tek kart. Fotoğrafın içindeki
     * yazı, beğeni/yorum sayısı, konum satırı ("Okchiloha Bay") ve öbür satırlar çevrilmez.
     */
    private fun captions(lines: List<Line>, order: List<Int>, median: Double): List<Card> {
        val cards = mutableListOf<Card>()
        for (handle in order) {
            if (!isHandle(lines[handle].text)) continue
            val head = lines[handle]
            val taken = mutableListOf<Int>()
            var last = head
            for (index in order) {
                if (!isWords(lines[index].text)) continue
                val line = lines[index]
                if (line.spot.top < head.spot.top + head.height * 0.5) continue
                val gap = line.spot.top - last.spot.bottom
                val limit = (if (taken.isEmpty()) CAPTION_GAP else ROW_GAP) * maxOf(median, last.height)
                val anchor = if (taken.isEmpty()) head.spot.left else lines[taken[0]].spot.left
                if (gap > limit || abs(line.spot.left - anchor) > CAPTION_ALIGN) {
                    // Aynı satırda yan yana okunan parça (emoji satırı böler) ya da aynı satırın ikinci okunuşu.
                    val first = taken.lastOrNull()
                    if (first != null && sameBand(lines[first], line)) {
                        taken.add(index)
                        continue
                    }
                    break
                }
                taken.add(index)
                last = line
            }
            if (taken.isNotEmpty()) cards.add(Card(withoutRepeats(taken, lines)))
        }
        return cards
    }

    /**
     * Uygulama ekranının kartları: arada dar boşluk, solda hizalı ve aynı boyda satırlar bir kart. Kartın ilk satırı kısa
     * bir başlıksa ve alttaki satır yeni bir cümleyle başlıyorsa başlıktır ("Strength Workout" / "Level 3/4"); satırları
     * sayfadan belirgin büyük kart başlıktır (makale başlığı). "…" ile kesilmiş başlığın ya da cümlenin altındaki ad satırı
     * haberin kaynağıdır ("Vice City Horn"): çevrilmez.
     */
    private fun appCards(lines: List<Line>, order: List<Int>, median: Double): List<Card> {
        val blocks = mutableListOf<MutableList<Int>>()
        for (index in order) {
            if (!isWords(lines[index].text)) continue
            val line = lines[index]
            val block = blocks.lastOrNull()
            val lastIndex = block?.lastOrNull()
            if (block != null && lastIndex != null) {
                val last = lines[lastIndex]
                val first = lines[block[0]]
                if (sameBand(last, line)) {
                    block.add(index)
                    continue
                }
                val gap = line.spot.top - last.spot.bottom
                val ratio = maxOf(line.height, last.height) / maxOf(1e-6, minOf(line.height, last.height))
                // Kesik başlığın hemen altındaki satır (kaynak adı, simgesiyle biraz içeride) hizasız da aynı karttır.
                val aligned = abs(line.spot.left - first.spot.left) <= LEFT_ALIGN || isCut(last.text)
                if (gap <= ROW_GAP * maxOf(line.height, last.height) && aligned && ratio <= HEIGHT_RATIO) {
                    block.add(index)
                    continue
                }
            }
            blocks.add(mutableListOf(index))
        }
        return blocks.mapNotNull { block ->
            val rows = withoutRepeats(block, lines).toMutableList()
            // Haberin kaynağı: kesik başlığın ya da cümlenin altındaki ad satırı.
            if (rows.size >= 2 && isName(lines[rows.last()].text) &&
                rows.dropLast(1).any { isCut(lines[it].text) || endsSentence(lines[it].text) || lines[it].words > SHORT_WORDS }) {
                rows.removeAt(rows.size - 1)
            }
            if (rows.isEmpty()) return@mapNotNull null
            val tall = rows.map { lines[it].height }.sorted()[(rows.size - 1) / 2] >= median * TITLE_HEIGHT
            if (tall) return@mapNotNull Card(rows, bold = true)
            val next = if (rows.size >= 2) lines[rows[1]].text.firstOrNull { it.isLetterOrDigit() } else null
            if (next != null && isShort(lines[rows[0]].text) && (next.isUpperCase() || next.isDigit()) &&
                !sameBand(lines[rows[0]], lines[rows[1]])) {
                return@mapNotNull Card(rows, titled = true)
            }
            Card(rows)
        }
    }

    /**
     * Kartın çevrilecek paragrafları: başlıklı kartta başlık ve gövde, değilse tek paragraf. Satırlar birleşir; satır
     * sonunda tireyle bölünmüş sözcük boşluksuz.
     */
    fun paragraphs(card: Card, lines: List<Line>): List<String> {
        fun joined(part: List<Int>): String {
            var text = ""
            for (index in part) {
                val piece = lines[index].text.trim()
                text = if (text.isEmpty()) piece else if (text.endsWith("-")) text + piece else "$text $piece"
            }
            return text
        }
        if (card.lines.isEmpty()) return emptyList()
        return if (card.titled && card.lines.size >= 2) listOf(joined(card.lines.take(1)), joined(card.lines.drop(1)))
        else listOf(joined(card.lines))
    }

    /** İki satır aynı yükseklikte (dikeyde en az yarı yarıya üst üste). */
    fun sameBand(a: Line, b: Line): Boolean =
        minOf(a.spot.bottom, b.spot.bottom) - maxOf(a.spot.top, b.spot.top) >= minOf(a.height, b.height) * 0.5

    /**
     * Aynı satırın ikinci okunuşu ya da başka bir satırın içinde kalan parçası atılır (Sinan Bey, 3419: "Pick up OFF
     * THE HOOK" ayrı balon olarak da çiziliyordu). Uzun olan kalır.
     */
    fun withoutRepeats(rows: List<Int>, lines: List<Line>): List<Int> {
        fun key(text: String): String {
            var value = text.trim()
            while (value.isNotEmpty() && (value.last() == '.' || value.last() == '…')) value = value.dropLast(1)
            return TextMatch.normalize(value)
        }
        return rows.filter { index ->
            val mine = key(lines[index].text)
            if (mine.count { it.isLetter() } < 4) return@filter true
            rows.none { other ->
                if (other == index) return@none false
                val theirs = key(lines[other].text)
                if (theirs.length < mine.length) return@none false
                // Eşit uzunlukta aynı yazı: önce okunan kalır.
                if (theirs == mine) other < index else theirs.contains(mine)
            }
        }
    }
}
