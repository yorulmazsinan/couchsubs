// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale

/**
 * Konuşana göre renk: "Mattia: …" satırında ad ve satır o konuşanın renginde görünür; aynı ad her zaman aynı renktir.
 * Renk addan hesaplanır (FNV-1a, 32 bit, küçük harfli adın UTF-16 kodları); koyu zeminde okunaklı 10 renklik palet.
 * Mac/iPhone (SpeakerColors.swift), Windows (SpeakerColors.cs) ve TV uygulaması aynı paleti ve aynı hesabı kullanır.
 * TV'ye `subtitle` olayının `speakers` alanıyla gider (eski TV uygulamaları alanı yok sayar).
 */
object SpeakerColors {
    val palette = listOf(
        "#FFD54F", "#4FC3F7", "#81C784", "#FF8A65", "#CE93D8",
        "#F06292", "#4DD0E1", "#AED581", "#FFB74D", "#90CAF9",
    )

    data class Speaker(val name: String, val color: String)

    /** Satırın bir parçası; [color] null ise konuşansız (öntanımlı renkte) yazı. */
    data class Segment(val start: Int, val end: Int, val color: String?)

    /** Adın rengi ("#RRGGBB"). Büyük/küçük harf ve baştaki/sondaki boşluk rengi değiştirmez. */
    fun color(name: String): String {
        var hash = 2166136261L
        for (char in name.trim().lowercase(Locale.ROOT)) {
            hash = hash xor char.code.toLong()
            hash = (hash * 16777619L) and 0xffffffffL
        }
        return palette[(hash % palette.size).toInt()]
    }

    /** Çeviri oturumunun renk defteri (çeviri başlayınca sıfırlanır; bkz. [SpeakerColorBook]). */
    val session = SpeakerColorBook()

    /**
     * Metindeki konuşanlar (her satırın baştaki adı; [SpeakerPrefix.split]), ilk görülüş sırasıyla, tekrarsız; renkler
     * [book]'tan (aynı kişinin yakın okumaları aynı renk, yeni kişi kullanılmayan aileden renk alır).
     */
    fun speakers(text: String, book: SpeakerColorBook = session): List<Speaker> =
        text.split('\n').mapNotNull { SpeakerPrefix.split(it)?.name }
            .filter { it.lowercase(Locale.forLanguageTag("tr")) !in turkishHeadings }
            .distinct().mapNotNull { name -> book.color(name)?.let { Speaker(name, it) } }

    /** Çeviride ad gibi görünen Türkçe başlıklar ("Hedef: Arabaya bin."); konuşan sayılmaz, renklenmez. */
    private val turkishHeadings = setOf(
        "hedef", "görev", "not", "ipucu", "uyarı", "ödül", "ödüller", "konum", "bölüm", "güncelleme", "bilgi", "durum",
        "soru", "cevap",
    )

    /**
     * Gösterilecek (satırlara bölünmüş olabilir) [display] metninin renkli parçaları. Konuşanlar [source]'tan (bölünmemiş
     * metin) bulunur; bir parça, satır başında "Ad:" ile başlar ve sonraki konuşanın satırına dek sürer: bölünen uzun
     * cümlenin alt satırları da konuşanın renginde kalır. Konuşan yoksa boş liste.
     */
    fun segments(display: String, source: String = display, book: SpeakerColorBook = session): List<Segment> {
        val names = speakers(source, book)
        if (names.isEmpty()) return emptyList()
        val result = mutableListOf<Segment>()
        var start = 0
        var color: String? = null
        var lineStart = 0
        while (lineStart <= display.length) {
            val line = display.substring(lineStart).substringBefore('\n')
            val trimmed = line.trimStart()
            val match = names.firstOrNull { speaker ->
                trimmed.startsWith(speaker.name) && trimmed.drop(speaker.name.length).trimStart(' ').let { it.startsWith(":") || it.startsWith("：") }
            }
            if (match != null && lineStart > start) {
                result += Segment(start, lineStart, color)
                start = lineStart
            }
            if (match != null) color = match.color
            val next = display.indexOf('\n', lineStart)
            if (next < 0) break
            lineStart = next + 1
        }
        if (display.length > start) result += Segment(start, display.length, color)
        return result
    }
}

/**
 * Konuşana göre renk v2: çeviri oturumu boyunca kişilerin rengi. Ad anahtarı kırpılmış, sondaki noktalaması atılmış,
 * küçük harf addır. Yazı tanımanın yakın okuması aynı kişidir: karışan harfler (l, 1, | → i; 0 → o; rn → m) eşitlenince
 * aynıysa ya da ikisi de en az 5 harfken Levenshtein uzaklığı en çok 1 ise ("Mattia", "Mattla", "Mattia."). Yeni kişi
 * tabanı (FNV-1a % 10) alır; taban ya da ailesi başka bir kişide kullanılıyorsa palet sırasıyla ilk kullanılmayan ve
 * ailesi kullanılmayan renk, o da yoksa ilk kullanılmayan, o da yoksa taban. Dört platform aynı sırayla aynı rengi verir
 * (ortak vektör: docs/speaker-colors-vectors.json; başvuru: scripts/speaker_colors_ref.py).
 */
class SpeakerColorBook {
    companion object {
        /** Renk aileleri: aynı ailedeki iki renk yan yana ayırt edilmesi zor olduğu için iki kişiye birden verilmez. */
        val families = mapOf(
            "#FFD54F" to 'A', "#FFB74D" to 'A', "#FF8A65" to 'A', "#4FC3F7" to 'B', "#4DD0E1" to 'B', "#90CAF9" to 'B',
            "#81C784" to 'C', "#AED581" to 'C', "#CE93D8" to 'D', "#F06292" to 'D',
        )

        fun key(name: String): String = name.trim().trimEnd('.', ',', '!', '?', ';', ':', '…').trim().lowercase(Locale.ROOT)

        private fun confused(key: String): String =
            key.replace("rn", "m").map { when (it) { 'l', '1', '|' -> 'i'; '0' -> 'o'; else -> it } }.joinToString("")

        private fun distance(a: String, b: String): Int {
            var row = IntArray(b.length + 1) { it }
            for (i in 1..a.length) {
                val next = IntArray(b.length + 1)
                next[0] = i
                for (j in 1..b.length) next[j] = minOf(row[j] + 1, next[j - 1] + 1, row[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
                row = next
            }
            return row[b.length]
        }

        private fun base(key: String): Int {
            var hash = 2166136261L
            for (char in key) {
                hash = hash xor char.code.toLong()
                hash = (hash * 16777619L) and 0xffffffffL
            }
            return (hash % SpeakerColors.palette.size).toInt()
        }
    }

    private val people = mutableListOf<Pair<String, String>>()

    /** Kişinin rengi; ad boşsa null. */
    @Synchronized
    fun color(name: String): String? {
        val key = key(name)
        if (key.isEmpty()) return null
        people.firstOrNull { (known, _) ->
            known == key || confused(known) == confused(key) || (minOf(known.length, key.length) >= 5 && distance(known, key) <= 1)
        }?.let { return it.second }
        val palette = SpeakerColors.palette
        val start = base(key)
        val used = people.map { it.second }.toSet()
        val usedFamilies = used.mapNotNull { families[it] }.toSet()
        val ordered = (0 until palette.size).map { palette[(start + it) % palette.size] }
        val pick = ordered.firstOrNull { it !in used && families[it] !in usedFamilies }
            ?: ordered.firstOrNull { it !in used } ?: palette[start]
        people.add(key to pick)
        return pick
    }

    /** Yeni çeviri oturumu: renkler unutulur. */
    @Synchronized
    fun reset() = people.clear()
}
