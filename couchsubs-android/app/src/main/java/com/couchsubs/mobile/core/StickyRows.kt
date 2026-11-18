// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Konuşma değişirken ekranda sabit duran satırı (görev/HUD yazısı) okumadan çıkarır. GTA 6'da görev yazısı ("Get in
 * the sea plane") konuşma altyazısının hemen altında dakikalarca durur; yazı tanıma ikisini tek blok okuyordu. Konuşma
 * kalkıp görev tek başına kalınca kararlayıcı bunu gönderilenin bir satırı eksik okuması sayıyor, TV'de eski konuşmanın
 * çevirisi kalıyordu; kısa yeni konuşma da uzun görev satırı yüzünden aynı altyazı sayılıp çevrilmiyordu. Bir satır en
 * az [STICKY_MS] ekranda kaldıysa ve yanında ondan en az [YOUNGER_BY_MS] sonra gelmiş başka bir satır varsa sabit
 * sayılır; sabit satır, ekrandan kalkana dek (tek başına kalsa da) okumadan çıkarılır. Satırları birlikte beliren
 * konuşma kutusu etkilenmez (Mac: StickyRows.swift, Windows: StickyRows.cs).
 */
class StickyRows {
    companion object {
        /** Satır bu kadar ekranda kalmadan sabit sayılmaz. */
        const val STICKY_MS = 6000L
        /** Yanındaki satırın en az bu kadar sonra gelmiş olması gerekir (birlikte beliren satırlar konuşmadır). */
        const val YOUNGER_BY_MS = 3000L
        /** Bu kadar okunmayan satır ekrandan kalkmış sayılır (birkaç karelik okuma kaçağı satırı unutturmaz). */
        const val FORGET_AFTER_MS = 1500L
    }

    private class Row(val text: String, val since: Long) {
        var lastSeen = since
        var sticky = false
    }

    private val rows = mutableListOf<Row>()

    /** Son [filter] çağrısında ilk kez sabit sayılan satırlar (günlük için). */
    var newlySticky: List<String> = emptyList()
        private set

    /** Okumanın sabit (HUD) satırları çıkarılmış hali. [time]: milisaniye saati. */
    fun filter(reading: Reading, time: Long): Reading {
        val newly = mutableListOf<String>()
        val matched = mutableListOf<Row?>()
        val used = mutableSetOf<Row>()
        for (line in reading.lines) {
            val text = TextMatch.normalize(line.text)
            if (text.length < 3) { matched.add(null); continue }
            val row = rows.firstOrNull { it !in used && TextMatch.isSimilar(text, it.text) }
                ?: Row(text, time).also { rows.add(it) }
            row.lastSeen = time
            used.add(row)
            matched.add(row)
        }
        val present = matched.filterNotNull()
        matched.forEachIndexed { i, row ->
            if (row == null || row.sticky || time - row.since < STICKY_MS) return@forEachIndexed
            if (present.any { it.since - row.since >= YOUNGER_BY_MS }) {
                row.sticky = true
                newly.add(reading.lines[i].text)
            }
        }
        newlySticky = newly
        val kept = reading.lines.filterIndexed { i, _ -> matched[i]?.sticky != true }
        rows.removeAll { time - it.lastSeen > FORGET_AFTER_MS }
        return if (kept.size == reading.lines.size) reading else Reading(kept)
    }

    fun reset() {
        rows.clear()
        newlySticky = emptyList()
    }
}
