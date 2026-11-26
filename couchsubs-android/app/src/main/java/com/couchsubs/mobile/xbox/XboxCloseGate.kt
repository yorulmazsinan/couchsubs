// SPDX-License-Identifier: AGPL-3.0-only
// Xbox oturumlarının kapanış sırası (süreç genelinde). "Yeniden bağlan" ya da öne dönüşte eski oturum durdurulup hemen
// yenisi açılıyordu: eski oturumun kapatma isteği (DELETE) ve WebRTC kapanışı daha bitmeden yeni oturumun `play` isteği
// Xbox'a gidiyordu. Xbox eski oturumu açık sayınca yeni oturum düşüyor, "uzaktan yürütme başladı/durduruldu" art arda
// geliyor ve kullanıcılar Xbox'ı yeniden başlatmak zorunda kalıyordu. Windows'ta oturumlar zaten sırayla açılıyor
// (XboxStreamSession.Start → RunAfterAsync); burada da yeni oturum önceki oturumların kapanışını (en çok [WAIT_LIMIT_MS])
// bekler. Kapatılamayan oturum kimlikleri de süreç genelinde tutulur: oturum nesnesi atıldıktan sonra açılan yeni oturum
// onları önce kapatır (eskiden kimlik atılan nesneyle kayboluyordu). iPhone/Mac'teki XboxCloseGate ile aynı kurallar.
package com.couchsubs.mobile.xbox

import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class XboxCloseGate {
    /** Süren bir kapanış; [done] kapanış bitince (ya da başlatılamazsa) çağrılır. */
    inner class Closing internal constructor() {
        internal val latch = CountDownLatch(1)

        fun done() {
            latch.countDown()
            synchronized(lock) { pending.remove(this) }
        }
    }

    private val lock = Any()
    private val pending = LinkedHashSet<Closing>()
    private val stale = ArrayList<String>()

    /** Oturum kapanmaya başladı. */
    fun begin(): Closing = Closing().also { synchronized(lock) { pending += it } }

    val pendingCount: Int get() = synchronized(lock) { pending.size }

    /**
     * Süren kapanışlar biter ya da [limitMs] dolar. Dönen değer: beklenen kapanış sayısı, geçen süre ve süre doldu mu
     * (bekleyen yoksa null).
     */
    fun waitForPending(limitMs: Long = WAIT_LIMIT_MS): XboxCloseWait? {
        val closings = synchronized(lock) { pending.toList() }
        if (closings.isEmpty()) return null
        val started = System.nanoTime()
        val deadline = started + TimeUnit.MILLISECONDS.toNanos(limitMs)
        var finished = true
        for (closing in closings) {
            val left = (deadline - System.nanoTime()).coerceAtLeast(0)
            if (!closing.latch.await(left, TimeUnit.NANOSECONDS)) {
                finished = false
                break
            }
        }
        return XboxCloseWait(closings.size, TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started), !finished)
    }

    /** Kapatılamayan oturum: sonra açılan ilk oturum `play`dan önce yeniden kapatır. */
    fun addStale(id: String) = synchronized(lock) { if (id !in stale) stale += id }

    /** Kapatılmayı bekleyen eski oturumlar (alınınca liste boşalır). */
    fun takeStale(): List<String> = synchronized(lock) { stale.toList().also { stale.clear() } }

    companion object {
        /** Yeni oturum önceki oturumların kapanışını en çok bu kadar bekler (Windows'taki RunAfterAsync gibi 10 sn). */
        const val WAIT_LIMIT_MS = 10_000L
        val shared = XboxCloseGate()
    }
}

/** Önceki oturumların kapanışının beklenmesi (günlük satırı için). */
data class XboxCloseWait(val sessions: Int, val elapsedMs: Long, val timedOut: Boolean) {
    val line: String
        get() {
            val seconds = String.format(Locale.ROOT, "%.1f", elapsedMs / 1000.0)
            return if (timedOut) "önceki oturumun kapanması $seconds sn'de bitmedi ($sessions oturum); yeni oturum yine açılıyor"
            else "önceki oturumun kapanması beklendi ($sessions oturum, $seconds sn)"
        }
}
