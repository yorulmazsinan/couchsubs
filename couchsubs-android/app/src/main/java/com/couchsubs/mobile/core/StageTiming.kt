// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Ek alan turunun ve kare iş parçacığının aşama süreleri; [PERIOD_MS]'de bir tek günlük satırı. Altyazı ya da telefon
 * çevirisi geç kalınca hangi işin (okuma, çizim ölçümü, telefon izleme, kare kopyası) zaman aldığı günlükte görünsün diye
 * (beta.103: "telefon mesajları yavaş, altyazı gecikiyor"). Mac/iPhone StageTiming.swift ve Windows StageTiming.cs aynı
 * biçim.
 */
class StageTiming(private val periodMs: Long = PERIOD_MS) {
    private class Stat(var count: Int = 0, var totalNanos: Long = 0, var maxNanos: Long = 0)

    private val stats = LinkedHashMap<String, Stat>()
    private var since: Long? = null

    /** [stage] bir kez [nanos] sürdü. */
    @Synchronized
    fun add(stage: String, nanos: Long) {
        val stat = stats.getOrPut(stage) { Stat() }
        stat.count++
        stat.totalNanos += maxOf(0L, nanos)
        stat.maxNanos = maxOf(stat.maxNanos, nanos)
    }

    /** [block]'u çalıştırıp süresini [stage]'e ekler. */
    inline fun <T> measure(stage: String, block: () -> T): T {
        val start = System.nanoTime()
        try {
            return block()
        } finally {
            add(stage, System.nanoTime() - start)
        }
    }

    /**
     * Süre dolduysa ([now], ms) satır ve sayaçlar sıfırlanır; dolmadıysa ya da ölçüm yoksa null. İlk çağrı süreyi başlatır.
     */
    @Synchronized
    fun report(now: Long): String? {
        val start = since ?: run {
            since = now
            return null
        }
        if (now >= start && now - start < periodMs) return null
        since = now
        if (stats.isEmpty()) return null
        val line = format((now - start).coerceAtLeast(0), stats.map { (stage, s) -> Triple(stage, s.count, s.totalNanos to s.maxNanos) })
        stats.clear()
        return line
    }

    companion object {
        const val PERIOD_MS = 30_000L

        /** "aşama süreleri (30 sn): okuma 12× ort 85,0 en çok 140,2 ms; çizim 4× ort 30,1 en çok 52,0 ms". */
        fun format(spanMs: Long, stages: List<Triple<String, Int, Pair<Long, Long>>>): String =
            "aşama süreleri (${spanMs / 1000} sn): " + stages.joinToString("; ") { (stage, count, nanos) ->
                "$stage $count× ort ${ms(nanos.first / maxOf(1, count))} en çok ${ms(nanos.second)} ms"
            }

        private fun ms(nanos: Long): String {
            val tenths = (nanos + 50_000) / 100_000
            return "${tenths / 10},${tenths % 10}"
        }
    }
}
