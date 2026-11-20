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

        private fun within(a: CropRegion, b: CropRegion, tolerance: Double) =
            abs(a.top - b.top) <= tolerance && abs(a.bottom - b.bottom) <= tolerance &&
                abs(a.left - b.left) <= tolerance * 2 && abs(a.right - b.right) <= tolerance * 2
    }

    private class Track(val text: String, val since: Long, var lastSeen: Long, var box: TextBox)

    private val tracks = mutableListOf<Track>()

    /** Görevin karedeki bölgesi; görev yoksa null. */
    var region: CropRegion? = null
        private set

    /** Altyazı bloğundan çıkarılan satırlar (yeri [area]'ya oranla). Görev bölgesi değiştiyse true. */
    fun observe(removed: List<TextLine>, area: TextBox, time: Long): Boolean {
        for (line in removed) {
            val box = line.box ?: continue
            if (SpeakerPrefix.split(line.text) != null) continue
            val text = TextMatch.normalize(line.text)
            if (text.length < 3) continue
            val placed = box.placedIn(area)
            val track = tracks.firstOrNull { TextMatch.isSimilar(it.text, text) }
            if (track != null) {
                track.lastSeen = time
                track.box = placed
            } else {
                tracks.add(Track(text, time, time, placed))
            }
        }
        tracks.removeAll { time - it.lastSeen > FORGET_MS }
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
        region = null
    }
}
