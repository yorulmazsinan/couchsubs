// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Ekranın kenarındaki bildirim kartları (GTA 6: sağ altta telefona gelen mesajın önizlemesi, solda kayarak giren bildirim)
 * altyazı değildir, kendi yerinde çevrilir. Kullanıcı bildirimi (X, iki kişi): altyazı alanı "Tam ekran"ken bu kartlar
 * altyazı bloğu seçiliyordu (ortalanmış blok yokken en alttaki üç sözcüklü blok); çevirileri altyazının yerinde, ekranın
 * ortasında çiziliyor, art arda gelen kartlar orada üst üste toplanıyordu. Artık "Tam ekran" alanda ([isWholeScreen])
 * karenin bir yarısında kalan ve ortasından uzak blok ([isNotice]) altyazı bloğuna girmez ([Reading.subtitleBlock]);
 * bildirim olarak izlenir. Kayarak giren kartın kutusu her karede kayar: kutu [SETTLE_MS] boyunca yerinde durunca (kayma
 * bitti) bölgesi "auto-notice-<n>" ek alanı olur, çevirisi [RegionWatcher] ile özgün stilinde kendi yerinde görünür. Kart
 * sonra yeniden kayarsa son geçerli yer kalır; konumu belirsiz kart hiç çizilmez, asla ortaya çizilmez. Windows
 * (ScreenNotices.cs) ve Mac/iPhone (ScreenNotices.swift) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
 * fixtures/screen-notice.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası).
 */
class ScreenNotices {
    companion object {
        const val ID_PREFIX = "auto-notice-"
        /** Okunan alan karenin en az bu kadar genişliğini ve [TALL_AREA] kadar yüksekliğini kaplıyorsa "Tam ekran". */
        const val WIDE_AREA = 0.85
        const val TALL_AREA = 0.5
        /** Bildirim bloğunun yatay ortası karenin ortasından en az bu kadar uzaktır (blok ortayı geçmez). */
        const val SIDE_OFFSET = 0.2
        /** Kutu bu kadar süre yerinde durunca (kayma bitti) bildirimin bölgesi gönderilir. */
        const val SETTLE_MS = 400L
        /** Bu kadar görülmeyen bildirim ekrandan kalkmış sayılır. */
        const val FORGET_MS = 1500L
        /** Kutunun kenarları bundan az oynarsa yerinde duruyor sayılır. */
        const val MOVE_TOLERANCE = 0.006
        /** En çok bu kadar bildirim aynı anda kendi yerinde çevrilir. */
        const val MAX_COUNT = 3

        fun isWholeScreen(area: TextBox) = area.right - area.left >= WIDE_AREA && area.bottom - area.top >= TALL_AREA

        /** Kutu (karede) bir kenar bildirimi mi: karenin bir yarısında ve ortası karenin ortasından en az [SIDE_OFFSET] uzak. */
        fun isNotice(box: TextBox) = box.right > box.left && box.bottom > box.top &&
            (box.right <= 0.5 || box.left >= 0.5) && abs((box.left + box.right) / 2 - 0.5) >= SIDE_OFFSET

        /** Ek alan bir bildirim bölgesi mi. */
        fun isNotice(id: String) = id.startsWith(ID_PREFIX)

        /** Bölge: kutu ve her yanında pay (dikeyde satır boyunun %35'i, yatayda karenin %1'i), 0…1'e kırpılmış. */
        internal fun region(box: TextBox, line: Double) = CropRegion(
            top = max(0.0, box.top - 0.35 * line), bottom = min(1.0, box.bottom + 0.35 * line),
            left = max(0.0, box.left - 0.01), right = min(1.0, box.right + 0.01))

        /**
         * İki kutu aynı bildirim mi: karenin aynı yarısında ve dikeyde (yana kayan kart) ya da yatayda (yukarı kayan kart)
         * küçüğünün en az yarısı kadar örtüşüyor.
         */
        internal fun same(a: TextBox, b: TextBox): Boolean {
            if (((a.left + a.right) / 2 < 0.5) != ((b.left + b.right) / 2 < 0.5)) return false
            val vertical = min(a.bottom, b.bottom) - max(a.top, b.top)
            val horizontal = min(a.right, b.right) - max(a.left, b.left)
            val rows = vertical > 0 && vertical >= 0.5 * min(a.bottom - a.top, b.bottom - b.top)
            val columns = horizontal > 0 && horizontal >= 0.5 * min(a.right - a.left, b.right - b.left) &&
                max(a.top, b.top) - min(a.bottom, b.bottom) <= max(a.bottom - a.top, b.bottom - b.top)
            return rows || columns
        }

        internal fun moved(a: TextBox, b: TextBox) = abs(a.left - b.left) > MOVE_TOLERANCE || abs(a.top - b.top) > MOVE_TOLERANCE ||
            abs(a.right - b.right) > MOVE_TOLERANCE || abs(a.bottom - b.bottom) > MOVE_TOLERANCE

        private fun close(a: CropRegion, b: CropRegion) = abs(a.left - b.left) <= MOVE_TOLERANCE && abs(a.top - b.top) <= MOVE_TOLERANCE &&
            abs(a.right - b.right) <= MOVE_TOLERANCE && abs(a.bottom - b.bottom) <= MOVE_TOLERANCE
    }

    private class Track(val number: Int, var box: TextBox, var line: Double, var still: Long, var lastSeen: Long) {
        var region: CropRegion? = null
    }

    private val tracks = mutableListOf<Track>()
    private var counter = 0

    /** Şu an kendi yerinde okunan bildirim alanları. */
    var areas: List<ExtraArea> = emptyList()
        private set

    /**
     * Bu karenin bildirim blokları (satır kutuları karede). Alan listesi değiştiyse true. Bildirim yokken de her karede
     * çağrılır: görülmeyen bildirim [FORGET_MS] sonra kalkar.
     */
    fun observe(blocks: List<Reading>, time: Long): Boolean {
        val matched = mutableSetOf<Track>()
        for (block in blocks) {
            val box = block.box ?: continue
            if (!isNotice(box)) continue
            val line = block.lines.mapNotNull { it.box?.let { b -> b.bottom - b.top } }.minOrNull() ?: (box.bottom - box.top)
            val track = tracks.firstOrNull { it !in matched && same(it.box, box) }
            if (track == null) {
                counter++
                tracks.add(Track(counter, box, line, time, time).also { matched.add(it) })
            } else {
                if (moved(track.box, box)) track.still = time
                track.box = box
                track.line = line
                track.lastSeen = time
                matched.add(track)
            }
        }
        tracks.removeAll { time - it.lastSeen > FORGET_MS }
        for (track in tracks) {
            if (time - track.still < SETTLE_MS) continue
            val next = region(track.box, track.line)
            // Okuma kutusunun küçük oynaması bölgeyi değiştirmez (bölge değişirse bildirim yeniden okunur).
            val current = track.region
            if (current != null && close(current, next)) continue
            track.region = next
        }
        val next = tracks.mapNotNull { track ->
            track.region?.let { ExtraArea(id = ID_PREFIX + track.number, name = "Notice", region = it, auto = true) }
        }.take(MAX_COUNT)
        if (next == areas) return false
        areas = next
        return true
    }

    fun reset() {
        tracks.clear()
        areas = emptyList()
    }
}
