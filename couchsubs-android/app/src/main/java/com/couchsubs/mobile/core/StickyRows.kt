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
        /**
         * Görev satırı henüz sabit sayılmadan da (ilk [STICKY_MS]) altyazıya karışmasın: okumanın üst ya da alt ucunda
         * duran, yanındaki en yeni satırdan en az bu kadar önce gelmiş, konuşan adı taşımayan satır bu okumadan çıkarılır.
         * Kullanıcı bildirimi (GTA 6): görev yazısı ("x yere git") ekrandayken gelen altyazılar ya görevle tek blok
         * gönderiliyor ya da görev ayrı blok olarak altyazının yerine seçiliyordu; arada diyaloglar kayboluyordu. Yazı
         * yazılır gibi beliren ikinci satır (yaklaşık 1 sn sonra) bu süreden kısa kalır, konuşma bölünmez. Yaş satırın son
         * büyümesinden sayılır (yazı yazılır gibi beliren üst satır alt satır gelene dek büyür) ve üst uçtaki satırın
         * altındaki satır onun devamıysa ([Reading.continues]: cümle bitmemiş, alttaki küçük harfle başlıyor ya da kısa)
         * üst satır çıkarılmaz: iki satırlı altyazının alt satırı geç belirince üst satır atılıyor, yalnız alttaki 1-2
         * sözcük çevriliyordu (GitHub #715).
         */
        const val LINGER_MS = 1200L
    }

    private class Row(var text: String, val since: Long) {
        var lastSeen = since
        /** Satırın en son büyüdüğü an (yazı yazılır gibi beliren satır). */
        var grown = since
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
            if (text.length >= row.text.length + 3) {
                // Satır büyüdü (yazı yazılır gibi): yaşı yeniden başlar; okuma sapmaları (kısalıp uzama) saymaz.
                row.text = text
                row.grown = time
            }
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
        val lingering = lingering(reading, matched)
        val kept = reading.lines.filterIndexed { i, _ -> matched[i]?.sticky != true && !lingering[i] }
        rows.removeAll { time - it.lastSeen > FORGET_AFTER_MS }
        return if (kept.size == reading.lines.size) reading else Reading(kept)
    }

    /**
     * [LINGER_MS]: okumanın üst ya da alt ucundaki, en yeni satırdan en az o kadar eski satırlar (görev yazısı). Sabit
     * satırlar hesaba katılmaz; konuşan adlı satır hiç çıkarılmaz.
     */
    private fun lingering(reading: Reading, matched: List<Row?>): BooleanArray {
        val result = BooleanArray(reading.lines.size)
        val live = matched.indices.filter { matched[it]?.sticky == false }
        if (live.size < 2) return result
        val youngest = live.maxOf { matched[it]!!.since }
        fun old(i: Int) = youngest - matched[i]!!.grown >= LINGER_MS && SpeakerPrefix.split(reading.lines[i].text) == null
        // Yalnız uçtaki eski satırlar (görev altyazının altında ya da üstünde); ortadaki satır konuşmanın parçasıdır.
        // Üstteki eski satırın altındaki satır onun devamıysa ikisi aynı cümledir: üst satır kalır.
        for ((k, i) in live.withIndex()) {
            if (!old(i)) break
            if (k + 1 < live.size && Reading.continues(reading.lines[i].text, reading.lines[live[k + 1]].text)) break
            result[i] = true
        }
        for (i in live.asReversed()) if (old(i)) result[i] = true else break
        return result
    }

    fun reset() {
        rows.clear()
        newlySticky = emptyList()
    }
}
