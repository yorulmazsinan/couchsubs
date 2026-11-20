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

    /** Metindeki konuşanlar (her satırın baştaki adı; [SpeakerPrefix.split]), ilk görülüş sırasıyla, tekrarsız. */
    fun speakers(text: String): List<Speaker> =
        text.split('\n').mapNotNull { SpeakerPrefix.split(it)?.name }
            .filter { it.lowercase(Locale.forLanguageTag("tr")) !in turkishHeadings }
            .distinct().map { Speaker(it, color(it)) }

    /** Çeviride ad gibi görünen Türkçe başlıklar ("Hedef: Arabaya bin."); konuşan sayılmaz, renklenmez. */
    private val turkishHeadings = setOf(
        "hedef", "görev", "not", "ipucu", "uyarı", "ödül", "ödüller", "konum", "bölüm", "güncelleme", "bilgi", "durum",
    )

    /**
     * Gösterilecek (satırlara bölünmüş olabilir) [display] metninin renkli parçaları. Konuşanlar [source]'tan (bölünmemiş
     * metin) bulunur; bir parça, satır başında "Ad:" ile başlar ve sonraki konuşanın satırına dek sürer: bölünen uzun
     * cümlenin alt satırları da konuşanın renginde kalır. Konuşan yoksa boş liste.
     */
    fun segments(display: String, source: String = display): List<Segment> {
        val names = speakers(source)
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
