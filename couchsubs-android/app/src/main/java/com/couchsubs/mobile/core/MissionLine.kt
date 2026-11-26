// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * Görev/hedef satırı altyazıdan ayrı, kendi yerinde: altyazı hattının altyazı bloğundan çıkardığı satırlardan
 * ([StickyRows.removed]) konuşan adı taşımayan ve en az [SETTLE_MS] ekranda kalan satırlar görevdir. Bölgesi
 * "auto-mission" ek alanı olarak sürekli okunur, çevirisi özgün stilinde kendi yerinde görünür ([RegionWatcher]). Görev
 * yerinde durdukça bölge değişmez: altyazı her değiştiğinde görev kutusu yeniden gönderilmez, yanıp sönmez. Windows
 * (MissionLine.cs) ve Mac/iPhone (MissionLine.swift) aynı kuralları uygular.
 */
class MissionLine {
    companion object {
        const val AREA_ID = "auto-mission"
        /** Satır bu kadar ekranda kalınca görev sayılır. */
        const val SETTLE_MS = 3000L
        /** Bu kadar görülmeyen satır ekrandan kalkmış sayılır. */
        const val FORGET_MS = 1500L
        /**
         * Görev çevirisinin kutusu: koyu kehribar zemin, beyaz yazı. Kullanıcı bildirimi (beta.100): görev yazısının
         * Türkçesi altyazıyla ve öbür ekran yazılarıyla aynı görünüyor, hangisinin görev olduğu anlaşılmıyordu. TV ve
         * önizlemeler bu zemini öğenin yüzeyinden çizer (Mac/iPhone: MissionLine.style, Windows: MissionLine.Style).
         */
        val STYLE = TextSurface("#7A4E00", "#FFFFFF")
        /** Görev çevirisinin başındaki hedef imi (yaygın yazı tiplerinde bulunan dolu üçgen; emoji değildir). */
        const val MARKER = "\u25BA "

        /**
         * Satır (kutusu karede) görev olabilir mi. Görev satırı ortadadır ve sözcüklerden oluşur; ekranın bir yanındaki HUD
         * yazısı ([ScreenNotices.isNotice]: GTA 6'da arama kartının yanındaki küçük yazı) ya da okuma kırıntısı
         * ([OcrNoise.isCrumb]) görev sayılıp kendi yerinde çevrilmez. Kullanıcı bildirimi (GitHub #882, GTA 6): telefon
         * araması sürerken arama kartının yanında "kulaklı ar." diye küçük bir çeviri kutusu çıkıyordu.
         */
        fun isCandidate(text: String, box: TextBox) = !ScreenNotices.isNotice(box) && !OcrNoise.isCrumb(text)

        /** İki kutu satır boyunun çeyreğinden az oynamış mı. */
        internal fun near(a: TextBox, b: TextBox): Boolean {
            val tolerance = 0.25 * minOf(a.bottom - a.top, b.bottom - b.top)
            return abs(a.top - b.top) <= tolerance && abs(a.bottom - b.bottom) <= tolerance &&
                abs(a.left - b.left) <= tolerance * 2 && abs(a.right - b.right) <= tolerance * 2
        }

        private fun within(a: CropRegion, b: CropRegion, tolerance: Double) =
            abs(a.top - b.top) <= tolerance && abs(a.bottom - b.bottom) <= tolerance &&
                abs(a.left - b.left) <= tolerance * 2 && abs(a.right - b.right) <= tolerance * 2
    }

    private class Track(val text: String, val source: String, val since: Long, var lastSeen: Long, var box: TextBox)

    private val tracks = mutableListOf<Track>()

    /** Görevin karedeki bölgesi; görev yoksa null. */
    var region: CropRegion? = null
        private set

    /**
     * Ekranda duran görev satırlarının karedeki yeri ([SETTLE_MS] dolmadan da): TV ve OBS sayfası altyazı kutusunu bunun
     * üstüne taşır, kutu oyundaki görev satırını örtmez. Kullanıcı bildirimi (X, beta.100–104, GTA 6): "Örtsün"de iki
     * satırlık Türkçe İngilizce satırın ortasına göre büyüyor, alttaki görev satırının ("Get in the speedboat") üst yarısını
     * kapatıyordu. Okuma kutusunun küçük oynaması değer değiştirmez. Mac/iPhone ve Windows aynı.
     */
    var clearance: TextBox? = null
        private set

    /**
     * Son [observe]'da görev sayılmadan ([SETTLE_MS] dolmadan) ekrandan kalkan satırlar, özgün metinleriyle: altyazıdan da
     * çıkarıldıkları için hiç çevrilmediler; altyazı günlüğüne bir kez yazılır (Mac/iPhone ve Windows aynı).
     */
    var dropped: List<String> = emptyList()
        private set

    /** Altyazı bloğundan çıkarılan satırlar (yeri [area]'ya oranla). Görev bölgesi değiştiyse true. */
    fun observe(removed: List<TextLine>, area: TextBox, time: Long): Boolean {
        for (line in removed) {
            val box = line.box ?: continue
            if (SpeakerPrefix.split(line.text) != null) continue
            val text = TextMatch.normalize(line.text)
            if (text.length < 3) continue
            val placed = box.placedIn(area)
            if (!isCandidate(line.text, placed)) continue
            val track = tracks.firstOrNull { TextMatch.isSimilar(it.text, text) }
            if (track != null) {
                track.lastSeen = time
                track.box = placed
            } else {
                tracks.add(Track(text, line.text, time, time, placed))
            }
        }
        dropped = tracks.filter { time - it.lastSeen > FORGET_MS && it.lastSeen - it.since < SETTLE_MS }.map { it.source }
        tracks.removeAll { time - it.lastSeen > FORGET_MS }
        val shown = tracks.firstOrNull()?.let { first -> tracks.drop(1).fold(first.box) { total, track -> total.union(track.box) } }
        val current = clearance
        if (shown == null || current == null || !near(shown, current)) clearance = shown
        val settled = tracks.filter { time - it.since >= SETTLE_MS }
        var next: CropRegion? = null
        if (settled.isNotEmpty()) {
            val union = settled.drop(1).fold(settled[0].box) { total, track -> total.union(track.box) }
            val line = settled.minOf { it.box.bottom - it.box.top }
            var candidate = CropRegion(
                top = maxOf(0.0, union.top - 0.35 * line), bottom = minOf(1.0, union.bottom + 0.35 * line),
                left = maxOf(0.0, union.left - 0.01), right = minOf(1.0, union.right + 0.01),
            )
            // Okuma kutusunun küçük oynaması bölgeyi değiştirmez (bölge değişirse görev yeniden okunur).
            region?.let { current -> if (within(candidate, current, line * 0.5)) candidate = current }
            next = candidate
        }
        if (next == region) return false
        region = next
        return true
    }

    fun reset() {
        tracks.clear()
        dropped = emptyList()
        region = null
        clearance = null
    }
}
