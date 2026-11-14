// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale

/** OCR çıktılarını karşılaştırmak için sadeleştirme ve gürültüye dayanıklı benzerlik (Windows: TextMatch.cs). */
object TextMatch {
    /** Küçük harf, yalnız harf/rakam, tek boşluk. */
    fun normalize(s: String): String {
        val builder = StringBuilder(s.length)
        for (c in s.lowercase(Locale.ROOT)) builder.append(if (isAlphanumeric(c)) c else ' ')
        return builder.toString().split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** Levenshtein oranı [threshold] ve üstündeyse benzer sayılır. Boş metin hiçbir metne benzemez. */
    fun isSimilar(a: String, b: String, threshold: Double = 0.85): Boolean {
        if (a == b) return a.isNotEmpty()
        if (a.isEmpty() || b.isEmpty()) return false
        var previous = IntArray(b.length + 1) { it }
        var row = IntArray(b.length + 1)
        for (i in 1..a.length) {
            row[0] = i
            for (j in 1..b.length)
                row[j] = minOf(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            val swap = previous
            previous = row
            row = swap
        }
        return 1 - previous[b.length].toDouble() / maxOf(a.length, b.length) >= threshold
    }

    /** Satırları ayrı ayrı sadeleştirip alt alta birleştirir; [isSameSubtitle] kaçırılan satırı bundan anlar. */
    fun normalizeRows(s: String): String =
        s.replace("\r\n", "\n").split('\n').map(::normalize).filter { it.isNotEmpty() }.joinToString("\n")

    /**
     * Yeni okuma, gönderilmiş altyazının yeniden okuması mı (sadeleştirilmiş metinler; [sent] satırları alt alta).
     * Süslü yazı tipinde ya da solarken OCR bir iki sözcüğü her karede başka çöpe çevirir ya da iki satırlık altyazının
     * bir satırını kaçırır; sözcükler aynı kalır. Başına ya da sonuna sözcük eklenmiş metin yenidir; sondan kısalmış metin
     * ancak tam bir satırı eksikse aynı altyazıdır.
     */
    fun isSameSubtitle(reread: String, sent: String): Boolean {
        val rows = sent.split('\n')
        val flat = rows.joinToString(" ")
        val x = cleanWords(reread)
        val y = cleanWords(flat)
        // Uzayan metin (daktilo efekti ya da aynı sözlerle başlayan yeni satır) karakterce benzese de yenidir.
        if (y.isNotEmpty() && x.size > y.size && (startsWith(x, y) || endsWith(x, y))) return false
        if (isSimilar(reread, flat)) return true
        // Baştan ya da sondan kesilmiş okuma: yalnız tam satırları okunduysa aynıdır, yoksa başka bir cümledir.
        if (x.isNotEmpty() && x.size < y.size && (startsWith(y, x) || endsWith(y, x)))
            return isWholeRows(x.size, rows, startsWith(y, x))
        val remaining = y.toMutableList()
        val sentCount = remaining.size
        var shared = 0
        for (word in x) if (remaining.remove(word)) shared++
        // Arasından çöp sözcükler düşmüş okuma: yeni okumanın sözcüklerinin hemen hepsi gönderilende var.
        if (x.size in 4..sentCount && shared >= x.size * 0.85) return true
        // Kısa satırda tek sözcük anlamı değiştirir; orada yalnız karakter benzerliği geçerli.
        val longer = maxOf(x.size, sentCount)
        val shorter = minOf(x.size, sentCount)
        if (shorter < 6 || shorter.toDouble() / longer < 0.75) return false
        return shared.toDouble() / longer >= 0.75
    }

    private fun startsWith(words: List<String>, part: List<String>) = words.take(part.size) == part

    private fun endsWith(words: List<String>, part: List<String>) = words.takeLast(part.size) == part

    private fun isWholeRows(count: Int, rows: List<String>, fromStart: Boolean): Boolean {
        var total = 0
        for (row in if (fromStart) rows else rows.reversed()) {
            total += cleanWords(row).size
            if (total == count) return true
            if (total > count) return false
        }
        return false
    }

    // Tek harfler ("a", "I" ya da OCR'ın uydurduğu "O") karşılaştırmaya bir şey katmaz.
    private fun cleanWords(normalized: String): List<String> =
        normalized.split(' ').filter { it.length > 1 && it.none(::isNumber) }

    /** .NET'teki char.IsNumber: Nd, Nl, No. */
    internal fun isNumber(c: Char): Boolean = when (Character.getType(c).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    private fun isAlphanumeric(c: Char): Boolean = when (Character.getType(c).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }
}
