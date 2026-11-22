// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * CouchSubs'ın gösterdiği çeviriler: okunan karede kendi altyazımız varsa yeni satır sayılmasın. Kullanıcı bildirimi (X,
 * capture card + OBS ile yayın): görüntü kaynağı OBS'in Program/Önizleme projektörüyken karede CouchSubs'ın OBS katmanı
 * (tarayıcı kaynağı) da vardır. Türkçe altyazı İngilizce satırın üstüne düşünce yazı tanıma onu okuyor, hat onu yeni satır
 * sanıp yeniden çeviriyor, sonra İngilizce yeniden görünüp eski çeviri geri geliyordu; altyazı yanıp sönüyordu.
 *
 * Kural: gösterilen çeviri ekranda kaldıkça (ve kalktıktan sonra [TEXT_GRACE_MS]) okunan bir satır ona benziyorsa (yazı
 * tanımanın Türkçe harfleri düz harfe çevirdiği hâliyle, bkz. [PoolFilter.fold]) ya da onun bir parçasıysa "kendi
 * altyazısı" sayılır, atılır. Kaynağına (İngilizce satıra) benzeyen okuma hiçbir zaman atılmaz. Kendi altyazısı bir kez
 * metinden tanınınca okunduğu yer öğrenilir; çeviri ekrandayken o dikdörtgene düşen öbür satırlar da atılır. Telefonda
 * OBS yolu yoktur; karede bizim altyazımız olmadığından süzgeç bir şey atmaz (zararsız). Mac/iPhone
 * (OwnSubtitles.swift) ve Windows (OwnSubtitles.cs) aynı kuralları uygular. İş parçacığı güvenlidir.
 */
class OwnSubtitles(private val clock: () -> Long = monotonicClock) {
    companion object {
        /** Çeviri kalktıktan sonra metin eşleşmesi bu kadar süre geçerli. */
        const val TEXT_GRACE_MS = 3000L
        /** Öğrenilen yer kuralı çeviri kalktıktan sonra bu kadar süre geçerli. */
        const val PLACE_GRACE_MS = 500L
        internal const val SIMILARITY = 0.8
        internal const val PART_SHARE = 0.8
        internal const val PART_WORDS = 2
        internal const val MINIMUM_LETTERS = 4
        internal const val REMEMBERED = 6

        /**
         * Kendi altyazımız İngilizce satırın yerine mi düştü (örtme ya da üst üste binen sabit yer): öyleyse altyazı yalnız
         * bizim çevirimiz okunduğu için "kalktı" sayılmaz. Yeri bilinmeyen okumada da öyle sayılır.
         */
        fun coversLine(own: List<TextLine>, line: TextBox?): Boolean {
            if (line == null) return true
            return own.any { item ->
                val box = item.box ?: return@any true
                val overlap = minOf(box.bottom, line.bottom) - maxOf(box.top, line.top)
                val height = minOf(box.bottom - box.top, line.bottom - line.top)
                height > 0 && overlap >= 0.5 * height
            }
        }

        internal fun resembles(probe: List<String>, source: List<String>, sourceText: String): Boolean {
            if (probe.isEmpty() || source.isEmpty()) return false
            if (TextMatch.isSimilar(probe.joinToString(" "), sourceText, SIMILARITY)) return true
            val found = probe.count { word -> source.any { PoolFilter.isClose(word, it) } }
            return found >= 0.6 * probe.size
        }

        internal fun covers(area: TextBox, box: TextBox): Boolean {
            val pad = 0.01
            val w = minOf(box.right, area.right + pad) - maxOf(box.left, area.left - pad)
            val h = minOf(box.bottom, area.bottom + pad) - maxOf(box.top, area.top - pad)
            val size = (box.right - box.left) * (box.bottom - box.top)
            return w > 0 && h > 0 && size > 0 && w * h >= 0.7 * size
        }
    }

    private class Shown(val words: List<String>, val source: List<String>, var until: Long) {
        val text = words.joinToString(" ")
        val sourceText = source.joinToString(" ")
        var seen: TextBox? = null
    }

    private val lock = Any()
    private val shown = mutableListOf<Shown>()

    /** Çeviri ekrana gitti; [durationMs]: ekranda kalma süresi. Yer karede okunduğu yerden öğrenilir. */
    fun record(translation: String, source: String, durationMs: Int) {
        val words = PoolFilter.fold(IconText.plain(translation))
        if (words.isEmpty()) return
        val sourceWords = PoolFilter.fold(IconText.plain(source))
        val time = clock()
        synchronized(lock) {
            shown.add(Shown(words, sourceWords, time + durationMs))
            while (shown.size > REMEMBERED) shown.removeAt(0)
        }
    }

    /** Ekrandaki çeviri kaldırıldı. */
    fun cleared() {
        val time = clock()
        synchronized(lock) { shown.forEach { it.until = minOf(it.until, time) } }
    }

    fun reset(): Unit = synchronized(lock) { shown.clear() }

    /** [text] ekrandaki (ya da az önce kalkan) bir çevirimize benziyor ya da onun parçası. */
    fun isOwn(text: String): Boolean {
        val probe = PoolFilter.fold(IconText.plain(text))
        val time = clock()
        return synchronized(lock) { matchIndex(probe, time) != null }
    }

    /** Okumanın kendi altyazımız olan satırları ayrılmış hali. [place]: okumanın karedeki yeri; ikinci değerin kutuları kareye oranla. */
    fun split(reading: Reading, place: TextBox = TextBox(0.0, 0.0, 1.0, 1.0)): Pair<Reading, List<TextLine>> {
        val time = clock()
        synchronized(lock) {
            if (shown.none { time <= it.until + TEXT_GRACE_MS }) return reading to emptyList()
            val keep = BooleanArray(reading.lines.size) { true }
            val own = mutableListOf<TextLine>()
            reading.lines.forEachIndexed { index, line ->
                val match = matchIndex(PoolFilter.fold(IconText.plain(line.text)), time) ?: return@forEachIndexed
                keep[index] = false
                val box = line.box?.placedIn(place)
                if (box != null) shown[match].seen = shown[match].seen?.union(box) ?: box
                own.add(line.copy(box = box))
            }
            reading.lines.forEachIndexed { index, line ->
                if (!keep[index]) return@forEachIndexed
                val box = line.box?.placedIn(place) ?: return@forEachIndexed
                val probe = PoolFilter.fold(IconText.plain(line.text))
                val inside = shown.any { entry ->
                    val seen = entry.seen
                    time <= entry.until + PLACE_GRACE_MS && seen != null && covers(seen, box) &&
                        !resembles(probe, entry.source, entry.sourceText)
                }
                if (!inside) return@forEachIndexed
                keep[index] = false
                own.add(line.copy(box = box))
            }
            if (own.isEmpty()) return reading to emptyList()
            return Reading(reading.lines.filterIndexed { index, _ -> keep[index] }) to own
        }
    }

    private fun matchIndex(probe: List<String>, time: Long): Int? {
        val joined = probe.joinToString(" ")
        if (joined.count { it != ' ' } < MINIMUM_LETTERS) return null
        for (index in shown.indices.reversed()) {
            val entry = shown[index]
            if (time > entry.until + TEXT_GRACE_MS) continue
            if (resembles(probe, entry.source, entry.sourceText)) continue
            if (TextMatch.isSimilar(joined, entry.text, SIMILARITY)) return index
            if (probe.size < PART_WORDS) continue
            val found = probe.filter { word -> entry.words.any { PoolFilter.isClose(word, it) } }
            val foreign = found.count { word -> entry.source.none { PoolFilter.isClose(word, it) } }
            if (found.size >= PART_SHARE * probe.size && foreign >= PART_WORDS) return index
        }
        return null
    }
}
