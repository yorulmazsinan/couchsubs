// SPDX-License-Identifier: AGPL-3.0-only
// Xbox görüntü alıcısından okuma hattına kare aktarımı (#1308). Eskiden libwebrtc'nin görüntü alıcısı (VideoSink) her
// 66 ms'de bir okuma hattının bütün işini (altyazı kopyası, telefon araması, ekran yazısı örneklemesi, önizleme)
// libwebrtc'nin kendi iş parçacığında yapıyordu. EGL bağlamı olmadığı için kareler ~3 MB'lık bellek (I420)
// arabellekleridir; alıcı yavaşlayınca libwebrtc'nin sınırsız kare kuyruğu büyüyor, bellek 30 MB'tan 430 MB'a çıkıp
// uygulama 2-3 dakikada bir düşüyordu. Şimdi alıcı yalnız kareyi önceden ayrılmış üç arabellekten birine kopyalar ve
// döner; okuma hattı ayrı bir iş parçacığında yalnız en son kareyi işler (yetişemediği kare atlanır, bellek sabit).
// iPhone ve Mac'te aynı iş FrameMailbox ve XboxFramePipeStats'la yapılır (XboxStreamSession.swift).
package com.couchsubs.mobile.xbox

import com.couchsubs.mobile.remoteplay.ChromaPlanes
import com.couchsubs.mobile.remoteplay.VideoFrame
import java.nio.ByteBuffer
import java.util.Locale
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

/**
 * "En son kare kazanır" aktarımı: [offer] görüntü alıcısında çağrılır, kareyi kopyalayıp döner; [process] [executor]'da
 * tek tek, yalnız en son kareyle çağrılır. Arabellekler yeniden kullanılır: aynı anda en çok üç kare bellekte (biri
 * işlenen, biri bekleyen, biri doldurulan).
 */
internal class XboxFrameHandoff(
    private val executor: Executor,
    private val stats: XboxFramePipeStats = XboxFramePipeStats(),
    private val process: (VideoFrame) -> Unit,
) {
    /** Kopyalanmış kare: sıkı paketlenmiş Y (width × height), U ve V ((width+1)/2 × (height+1)/2). */
    internal class Slot {
        var y: ByteBuffer = ByteBuffer.allocateDirect(0); private set
        var u: ByteBuffer = ByteBuffer.allocateDirect(0); private set
        var v: ByteBuffer = ByteBuffer.allocateDirect(0); private set
        var width = 0; private set
        var height = 0; private set

        fun fill(width: Int, height: Int, srcY: ByteBuffer, strideY: Int, srcU: ByteBuffer, strideU: Int, srcV: ByteBuffer, strideV: Int) {
            val cw = (width + 1) / 2
            val ch = (height + 1) / 2
            if (y.capacity() != width * height) y = ByteBuffer.allocateDirect(width * height)
            if (u.capacity() != cw * ch) u = ByteBuffer.allocateDirect(cw * ch)
            if (v.capacity() != cw * ch) v = ByteBuffer.allocateDirect(cw * ch)
            this.width = width
            this.height = height
            copyPlane(srcY, strideY, width, height, y)
            copyPlane(srcU, strideU, cw, ch, u)
            copyPlane(srcV, strideV, cw, ch, v)
        }

        fun frame(): VideoFrame = VideoFrame(y, width, height, width, chroma = ChromaPlanes(u, v, (width + 1) / 2))

        private fun copyPlane(src: ByteBuffer, stride: Int, width: Int, height: Int, dst: ByteBuffer) {
            dst.clear()
            val source = src.duplicate()
            if (stride == width) {
                source.position(0).limit(width * height)
                dst.put(source)
            } else {
                for (row in 0 until height) {
                    val at = row * stride
                    source.limit(at + width).position(at)
                    dst.put(source)
                    source.limit(source.capacity())
                }
            }
            dst.clear()
        }
    }

    private val lock = Any()
    private val free = ArrayDeque<Slot>()
    private var pending: Slot? = null
    private var scheduled = false
    private var closed = false

    /** Görüntü alıcısında: kareyi kopyalar ve döner. Kapandıysa false. */
    fun offer(width: Int, height: Int, srcY: ByteBuffer, strideY: Int, srcU: ByteBuffer, strideU: Int, srcV: ByteBuffer, strideV: Int): Boolean {
        val slot = synchronized(lock) {
            if (closed) return false
            free.removeFirstOrNull() ?: Slot()
        }
        slot.fill(width, height, srcY, strideY, srcU, strideU, srcV, strideV)
        val schedule = synchronized(lock) {
            if (closed) return false
            pending?.let {
                free.addLast(it)
                stats.dropped()
            }
            pending = slot
            stats.handed()
            if (scheduled) false else true.also { scheduled = true }
        }
        if (schedule) {
            try {
                executor.execute(::drain)
            } catch (error: RejectedExecutionException) {
                synchronized(lock) { scheduled = false }
                return false
            }
        }
        return true
    }

    private fun drain() {
        while (true) {
            val slot = synchronized(lock) {
                val next = pending
                pending = null
                if (next == null || closed) {
                    next?.let(free::addLast)
                    scheduled = false
                    return
                }
                next
            }
            val started = System.nanoTime()
            try {
                process(slot.frame())
            } catch (error: Exception) {
                // Tek karenin hatası okumayı durdurmaz; sonraki kare işlenir.
            } finally {
                stats.processed(System.nanoTime() - started)
                synchronized(lock) { free.addLast(slot) }
            }
        }
    }

    /** Bağlantı bitti: bekleyen kare atılır (yeni bağlantının ilk karesinden önce eski kare işlenmez). */
    fun clear() {
        synchronized(lock) {
            pending?.let(free::addLast)
            pending = null
        }
    }

    /** Oturum kapandı: bir daha kare işlenmez, arabellekler bırakılır. */
    fun close() {
        synchronized(lock) {
            closed = true
            pending = null
            free.clear()
        }
    }

    /** Ayrılmış kare arabelleği sayısı (test: en çok üç). */
    internal fun slotsAllocated(): Int = synchronized(lock) { free.size + (if (pending != null) 1 else 0) }
}

/**
 * Görüntü alıcısı ve kare işleme süreleri (10 sn'de bir günlüğe yazılır, #1308): alıcı hızlı dönüyor mu, işlenemeyip
 * atlanan kare var mı, bellek büyüyor mu. iPhone/Mac'teki XboxFramePipeStats ile aynı satır.
 */
class XboxFramePipeStats {
    private var arrived = 0L
    private var sinkNanos = 0L
    private var sinkMaxNanos = 0L
    private var handed = 0L
    private var dropped = 0L
    private var processed = 0L
    private var processNanos = 0L
    private var processMaxNanos = 0L
    /**
     * Kare onayı döngüsünün turları arasındaki süre: döngü takılırsa Xbox onay alamayıp görüntü kanalını kapatır.
     * Windows'taki oynatıcının "onay en uzun aralık" alanıyla aynı.
     */
    private var ackTicks = 0L
    private var ackMaxGapNanos = 0L
    private var ackLate = 0L

    /** Alıcıya gelen her kare (aralık dolmadığı için atlananlar da) ve alıcıda geçen süre. */
    @Synchronized fun sink(nanos: Long) {
        arrived++
        sinkNanos += nanos
        if (nanos > sinkMaxNanos) sinkMaxNanos = nanos
    }

    @Synchronized fun handed() { handed++ }

    /** Okuma hattı yetişemedi: bekleyen kare yenisiyle değişti. */
    @Synchronized fun dropped() { dropped++ }

    @Synchronized fun processed(nanos: Long) {
        processed++
        processNanos += nanos
        if (nanos > processMaxNanos) processMaxNanos = nanos
    }

    /** Kare onayı döngüsünün bir turu; [gapNanos] önceki turdan bu yana geçen süre. */
    @Synchronized fun ackTick(gapNanos: Long) {
        ackTicks++
        if (gapNanos > ackMaxGapNanos) ackMaxGapNanos = gapNanos
        if (gapNanos > LATE_ACK_NANOS) ackLate++
    }

    /** Pencerenin satırı ("kare hattı (10 sn): ..."); sayaçlar sıfırlanır. Hiç kare gelmediyse null. */
    @Synchronized fun take(windowMs: Long, memory: String): String? {
        val line = if (arrived == 0L) null else line(windowMs, memory)
        arrived = 0; sinkNanos = 0; sinkMaxNanos = 0; handed = 0; dropped = 0; processed = 0; processNanos = 0; processMaxNanos = 0
        ackTicks = 0; ackMaxGapNanos = 0; ackLate = 0
        return line
    }

    private fun line(windowMs: Long, memory: String): String {
        fun ms(nanos: Long) = String.format(Locale.ROOT, "%.1f", nanos / 1_000_000.0)
        val sinkAvg = if (arrived > 0) sinkNanos / arrived else 0
        val processAvg = if (processed > 0) processNanos / processed else 0
        val acks = if (ackTicks > 0) "onay aralığı en çok ${ms(ackMaxGapNanos)} ms, 250 ms üstü $ackLate; " else ""
        return "kare hattı (${windowMs / 1000} sn): gelen $arrived, aktarılan $handed, işlenen $processed, atlanan $dropped; " +
            "alıcı ort ${ms(sinkAvg)} ms, en çok ${ms(sinkMaxNanos)} ms; işleme ort ${ms(processAvg)} ms, en çok ${ms(processMaxNanos)} ms; $acks$memory"
    }

    companion object {
        const val WINDOW_MS = 10_000L
        /** Bu süreyi aşan onay aralığı "geç" sayılır (Windows oynatıcısındaki 250 ms). */
        const val LATE_ACK_NANOS = 250_000_000L
    }
}

/**
 * Xbox görüntü kanalını (input) ya da WebRTC bağlantısını kapattığında akışın durumu (#1252, #1308): son kare ve son
 * kare onayı ne kadar önceydi. Onay uzun süredir gitmiyorsa kapanmanın nedeni onaydır; kare uzun süredir gelmiyorsa ağ.
 * iPhone/Mac'teki XboxCloseContext ile aynı satır.
 */
object XboxCloseContext {
    fun describe(nowMs: Long, lastFrameAt: Long, lastAckAt: Long, acksSent: Long): String {
        fun ago(at: Long) = String.format(Locale.ROOT, "%.1f sn önce", (nowMs - at).coerceAtLeast(0) / 1000.0)
        val frame = if (lastFrameAt > 0) "son kare ${ago(lastFrameAt)}" else "kare gelmedi"
        val ack = if (lastAckAt > 0) "son onay ${ago(lastAckAt)}, onay $acksSent" else "onay gönderilmedi"
        return "$frame, $ack"
    }
}
