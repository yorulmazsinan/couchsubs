// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Aynı altyazının farklı okumalarını tanıma kuralları (Windows: SubtitlePipeline.cs içindeki IsRereadOf, Related,
 * KeepMissingLines, LooksComplete; Mac/iPhone: Rereads.swift). Hat, yarım ya da bozuk okumayı kısa süre bekletip aynı
 * satırın en iyi okumasını çevirir; bu kurallar hangi okumanın aynı satır sayılacağını söyler.
 */
object Rereads {
    /** Okuma bozuk mu (OCR izi taşıyor mu). */
    fun looksMisread(text: String): Boolean = PackFuzzy.damaged(text)

    /** Okumanın puanı: daha çok gerçek sözcük, daha uzun. */
    fun score(text: String): Int = OcrNoise.score(text)

    private fun words(text: String) = TextMatch.normalize(text).split(' ').filter { it.isNotEmpty() }

    /** Her satırı büyük harfle başlayıp nokta, soru, ünlem ya da üç noktayla biten okuma. */
    fun looksComplete(text: String): Boolean {
        val lines = text.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
        return lines.isNotEmpty() && lines.all { line ->
            val first = line.firstOrNull { it.isLetter() }
            first != null && first.isUpperCase() && SubtitleStabilizer.endsSentence(line)
        }
    }

    /**
     * İki okuma aynı altyazının okunuşları mı: ortak sözcükler kısa olanın en az yarısı (iki sözcükten kısa satırlarda
     * biri ötekini içermeli).
     */
    fun related(a: String, b: String): Boolean {
        val x = words(a)
        val y = words(b)
        if (x.isEmpty() || y.isEmpty()) return false
        val remaining = y.toMutableList()
        val shared = x.count { remaining.remove(it) }
        val shorter = minOf(x.size, y.size)
        return if (shorter <= 1) shared >= 1 else shared >= 2 && shared * 2 >= shorter
    }

    /** [x] sözcükleri [y]'de aynı sırada geçiyor ama bitişik bir parça değil. */
    private fun isGappedSubsequence(x: List<String>, y: List<String>): Boolean {
        var i = 0
        var firstMatch = -1
        var lastMatch = -1
        for (j in y.indices) {
            if (i >= x.size) break
            if (y[j] != x[i]) continue
            if (firstMatch < 0) firstMatch = j
            lastMatch = j
            i++
        }
        return i == x.size && lastMatch - firstMatch + 1 > x.size
    }

    /**
     * [newer], [older]'ın yeniden okuması mı: biri bozuksa ortak sözcükler yeter; ikisi de temizse yeni okuma eskinin
     * kesilmiş bir parçası olmalı ve cümle sonu işareti taşımamalı ("Get Franklin close to the").
     */
    fun isRereadOf(newer: String, older: String): Boolean {
        // Eskide olmayan olumsuzluk ya da sayı taşıyan okuma yeniden okuma değil, düzeltmedir.
        if (TextMatch.addsMeaning(newer, older)) return false
        val normNewer = TextMatch.normalize(newer)
        val normOlder = TextMatch.normalize(older)
        val x = normNewer.split(' ').filter { it.isNotEmpty() }
        val y = normOlder.split(' ').filter { it.isNotEmpty() }
        if (normNewer.length >= 4 && x.size == y.size && TextMatch.isSimilar(normNewer, normOlder, 0.75)) return true
        if (x.size >= 2 && x.size == y.size) {
            val differing = x.indices.filter { x[it] != y[it] }
            if (differing.isNotEmpty() && differing.size * 2 <= x.size && differing.all { looksMisread(x[it]) }) return true
        }
        if (looksMisread(newer) || looksMisread(older)) return related(newer, older)
        if (x.isEmpty() || x.size > y.size) return false
        if (x.size >= 2 && x.size < y.size && isGappedSubsequence(x, y)) return true
        val head = newer.trimStart().firstOrNull()
        val startsLower = head == null || !head.isUpperCase()
        if (SubtitleStabilizer.endsSentence(newer) && !(startsLower && x.size < y.size)) return false
        for (start in 0..(y.size - x.size)) if (y.subList(start, start + x.size) == x) return true
        return false
    }

    private fun covered(line: String, previous: String): Boolean {
        val norm = TextMatch.normalize(line)
        if (norm.isEmpty()) return true
        if (isRereadOf(line, previous.replace('\n', ' '))) return true
        return previous.split('\n').any { old -> TextMatch.normalize(old) == norm || isRereadOf(line, old) }
    }

    /** Okumanın her satırı az önce çevrilenin (aynı ya da yeniden okunmuş) bir satırı mı. */
    fun allLinesCovered(reading: String, previous: String): Boolean {
        val lines = reading.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
        return lines.isNotEmpty() && lines.all { covered(it, previous) }
    }

    /**
     * Daha iyi okuma bekleyenin yerine geçerken bekleyende olup yenisinde olmayan temiz satırlar korunur (iki satırlı
     * altyazının ikinci satırı bir okumada çıkıp ötekinde kaçabiliyor).
     */
    fun keepMissingLines(better: String, older: String): String {
        val correctedLines = better.split('\n')
        val extra = older.split('\n').map { it.trim() }
            .filter { it.isNotEmpty() && !looksMisread(it) && !covered(it, better) }
            .filter { line ->
                correctedLines.none { TextMatch.addsMeaning(it, line) && TextMatch.isSimilar(TextMatch.normalize(it), TextMatch.normalize(line)) }
            }
        return if (extra.isEmpty()) better else better.trimEnd() + "\n" + extra.joinToString("\n")
    }
}
