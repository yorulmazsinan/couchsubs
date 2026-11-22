// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Sessizlik bekçisi: altyazı alanında konuşmaya benzeyen satır ([isSpeech]) [SILENCE_MS] boyunca okunup hiçbir çeviri
 * gönderilmediyse o satır süzgeçler atlanarak doğrudan çevrilir. En çok [SILENCE_MS]'de bir satır gönderir; aynı satırı bir
 * kez. İlke: fazladan bir HUD çevirisi kabul, diyaloğun kaybolması kabul değil (Mac/iPhone SilenceWatch.swift, Windows
 * SilenceWatch.cs ile aynı kurallar).
 */
class SilenceWatch {
    companion object {
        const val SILENCE_MS = 10_000L
        /** Konuşma sayılmak için en az bu kadar sözcük. */
        const val MIN_WORDS = 3
        /** Rakam taşıyan satır ancak bu kadar sözcükle konuşma sayılır (sayaç, para, saat gibi HUD yazıları geçmesin). */
        const val DIGIT_WORDS = 5

        /**
         * Konuşmaya benzeyen satır: en az üç sözcük, küçük harf içerir ve cümle sonu noktalamasıyla biter ya da konuşan
         * adıyla başlar. Tek sözcük, BÜYÜK HARF etiket ve rakamlı kısa HUD yazısı geçmez.
         */
        fun isSpeech(raw: String): Boolean {
            val text = raw.trim()
            val words = text.split(Regex("\\s+")).count { it.isNotEmpty() }
            if (words < MIN_WORDS || text.none { it.isLowerCase() }) return false
            if (text.any { it.isDigit() } && words < DIGIT_WORDS) return false
            return SubtitleStabilizer.endsSentence(text) || SpeakerPrefix.split(text) != null
        }
    }

    private var since: Long? = null
    private var lastFired: Long? = null
    private val done = mutableSetOf<String>()

    /** Hat bir çeviri gönderdi: sessizlik bitti. */
    fun sent() { since = null }

    /** Okunan satırlardan çevrilmesi gereken (süre dolduysa); yoksa null. */
    fun due(lines: List<String>, time: Long): String? {
        val candidate = lines.filter { isSpeech(it) && TextMatch.normalize(it) !in done }.maxByOrNull { it.length }
        if (candidate == null) {
            since = null
            return null
        }
        val start = since ?: run { since = time; return null }
        if (time - start < SILENCE_MS || lastFired?.let { time - it < SILENCE_MS } == true) return null
        return candidate
    }

    /** Satır gönderildi; aynı satır yeniden gönderilmez, bekçi yeniden [SILENCE_MS] bekler. */
    fun fired(text: String, time: Long) {
        done.add(TextMatch.normalize(text))
        lastFired = time
        since = time
    }
}
