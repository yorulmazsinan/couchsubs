// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.CRC32
import java.util.zip.Deflater
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

/**
 * Kumanda simgesinin kesileceği gri kare: parlaklık (Y) düzlemi, satır başına [stride] bayt. Okuma hattı yalnız
 * parlaklığı kopyalar ([com.couchsubs.mobile.ocr.RegionPixels]; NV21'in başı Y düzlemidir), simge de gri kesilir.
 */
class GrayFrame(val luma: ByteArray, val width: Int, val height: Int, val stride: Int = width) {
    /** (x, y) pikselinin parlaklığı, 0–255. */
    fun at(x: Int, y: Int): Int = luma[y * stride + x].toInt() and 0xff

    /** Düzlem kareyi taşıyor mu (bozuk boyutlu karede kesim yapılmaz). */
    internal val isValid: Boolean
        get() = width > 0 && height > 0 && stride >= width && (height - 1).toLong() * stride + width <= luma.size
}

/** TV'de çevirinin içine konacak simge: düz metinde [at]. karakterden önce, [image] PNG (data: adresi). */
data class IconPlacement(val at: Int, val image: String)

/**
 * Oyun ipuçlarının içindeki kumanda simgeleri ("Hold △ to sprint", "Use 🕹 to move the camera"). Yazı tanıma simgeyi
 * okuyamaz: harf sanır ("Hold A to sprint", "PressÄ to open", "Useo to move") ya da yerinde boşluk bırakır. Çevirmen
 * o harfi atınca TV'deki çeviri simgeyi de örtüyor, Türkçede yalnız "basılı tut" kalıyordu; neye basılacağı
 * görünmüyordu. Burada simge satırın içinde bulunur ([mark]), kareden kesilir ([crop]) ve çeviride yeri korunarak
 * ([IconText]) TV'ye resim olarak gider (Windows: ButtonIcons.cs, Mac: ButtonIcons.swift; aynı kurallar).
 */
object ButtonIcons {
    /** Okunan metinde simgenin yeri; satırın [TextLine.icons] listesindeki sıradaki simgedir. */
    const val MARKER = '￼'

    /** Simgeden önce gelen fiiller: "Press △", "Hold R2", "Use ◎". */
    private val verbs = setOf(
        "press", "hold", "tap", "push", "use", "mash", "release", "click", "hit", "pressing", "holding", "tapping", "using",
    )

    /** İki simgeyi bağlayanlar: "Press △ or ○", "Hold L1 + R1". */
    private val joiners = setOf("and", "or", "+", "/", "then")

    /** Düğme adları (büyük harfle) ve simgeleri; harf olarak okunsalar da simgedirler. */
    private val names = setOf(
        "R1", "R2", "R3", "L1", "L2", "L3", "RB", "LB", "RT", "LT", "LS", "RS", "ZL", "ZR",
        "✕", "×", "⨯", "✖", "○", "◯", "●", "□", "▢", "◻", "■", "△", "▲", "⨂",
    )

    /** Sözcük bir kumanda tuşunun adı ya da simgesi mi ("R3", "(L1)", "△"). */
    internal fun isButtonName(text: String): Boolean = text.trim { it in BRACKETS }.uppercase() in names

    /** Fiile yapışık okunan simgeden sonra gelemeyecek harfler: "Uses", "Used", "User", "Pushy", "Tape" sözcüktür. */
    private const val INFLECTIONS = "sdeyr"

    private const val BRACKETS = "()[]{}<>「」\"'“”‘’"
    private const val PUNCTUATION = ".,;:!?…"

    private val punctuationTypes = setOf(
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION, Character.END_PUNCTUATION,
        Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION, Character.OTHER_PUNCTUATION,
    )

    private val whitespace = Regex("\\s+")

    private fun isVerb(text: String) = text.lowercase() in verbs

    private fun isJoiner(text: String) = text.lowercase() in joiners

    /**
     * Satırdaki simgeleri [MARKER] ile işaretler ve yerlerini [TextLine.icons]'a yazar. Simge yalnız ipucu kalıbında
     * aranır, konuşma bozulmasın: bir fiilin ("press", "hold", "use"...) ya da bir simgeden sonra gelen "and/or/+"
     * bağlacının ardındaki (1) tek harf/simge ya da düğme adı ("A", "Ä", "©", "R2"), (2) fiile yapışık tek harf
     * ("PressÄ", "Useo") ve (3) fiilden sonraki, birkaç harf genişliğindeki boşluk (simge hiç okunmamış). Simgeyi tanıyan
     * okuyucunun yazdığı simge karakteri ("Hold △ to sprint") ya da düğme adı da simgedir; işaretlenen satır kumanda
     * ipucu sayılıp atılmaz, simgesiyle çevrilir. Satır başı/sonundaki simge ("R2 Swing", "△ Pick up") işaretlenmez: bu
     * kısa ipuçları bilerek hiç çevrilmez (ek alanda sürekli gelip gider), üstleri de örtülmez. Okuyucu sözcük yerlerini
     * vermiyorsa yerler satırın içinde harf sayısına göre kestirilir; o zaman boşluk aranmaz. Simge yoksa satır olduğu
     * gibi döner.
     */
    fun mark(line: TextLine): TextLine {
        val lineBox = line.box ?: return line
        if (!line.icons.isNullOrEmpty()) return line
        val given = line.words
        val measured = !given.isNullOrEmpty()
        val words = if (given != null && given.isNotEmpty()) given else estimate(line.text, lineBox)
        if (words.isEmpty()) return line
        val charWidth = averageCharWidth(words)
        val tokens = mutableListOf<String>()
        val icons = mutableListOf<IconSlot>()
        val isIcon = BooleanArray(words.size)
        val top = lineBox.top
        val bottom = lineBox.bottom
        val pad = (bottom - top) * 0.3
        // (0) Tuş kalıntısı kalıbı (ButtonPrompts.isIconPrompt, GTA 6 havuzu): "Hold I LI to", "Press (9 0 to",
        // "Release 2 and R2 to". Bağlaçsız art arda kalıntılar tek simgenin parçalarıdır; bağlaç iki simgeyi ayırır.
        val span = ButtonPrompts.iconRemnantSpan(words.map { it.text }, line.text)
        var skipThrough = -1

        for (i in words.indices) {
            if (i <= skipThrough) continue
            val word = words[i]
            if (span != null && i > span.first && i < span.second) {
                if (ButtonPrompts.isConnector(word.text.trim { it in BRACKETS })) {
                    tokens.add(word.text)
                    continue
                }
                var last = i
                while (last + 1 < span.second && !ButtonPrompts.isConnector(words[last + 1].text.trim { it in BRACKETS })) last++
                val left = minOf(word.box.left, (words[i - 1].box.right + word.box.left) / 2)
                val right = maxOf(words[last].box.right, (words[last].box.right + words[last + 1].box.left) / 2)
                tokens.add(MARKER.toString())
                icons.add(IconSlot(TextBox(left, top - pad, right, bottom + pad), words.subList(i, last + 1).joinToString(" ") { it.text }))
                for (k in i..last) isIcon[k] = true
                skipThrough = last
                continue
            }
            val previous = if (i > 0) letters(words[i - 1].text) else ""
            val afterVerb = i > 0 && isVerb(previous)
            val joiner = i > 0 && isJoiner(words[i - 1].text.trim { it in BRACKETS })
            // "Press △ or ○", ya da fiil önceden geçmiş: "Use ◎ to move the camera and △ to interact".
            val afterJoinedIcon = joiner && ((i > 1 && isIcon[i - 2]) ||
                (i + 1 < words.size && words[i + 1].text.equals("to", ignoreCase = true)))

            // (3) Fiil ile bu sözcük arasında okunmamış simge: boşluk birkaç harf genişliğinde.
            if (measured && afterVerb && !isIconToken(word.text) && word.box.left - words[i - 1].box.right >= charWidth * 2.5) {
                tokens.add(MARKER.toString())
                // Sözcük kenarları yaklaşık olabilir: iki yana birer harf payı; kutuya giren harf kırıntıları kırpılırken atılır.
                icons.add(IconSlot(TextBox(words[i - 1].box.right - charWidth, top - pad, word.box.left + charWidth, bottom + pad), ""))
                tokens.add(word.text)
                continue
            }
            // (1) Simgenin okunduğu harf ya da düğme adı.
            if ((afterVerb || afterJoinedIcon) && isIconToken(word.text)) {
                isIcon[i] = true
                // Komşu sözcükle arasındaki boşluğun ortasına kadar; kutular üst üste biniyorsa (yazı tanıma kutuları geniş
                // tutabilir) sözcüğün kendi kutusu küçülmez.
                val width = word.box.right - word.box.left
                val left = minOf(word.box.left, if (i > 0) (words[i - 1].box.right + word.box.left) / 2 else word.box.left - width / 2)
                val right = maxOf(word.box.right,
                    if (i + 1 < words.size) (word.box.right + words[i + 1].box.left) / 2 else word.box.right + width / 2)
                val trail = trailingPunctuation(word.text)
                tokens.add(MARKER.toString() + trail)
                icons.add(IconSlot(TextBox(left, top - pad, right, bottom + pad), word.text.substring(0, word.text.length - trail.length)))
                continue
            }
            // (2) Fiile yapışık simge: "PressÄ", "Useo".
            val verb = gluedVerb(word.text)
            if (verb != null) {
                isIcon[i] = true
                // Simge harften geniştir; kesim fiilin son harfinden başlar, fazlası kırpılırken atılır.
                val split = minOf(word.box.right, word.box.left + (verb.length - 1) * charWidth)
                val right = if (i + 1 < words.size) (word.box.right + words[i + 1].box.left) / 2 else word.box.right
                tokens.add(verb)
                tokens.add(MARKER.toString())
                icons.add(IconSlot(TextBox(split, top - pad, right, bottom + pad), word.text.substring(verb.length)))
                continue
            }
            tokens.add(word.text)
        }
        if (icons.isEmpty()) return line
        return line.copy(text = tokens.joinToString(" "), words = null, icons = icons)
    }

    /**
     * Yazı tanıma ipucu satırını simgenin olduğu yerden bölebilir: "Press" | "R2" | "to open the weapon wheel." ayrı
     * satırlar olunca cümle ikiye bölünüp çevriliyordu. Aynı sırada yan yana duran (aralarında en çok [Reading.ROW_GAP])
     * ve ipucu kalıbını sürdüren parçalar tek satır olur: soldaki parça fiille ya da fiilden sonraki simgeyle biter, ya da
     * sağdaki parça "and/or"dan sonra gelen tek simgedir. Sözcük yerleri korunur.
     */
    fun joinHints(reading: Reading): Reading {
        if (reading.lines.size < 2 || reading.lines.any { it.box == null }) return reading
        val pieces = reading.lines.toMutableList()
        var joined = true
        while (joined) {
            joined = false
            search@ for (a in pieces.indices) {
                for (b in pieces.indices) {
                    if (a == b || !continues(pieces[a], pieces[b])) continue
                    val left = pieces[a]
                    val right = pieces[b]
                    val leftBox = left.box!!
                    val rightBox = right.box!!
                    pieces[a] = TextLine(left.text + " " + right.text, leftBox.union(rightBox),
                        words = (left.words ?: estimate(left.text, leftBox)) + (right.words ?: estimate(right.text, rightBox)))
                    pieces.removeAt(b)
                    joined = true
                    break@search
                }
            }
        }
        return if (pieces.size == reading.lines.size) reading else Reading(pieces.sortedBy { it.box!!.top })
    }

    /** [right], [left]'in hemen sağında aynı sırada ve ipucu ondan sürüyor. */
    private fun continues(left: TextLine, right: TextLine): Boolean {
        val a = left.box!!
        val b = right.box!!
        val overlap = minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)
        val smaller = minOf(a.bottom - a.top, b.bottom - b.top)
        if (smaller <= 0 || overlap < smaller * 0.6 || b.left <= a.left || b.left - a.right > Reading.ROW_GAP) return false
        val first = left.text.split(whitespace).filter { it.isNotEmpty() }
        val second = right.text.split(whitespace).filter { it.isNotEmpty() }
        if (first.isEmpty() || second.isEmpty()) return false
        if (isVerb(letters(first.last()))) return true
        if (first.size >= 2 && isIconToken(first.last()) &&
            (isVerb(letters(first[first.size - 2])) || isJoiner(first[first.size - 2]))) return true
        return second.size == 1 && isIconToken(second[0]) && isJoiner(first.last())
    }

    /** Tek harf/simge (küçük "a" ve "I" dışında: sözcüktürler) ya da düğme adı; çevresindeki parantez ve noktalama sayılmaz. */
    private fun isIconToken(text: String): Boolean {
        val core = text.trim { it in BRACKETS }.trimEnd { it in PUNCTUATION }.trim { it in BRACKETS }
        if (core.uppercase() in names) return true
        if (core.length != 1) return false
        val c = core[0]
        if (c.isDigit() || c == 'a' || c == 'I' || c == '-' || c == '–' || c == '—' || c == '&') return false
        return c.isUpperCase() || c == 'o' || c == 'x' || !c.isLetter()
    }

    /** Fiile yapışmış tek harf ("PressÄ" → "Press"); değilse null. */
    private fun gluedVerb(text: String): String? {
        if (text.length < 4) return null
        val verb = text.substring(0, text.length - 1)
        val last = text[text.length - 1]
        if (!isVerb(verb) || !verb.all { it.isLetter() }) return null
        if (last.isLowerCase() && last in INFLECTIONS) return null
        return if (last.isLetter() || !isPunctuation(last)) verb else null
    }

    private fun isPunctuation(c: Char) = Character.getType(c).toByte() in punctuationTypes

    private fun trailingPunctuation(text: String): String {
        var end = text.length
        while (end > 1 && text[end - 1] in PUNCTUATION) end--
        return text.substring(end)
    }

    private fun letters(text: String) = text.filter { it.isLetter() }

    /** Yeri bilinen sözcüklerin harf başına ortalama genişliği (alan genişliğine oranla). */
    private fun averageCharWidth(words: List<TextWord>): Double {
        val normal = words.filter { it.text.length >= 2 && !isIconToken(it.text) }.ifEmpty { words }
        val chars = normal.sumOf { it.text.length }
        return if (chars == 0) 0.0 else normal.sumOf { it.box.right - it.box.left } / chars
    }

    /** Sözcük yerleri bilinmiyorsa satırın kutusu harf sayısına göre paylaştırılır. */
    internal fun estimate(text: String, box: TextBox): List<TextWord> {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return emptyList()
        val width = (box.right - box.left) / trimmed.length
        val result = mutableListOf<TextWord>()
        var start = 0
        for (i in 0..trimmed.length) {
            if (i < trimmed.length && trimmed[i] != ' ') continue
            if (i > start) {
                result.add(TextWord(trimmed.substring(start, i), TextBox(box.left + start * width, box.top, box.left + i * width, box.bottom)))
            }
            start = i + 1
        }
        return result
    }

    /**
     * Simgeyi kareden keser ve PNG (data: adresi) olarak verir; bulunamazsa null. Kutu kabacadır (simgenin okunduğu harf
     * simgeden dar, kestirilen yer kayık olabilir): içindeki zeminden ayrışan pikseller bitişik kümelere ayrılır, kutunun
     * ortasındaki en büyük küme simgedir ve sıkıca kırpılır. [frame], kutunun oranlandığı karedir. Windows'tan farkı:
     * kare gri olduğundan simge de gri kesilir.
     */
    fun crop(frame: GrayFrame, box: TextBox): String? {
        val icon = locate(frame, box) ?: return null
        return "data:image/png;base64," +
            Base64.getEncoder().encodeToString(png(frame, icon.left, icon.top, icon.width, icon.height))
    }

    /** Karede bulunan simge: kesilecek parça (piksel, kırpma payıyla) ve simgenin kendi genişliği/yüksekliği. */
    private class Located(val left: Int, val top: Int, val width: Int, val height: Int, val inkWidth: Int, val inkHeight: Int)

    private fun locate(frame: GrayFrame, box: TextBox): Located? {
        if (!frame.isValid || !box.left.isFinite() || !box.top.isFinite() || !box.right.isFinite() || !box.bottom.isFinite()) return null
        val x0 = floor(box.left * frame.width).toInt().coerceIn(0, frame.width)
        val x1 = ceil(box.right * frame.width).toInt().coerceIn(0, frame.width)
        val y0 = floor(box.top * frame.height).toInt().coerceIn(0, frame.height)
        val y1 = ceil(box.bottom * frame.height).toInt().coerceIn(0, frame.height)
        val width = x1 - x0
        val height = y1 - y0
        if (width < 4 || height < 6) return null

        val background = borderMedian(frame, x0, y0, width, height)
        val ink = BooleanArray(width * height)
        for (y in 0 until height) {
            for (x in 0 until width) {
                // Windows üç renk kanalının farkını toplar (> 90); gri karede kanallar aynıdır: 3 × fark.
                ink[y * width + x] = abs(frame.at(x0 + x, y0 + y) - background) * 3 > 90
            }
        }

        // Bitişik piksel kümeleri: simge genellikle kutudaki en büyük kümedir; kutuya taşan komşu harfler ("Use|o") ayrı
        // küçük kümelerdir. Ana kümenin içine düşen kümeler (halkanın içindeki △, düğmenin üstündeki "R2") simgeye katılır.
        val components = components(ink, width, height)
        val central = components.filter { (it.left + it.right) / 2.0 >= width * 0.1 && (it.left + it.right) / 2.0 <= width * 0.9 }
        if (central.isEmpty()) return null
        val main = central.maxBy { (it.right - it.left) * (it.bottom - it.top) }
        var start = main.left
        var end = main.right
        var top = main.top
        var bottom = main.bottom
        val padX = (end - start) * 0.15
        val padY = (bottom - top) * 0.15
        for (c in components) {
            if (c.left >= start - padX && c.right <= end + padX && c.top >= top - padY && c.bottom <= bottom + padY) {
                start = minOf(start, c.left)
                end = maxOf(end, c.right)
                top = minOf(top, c.top)
                bottom = maxOf(bottom, c.bottom)
            }
        }
        // Simge satır yüksekliğinin en az üçte biri kadardır; daha küçüğü kir ya da harf kırıntısıdır.
        if (bottom - top < height * 0.3 || end - start < 3) return null

        val margin = 2
        val left = maxOf(0, x0 + start - margin)
        val right = minOf(frame.width, x0 + end + margin)
        val cropTop = maxOf(0, y0 + top - margin)
        val cropBottom = minOf(frame.height, y0 + bottom + margin)
        return Located(left, cropTop, right - left, cropBottom - cropTop, end - start, bottom - top)
    }

    /** Renkli zeminde (kutu kenarının ortancası) her kanalda zemine bu kadar yakın nokta zemindir, simge sayılmaz. */
    const val BASE_TOLERANCE = 40

    /**
     * Kutudaki parlak piksellerin çoğu renksiz mi (kumanda simgesi beyaz/gri; portre, harita renkli). [color]: karenin
     * (x, y) noktasının rengi (0xRRGGBB); renk yoksa karar verilemez, simge sayılmaz (Mac isColourless, Windows
     * IsColourless ile aynı eşikler).
     */
    internal fun isColourless(frame: GrayFrame, color: ((Int, Int) -> Int)?, box: TextBox): Boolean {
        if (color == null || !frame.isValid) return false
        val x0 = maxOf(0, floor(box.left * frame.width).toInt())
        val x1 = minOf(frame.width, ceil(box.right * frame.width).toInt())
        val y0 = maxOf(0, floor(box.top * frame.height).toInt())
        val y1 = minOf(frame.height, ceil(box.bottom * frame.height).toInt())
        if (x1 - x0 < 2 || y1 - y0 < 2) return false
        // Zemin: kutunun kenarındaki noktaların ortancası. Beyaz simgenin kenarı zeminle karışır (mavi haritada mavimsi);
        // zeminle beyaz arasındaki karışım renkli sayılmaz (#860: GTA 6 haritasında L3/R3 simgesi tanınmıyordu).
        val reds = ArrayList<Int>()
        val greens = ArrayList<Int>()
        val blues = ArrayList<Int>()
        for (y in y0 until y1) for (x in x0 until x1) {
            if (y != y0 && y != y1 - 1 && x != x0 && x != x1 - 1) continue
            val rgb = color(x, y)
            reds.add((rgb shr 16) and 0xff)
            greens.add((rgb shr 8) and 0xff)
            blues.add(rgb and 0xff)
        }
        fun median(values: ArrayList<Int>): Int { values.sort(); return values[values.size / 2] }
        val br = median(reds)
        val bg = median(greens)
        val bb = median(blues)
        val baseLuma = (299 * br + 587 * bg + 114 * bb) / 1000
        val colourfulBase = maxOf(br, bg, bb) - minOf(br, bg, bb) > 60
        var bright = 0
        var coloured = 0
        for (y in y0 until y1) for (x in x0 until x1) {
            val rgb = color(x, y)
            val r = (rgb shr 16) and 0xff
            val g = (rgb shr 8) and 0xff
            val b = rgb and 0xff
            val luma = (299 * r + 587 * g + 114 * b) / 1000
            // Zeminin kendisi simgenin parçası değildir: parlak renkli zeminde (GTA 6 haritasının açık mavi denizi) zemin
            // noktaları renkli sayılıyor, haritadaki ✕/○ simgesi tanınmayıp çeviri kutusuna giriyordu.
            if (colourfulBase && maxOf(abs(r - br), abs(g - bg), abs(b - bb)) <= BASE_TOLERANCE) continue
            if (luma < 110) continue
            bright++
            if (maxOf(r, g, b) - minOf(r, g, b) <= 60) continue
            // Karışım muafiyeti yalnız koyu zeminde: kenarına kadar dolu renkli portre simge değildir.
            if (baseLuma >= 110) { coloured++; continue }
            // Zeminle beyazın karışımı mı: karışım oranı parlaklıktan, beklenen renk ondan.
            val share = if (baseLuma >= 250) 1.0 else ((luma - baseLuma).toDouble() / (255 - baseLuma)).coerceIn(0.0, 1.0)
            fun expected(channel: Int) = channel * (1 - share) + 255 * share
            val distance = maxOf(abs(r - expected(br)), abs(g - expected(bg)), abs(b - expected(bb)))
            if (distance > 60) coloured++
        }
        return bright > 0 && coloured * 4 < bright
    }

    /** Tuş çubuğunda yanlış okunmuş omuz tuşu: L1/R1 "11", L2 "12", L3 "13"... */
    private val shoulderMisreads = setOf("11", "12", "13", "21", "22", "23")

    /**
     * Ek alanlardaki tuş çubuklarında ve satır uçlarında yalnız kareden doğrulanan simgeler işaretlenir ([mark] fiil
     * kalıbını zaten kapsar): büyük harfli tuş çubuğunda ("SET DESTINATION ✕ EXIT ○", "OFFER RIDE e LUCIA") sözcük
     * arasındaki simge genişliğinde boşluk, tek harf ya da harfsiz parça, sonundaki simge; satırın başındaki simge
     * ("△ Pick up"). Sıradan cümlenin ortasındaki boşluk aranmaz: orada harita işareti ya da renkli ad durur. Mac
     * ButtonIcons.markFree ve Windows ButtonIcons.MarkFree ile aynı kurallar ve eşikler.
     *
     * [monochrome]: otomatik bulunan ekran yazısında ve "Ekranı çevir"deki satır uçlarında yalnız renksiz (beyaz/gri;
     * [color] gerekir) ve satır yüksekliğinin en az %60'ı kadar simgeler kabul edilir; satırın solunda ya da sonunda
     * simge aranmaz, satırın başındaki ve sonundaki simge çeviriye taşınmaz (kutu simgeden sonra başlar, önce biter).
     * Görev kutusundaki portre ve harita parçası simge sanılıp çevirinin içine kesiliyordu; "RECENTER 13" gibi yanlış
     * okunmuş simge kutuda kalıyordu (#860).
     */
    fun markFree(line: TextLine, frame: GrayFrame, color: ((Int, Int) -> Int)? = null, monochrome: Boolean = false): TextLine {
        val lineBox = line.box ?: return line
        if (!line.icons.isNullOrEmpty() || !frame.isValid || frame.width < 8 || frame.height < 8) return line
        val given = line.words
        val measured = !given.isNullOrEmpty()
        val words = if (given != null && given.isNotEmpty()) given else estimate(line.text, lineBox)
        val width = frame.width.toDouble()
        val lineHeight = lineBox.bottom - lineBox.top
        val linePx = lineHeight * frame.height
        if (words.isEmpty() || linePx < 6) return line
        val head = words.map { it.text }.filter { it.length > 1 && it.uppercase() !in names }.joinToString("")
        val bar = head.count { it.isLetter() } >= 2 && head == head.uppercase()
        val spanX = linePx * 1.8 / width
        val symbol = MARKER.toString()
        val tokens = mutableListOf<String>()
        val icons = mutableListOf<IconSlot>()
        fun padded(left: Double, right: Double) = TextBox(
            left.coerceIn(0.0, 1.0), (lineBox.top - lineHeight * 0.3).coerceIn(0.0, 1.0),
            right.coerceIn(0.0, 1.0), (lineBox.bottom + lineHeight * 0.3).coerceIn(0.0, 1.0),
        )
        fun hasIcon(box: TextBox): Boolean {
            val ink = locate(frame, box) ?: return false
            if (ink.inkHeight < linePx * (if (monochrome) 0.6 else 0.5) || ink.inkHeight > linePx * 2.2) return false
            val aspect = ink.inkWidth.toDouble() / ink.inkHeight
            return aspect in 0.6..2.4 && (!monochrome || isColourless(frame, color, box))
        }
        fun addEdge(left: Double, right: Double) {
            val box = padded(left, right)
            if (hasIcon(box)) {
                tokens.add(symbol)
                icons.add(IconSlot(box, ""))
            }
        }
        // Satırın solundaki simge (okunmamış): "△ Pick up".
        if (!monochrome && !isIconToken(words[0].text) && lineBox.left > 0) addEdge(lineBox.left - spanX, lineBox.left - spanX * 0.08)
        for ((i, word) in words.withIndex()) {
            if (bar && i > 0 && tokens.lastOrNull() != symbol) {
                val left = words[i - 1].box.right
                val gap = word.box.left - left
                if (gap * width > linePx * 0.9) addEdge(left + gap * 0.1, word.box.left - gap * 0.1)
            }
            val core = word.text.trim { it in BRACKETS }
            val named = core.uppercase() in names
            val hasLettersOrDigits = core.any { it.isLetter() || it.isDigit() }
            // Tuş çubuğunda tek harf/rakam ya da yanlış okunmuş omuz tuşu ("11", "12"); satır sonundaki harf+rakam ("C3",
            // "13"): yuvarlak L3/R3 simgesinin okunuşu (#860). Tuş çubuğu dışında: satır başında simge gibi parça.
            val suspicious = if (bar) {
                named || core.length == 1 || core in shoulderMisreads ||
                    (i == words.size - 1 && i > 0 && core.length == 2 && core.last().isDigit()) ||
                    (core.length <= 2 && !hasLettersOrDigits)
            } else {
                i == 0 && words.size >= 2 && isIconToken(word.text)
            }
            if (suspicious) {
                val halfWidth = (word.box.right - word.box.left) / 2
                var left = if (i > 0) minOf(word.box.left, (words[i - 1].box.right + word.box.left) / 2) else word.box.left - halfWidth
                var right = if (i + 1 < words.size) maxOf(word.box.right, (word.box.right + words[i + 1].box.left) / 2)
                    else word.box.right + halfWidth
                // Yazı tanıma yalnız içteki harfleri kutulayabilir: dış çerçeveye pay bırak, iki düğme arasındaki ortayı geçme.
                val measuredButton = named && measured
                if (measuredButton) {
                    val rim = linePx * 0.3 / width
                    left = maxOf(left, word.box.left - rim)
                    right = minOf(right, word.box.right + rim)
                }
                val box = padded(left, right)
                if (hasIcon(box)) {
                    if (measuredButton || tokens.lastOrNull() != symbol) {
                        tokens.add(symbol)
                        icons.add(IconSlot(box, core))
                    }
                    continue
                }
                // Tanınmayan harfsiz parça ("•", "*"): simge değil, yazı da değil.
                if (!named && !hasLettersOrDigits && core !in setOf("+", "/", "&", "-")) continue
            }
            tokens.add(word.text)
        }
        // Tuş çubuğunun sonundaki simge: "SELECT ✕".
        if (!monochrome && bar && tokens.isNotEmpty() && tokens.last() != symbol && lineBox.right < 1) {
            addEdge(lineBox.right + spanX * 0.08, lineBox.right + spanX)
        }
        if (icons.isEmpty()) return line
        if (monochrome) {
            // Satırın başındaki ve sonundaki simge çeviriye taşınmaz: oyunun kendi simgesi yerinde görünür kalır, çeviri
            // kutusu simgeden sonra başlar (önce biter). Yazının ortasındaki simge korunur.
            val kept = tokens.toMutableList()
            val slots = icons.toMutableList()
            while (kept.firstOrNull() == symbol && kept.size > 1) { kept.removeAt(0); slots.removeAt(0) }
            while (kept.lastOrNull() == symbol && kept.size > 1) { kept.removeAt(kept.size - 1); slots.removeAt(slots.size - 1) }
            if (kept.size == tokens.size) return TextLine(tokens.joinToString(" "), line.box, icons = icons, confidence = line.confidence)
            val texts = kept.filter { it != symbol }.toSet()
            val boxes = words.filter { it.text in texts }.map { it.box }
            val box = if (boxes.isEmpty()) lineBox
                else TextBox(maxOf(lineBox.left, boxes.first().left), lineBox.top, minOf(lineBox.right, boxes.last().right), lineBox.bottom)
            return TextLine(kept.joinToString(" "), box, icons = slots.takeIf { it.isNotEmpty() }, confidence = line.confidence)
        }
        return TextLine(tokens.joinToString(" "), line.box, icons = icons, confidence = line.confidence)
    }

    /** Kesilmiş simgeler: kutusu verilen her simge kareden kesilir (bkz. [crop]). */
    fun withImages(icons: List<IconSlot>, frame: GrayFrame): List<IconSlot> =
        icons.map { if (it.image == null) it.copy(image = crop(frame, it.box)) else it }

    private class Bounds(val left: Int, val top: Int, val right: Int, val bottom: Int)

    /** Sekiz komşulu bitişik piksel kümelerinin kutuları (sağ ve alt kenar dahil değil); dört pikselden küçükler atılır. */
    private fun components(ink: BooleanArray, width: Int, height: Int): List<Bounds> {
        val seen = BooleanArray(ink.size)
        val result = mutableListOf<Bounds>()
        // Her piksel yığına en çok bir kez girer (girerken görüldü sayılır).
        val stack = IntArray(ink.size)
        for (first in ink.indices) {
            if (!ink[first] || seen[first]) continue
            var left = width
            var top = height
            var right = 0
            var bottom = 0
            var count = 0
            var size = 0
            seen[first] = true
            stack[size++] = first
            while (size > 0) {
                val index = stack[--size]
                val x = index % width
                val y = index / width
                count++
                left = minOf(left, x)
                right = maxOf(right, x + 1)
                top = minOf(top, y)
                bottom = maxOf(bottom, y + 1)
                for (dy in -1..1) {
                    for (dx in -1..1) {
                        val nx = x + dx
                        val ny = y + dy
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue
                        val next = ny * width + nx
                        if (!ink[next] || seen[next]) continue
                        seen[next] = true
                        stack[size++] = next
                    }
                }
            }
            if (count >= 4) result.add(Bounds(left, top, right, bottom))
        }
        return result
    }

    /** Kutunun kenar piksellerinin ortanca parlaklığı: zemin. */
    private fun borderMedian(frame: GrayFrame, x0: Int, y0: Int, width: Int, height: Int): Int {
        val values = ArrayList<Int>(2 * (width + height))
        for (x in x0 until x0 + width) {
            values.add(frame.at(x, y0))
            values.add(frame.at(x, y0 + height - 1))
        }
        for (y in y0 until y0 + height) {
            values.add(frame.at(x0, y))
            values.add(frame.at(x0 + width - 1, y))
        }
        values.sort()
        return values[values.size / 2]
    }

    /** Karenin ([left], [top]) köşeli [width]×[height] parçasını 8 bit gri PNG'ye çevirir. */
    fun png(frame: GrayFrame, left: Int = 0, top: Int = 0, width: Int = frame.width, height: Int = frame.height): ByteArray {
        val raw = ByteArray(height * (width + 1))
        for (y in 0 until height) {
            // Her satırın başında süzgeç türü: 0 (yok).
            System.arraycopy(frame.luma, (top + y) * frame.stride + left, raw, y * (width + 1) + 1, width)
        }
        val deflater = Deflater(Deflater.BEST_COMPRESSION)
        val compressed = try {
            deflater.setInput(raw)
            deflater.finish()
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (!deflater.finished()) {
                val count = deflater.deflate(buffer)
                out.write(buffer, 0, count)
            }
            out.toByteArray()
        } finally {
            deflater.end()
        }
        val png = ByteArrayOutputStream()
        val signature = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        png.write(signature, 0, signature.size)
        val header = ByteArray(13)
        writeBigEndian(header, 0, width)
        writeBigEndian(header, 4, height)
        header[8] = 8 // bit derinliği
        header[9] = 0 // gri
        chunk(png, "IHDR", header)
        chunk(png, "IDAT", compressed)
        chunk(png, "IEND", ByteArray(0))
        return png.toByteArray()
    }

    private fun chunk(out: ByteArrayOutputStream, type: String, data: ByteArray) {
        val length = ByteArray(4)
        writeBigEndian(length, 0, data.size)
        out.write(length, 0, length.size)
        val body = type.toByteArray(Charsets.US_ASCII) + data
        out.write(body, 0, body.size)
        val crc = CRC32()
        crc.update(body, 0, body.size)
        val sum = ByteArray(4)
        writeBigEndian(sum, 0, crc.value.toInt())
        out.write(sum, 0, sum.size)
    }

    private fun writeBigEndian(target: ByteArray, offset: Int, value: Int) {
        target[offset] = (value ushr 24).toByte()
        target[offset + 1] = (value ushr 16).toByte()
        target[offset + 2] = (value ushr 8).toByte()
        target[offset + 3] = value.toByte()
    }
}

/**
 * Simgenin yerini çeviri boyunca korur. Çeviriden önce her [ButtonIcons.MARKER] uydurma bir özel adla değiştirilir
 * (terim korumasıyla aynı gerekçe: çevirmenler özel adı olduğu gibi bırakır, "[1]" gibi işaretleri düşürebilir):
 * "Hold Feldor to sprint" → "Koşmak için Feldor'u basılı tut". Çeviriden sonra ad (ekiyle birlikte: ek gerçek düğmenin
 * adına uymaz) simgenin sıra imine döner; çevirmen adı düşürdüyse simge başa konur (Windows: ButtonIcons.cs IconText).
 */
object IconText {
    /** Çevrilmiş metinde k. simgenin imi: U+E000 + k (özel kullanım alanı). */
    const val FIRST_SLOT = ''

    /**
     * Terim korumasının adlarıyla (translation.TermProtector.placeholders) aynı kurallar; sondan başlanır, ikisi aynı
     * metinde karşılaşmasın. Çekirdek çeviri katmanına bağlanmasın diye liste burada da yazılıdır.
     */
    private val names = listOf("Zarmon", "Velkor", "Dorvan", "Kelmar", "Tolvar", "Brandur", "Halvor", "Feldor").reversed()

    private val multipleSpaces = Regex(" {2,}")

    /** Korunmuş metin ve içinde kullanılan adlar, simgelerin sırasıyla. */
    data class Protected(val text: String, val names: List<String>)

    /** Çevrilecek düz metin ve simgelerin bu metindeki yerleri. */
    data class Rendered(val text: String, val icons: List<IconPlacement>)

    /**
     * Simgeleri adlarla değiştirir; kullanılan adlar sırayla döner. Ad kalmazsa fazla simge düşer. Simgenin ardındaki
     * noktalama ada yapışık kalır ("Hold Feldor.").
     */
    fun protect(paragraph: String): Protected {
        if (paragraph.indexOf(ButtonIcons.MARKER) < 0) return Protected(paragraph, emptyList())
        val free = ArrayDeque(names.filter { !paragraph.contains(it, ignoreCase = true) })
        val used = mutableListOf<String>()
        val builder = StringBuilder(paragraph.length + 16)
        for (c in paragraph) {
            if (c != ButtonIcons.MARKER) {
                builder.append(c)
            } else if (free.isNotEmpty()) {
                val name = free.removeFirst()
                used.add(name)
                builder.append(name)
            }
        }
        return Protected(collapse(builder.toString()), used)
    }

    /**
     * Çevirideki adları [offset]'ten başlayan sıra imlerine çevirir. Çeviride bulunmayan adın simgesi metnin başına
     * konur (en azından hangi düğme olduğu görünsün).
     */
    fun restore(translation: String, names: List<String>, offset: Int): String {
        var text = translation
        val missing = StringBuilder()
        for (k in names.indices) {
            val slot = (FIRST_SLOT + offset + k).toString()
            val pattern = Regex(
                "(?<![\\p{L}\\p{N}])" + Regex.escape(names[k]) + "(?:\\s?['’`´]\\p{L}+|\\p{L}+)?(?![\\p{L}\\p{N}])",
                RegexOption.IGNORE_CASE,
            )
            if (pattern.containsMatchIn(text)) text = pattern.replace(text, Regex.escapeReplacement(slot))
            else missing.append(slot).append(' ')
        }
        return if (missing.isEmpty()) text else missing.toString() + text
    }

    /** Okunan paragraf çevrilmeden gösterilecekse simgeleri sırayla imlenir. */
    fun indexed(paragraph: String, offset: Int): String {
        val builder = StringBuilder(paragraph.length)
        var next = offset
        for (c in paragraph) builder.append(if (c == ButtonIcons.MARKER) FIRST_SLOT + next++ else c)
        return builder.toString()
    }

    /**
     * İmli metni TV'ye gidecek düz metne ve simge yerlerine ayırır. Kesilemeyen simgenin yerine okunan hali yazılır;
     * art arda boşluklar teke iner (eski TV uygulamaları simgesiz düz metni gösterir).
     */
    fun render(marked: String, slots: List<IconSlot>): Rendered {
        val text = StringBuilder(marked.length)
        val icons = mutableListOf<IconPlacement>()
        fun append(value: String) {
            for (c in value) {
                if (c == ' ' && (text.isEmpty() || text[text.length - 1] == ' ' || text[text.length - 1] == '\n')) continue
                // Simgenin ardındaki noktalama ve satır sonu önündeki boşluğu yutar: "için [◎], etkileşim".
                if ((c == '\n' || c in ".,;:!?…)") && text.isNotEmpty() && text[text.length - 1] == ' ') {
                    text.setLength(text.length - 1)
                    for (i in icons.indices) if (icons[i].at > text.length) icons[i] = icons[i].copy(at = text.length)
                }
                text.append(c)
            }
        }
        for (c in marked) {
            val k = c - FIRST_SLOT
            if (c == ButtonIcons.MARKER || k < 0 || k >= 0x100) {
                if (c != ButtonIcons.MARKER) append(c.toString())
                continue
            }
            if (k >= slots.size) continue
            val image = slots[k].image
            if (image != null) icons.add(IconPlacement(text.length, image)) else append(slots[k].text)
        }
        val trimmed = text.toString().trimEnd()
        return Rendered(trimmed, icons.map { it.copy(at = minOf(it.at, trimmed.length)) })
    }

    /** Simgesiz düz metin (okunanın kaydı, paket araması ve karşılaştırma için). */
    fun plain(text: String): String =
        collapse(text.filter { it != ButtonIcons.MARKER && (it < FIRST_SLOT || it >= FIRST_SLOT + 0x100) })

    private fun collapse(text: String) = text.replace(multipleSpaces, " ").trim()
}
