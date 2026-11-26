// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Altyazı kapısının eleme sayacı: okunan bir satır altyazı sayılmayınca (sahne yazısı, menü/mağaza satırı, menü açıklaması,
 * telefon, sabit blok) nedeni sayılır. Kullanıcı bildirimi (beta.103, iki kullanıcı, GTA 6: "bazı altyazıları kaçırıyor,
 * öncesinde iyiydi"): günlükte hangi kuralın hangi satırı ne sıklıkla attığı görünmüyordu. Her neden satırı sonuna o nedenin
 * bu oturumdaki sayısını taşır ("[bu nedenle 12. kez]"); dakikada en çok [PER_MINUTE] satır yazılır, aşan satırlar sayılır.
 * [WINDOW_MS] dolunca sonraki elemede son dakikanın neden başına sayısı tek özet satırı olarak yazılır. Yalnız metin
 * yazılır. Mac/iPhone (RejectTally.swift) ve Windows (RejectTally.cs) aynı biçim, aynı sınırlar.
 */
class RejectTally {
    private val total = HashMap<String, Int>()
    private val window = HashMap<String, Int>()
    private var windowStart: Long? = null
    private var written = 0
    private var suppressed = 0

    /**
     * Elemeyi sayar. [line]: bu eleme için yazılacak satır (tekrarı yazılmayacaksa null). Dönen satırlar sırayla günlüğe
     * yazılır: varsa önce son dakikanın özeti, sonra sayaçlı neden satırı.
     */
    @Synchronized
    fun note(reason: String, line: String?, now: Long): List<String> {
        val out = mutableListOf<String>()
        val start = windowStart
        if (start != null && now - start >= WINDOW_MS) {
            summaryLine()?.let { out += it }
            window.clear()
            written = 0
            suppressed = 0
            windowStart = now
        } else if (start == null) {
            windowStart = now
        }
        total[reason] = (total[reason] ?: 0) + 1
        window[reason] = (window[reason] ?: 0) + 1
        if (line != null) {
            if (written < PER_MINUTE) {
                written++
                out += "$line [bu nedenle ${total[reason]}. kez]"
            } else {
                suppressed++
            }
        }
        return out
    }

    /** Bu oturumda [reason] ile atılan satır sayısı. */
    @Synchronized
    fun count(reason: String): Int = total[reason] ?: 0

    @Synchronized
    fun reset() {
        total.clear()
        window.clear()
        windowStart = null
        written = 0
        suppressed = 0
    }

    private fun summaryLine(): String? {
        if (window.isEmpty()) return null
        val parts = window.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .map { "${it.key} ×${it.value}" }
        var line = "altyazı elemesi (son ${WINDOW_MS / 1000} sn): " + parts.joinToString("; ")
        if (suppressed > 0) line += "; sınır yüzünden yazılmayan $suppressed satır"
        return line
    }

    companion object {
        /** Özet aralığı (ms). */
        const val WINDOW_MS = 60_000L
        /** Bir dakikada en çok yazılan neden satırı. */
        const val PER_MINUTE = 20
    }
}
