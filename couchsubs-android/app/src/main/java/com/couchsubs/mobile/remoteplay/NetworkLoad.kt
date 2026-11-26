// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

/**
 * PS5 aramasının ağa bindirdiği yük (Mac/iPhone `SweepPacing`, Windows `SweepPacing` ve yerel kütüphanedeki döngü
 * (couchsubs-jni.c) aynı kural).
 *
 * #1366: çeviri başlayınca evdeki bütün cihazların Wi-Fi'ı kopuyordu. Ağ taraması /24'ün 254 adresine yarım saniyede bir,
 * 3 sn boyunca aralıksız paket gönderiyordu: bir taramada ~1500 paket, her turda birkaç milisaniyede 254 paket ve boştaki her
 * adres için telefonun ARP genel yayını. Artık tarama yalnız iki tur gönderir ve paketler arasında 4 ms beklenir (en çok
 * ~250 paket/sn); tek adrese soru eskisi gibi yarım saniyede bir gider.
 */
object SweepPacing {
    /** Bu sayıdan çok hedef "ağ taraması"dır. */
    const val SWEEP_MIN_TARGETS = 8
    /** Taramada iki paket arası. */
    const val PACE_MS = 4
    /** Taramada hedeflerin hepsine kaç tur gönderilir. */
    const val SWEEP_ROUNDS = 2
    private const val ROUND_MS = 500

    fun isSweep(targetCount: Int) = targetCount > SWEEP_MIN_TARGETS

    /** [round] (0'dan) turunda hedeflere paket gider mi. */
    fun sendsInRound(round: Int, targetCount: Int) = !isSweep(targetCount) || round < SWEEP_ROUNDS

    /**
     * Yerel döngünün [timeoutMs] içinde kaç paket göndereceği (günlükteki sayım için; döngü couchsubs-jni.c'de, aynı kural):
     * birkaç adrese her yarım saniyede bir; taramada iki tur, paketler arası [PACE_MS] (süre dolunca gönderim kesilir).
     */
    fun plannedPackets(targetCount: Int, timeoutMs: Int): Int = when {
        targetCount <= 0 -> 0
        !isSweep(targetCount) -> targetCount * maxOf(1, (timeoutMs + ROUND_MS - 1) / ROUND_MS)
        else -> minOf(targetCount * SWEEP_ROUNDS, maxOf(targetCount, timeoutMs / PACE_MS))
    }
}

/**
 * PS5 aramalarının ve yeniden denemelerin sayacı: dakikada en çok bir satır günlüğe yazılır, böylece kullanıcı günlüğünde ağa
 * ne kadar yük bindiği görünür ("Ağ yükü (son 60 sn): PS5 ağ taraması 1 kez, 508 paket; ..."). İlk olay hemen yazılır,
 * sonrakiler biriktirilip dakikası dolunca tek satırda yazılır. Mac/iPhone ve Windows `NetworkLoad` ile aynı.
 */
class NetworkLoad(private val write: (String) -> Unit) {
    companion object {
        const val INTERVAL_MS = 60_000L
        val shared = NetworkLoad { line ->
            runCatching { android.util.Log.i("CouchSubsSession", line) }
        }

        fun line(seconds: Long, sweeps: Int, sweepPackets: Int, queries: Int, queryPackets: Int, retries: Int) =
            "Ağ yükü (son $seconds sn): PS5 ağ taraması $sweeps kez, $sweepPackets paket; tek adres sorgusu $queries kez, " +
                "$queryPackets paket; PS5'e yeniden bağlanma $retries"
    }

    private val lock = Any()
    private var sweeps = 0
    private var sweepPackets = 0
    private var queries = 0
    private var queryPackets = 0
    private var retries = 0
    private var windowStart: Long? = null
    private var lastLine: Long? = null

    /** Bir PS5 araması bitti: [sweep] ağ taraması mı, [packets] kaç paket gitti. */
    fun discovery(sweep: Boolean, packets: Int, nowMs: Long = System.currentTimeMillis()) = record(nowMs) {
        if (sweep) { sweeps++; sweepPackets += packets } else { queries++; queryPackets += packets }
    }

    /** PS5 oturumu yeniden denendi. */
    fun retry(nowMs: Long = System.currentTimeMillis()) = record(nowMs) { retries++ }

    private fun record(nowMs: Long, change: () -> Unit) {
        val text = synchronized(lock) {
            if (windowStart == null) windowStart = nowMs
            change()
            val last = lastLine
            if (last != null && nowMs - last < INTERVAL_MS) return
            val seconds = maxOf(0L, Math.round((nowMs - (windowStart ?: nowMs)) / 1000.0))
            line(seconds, sweeps, sweepPackets, queries, queryPackets, retries).also {
                sweeps = 0; sweepPackets = 0; queries = 0; queryPackets = 0; retries = 0
                lastLine = nowMs
                windowStart = null
            }
        }
        write(text)
    }
}
