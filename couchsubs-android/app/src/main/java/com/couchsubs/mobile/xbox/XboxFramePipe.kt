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
        /** Kaynak karenin düzeni ([XboxFrameHandoff.describeSource]); düzen değişmedikçe aynı metin. */
        var source = ""; private set
        private var sourceKey = 0L

        fun fill(width: Int, height: Int, srcY: ByteBuffer, strideY: Int, srcU: ByteBuffer, strideU: Int, srcV: ByteBuffer, strideV: Int) {
            val cw = (width + 1) / 2
            val ch = (height + 1) / 2
            if (y.capacity() != width * height) y = ByteBuffer.allocateDirect(width * height)
            if (u.capacity() != cw * ch) u = ByteBuffer.allocateDirect(cw * ch)
            if (v.capacity() != cw * ch) v = ByteBuffer.allocateDirect(cw * ch)
            this.width = width
            this.height = height
            val key = (width.toLong() shl 48) xor (height.toLong() shl 32) xor (strideY.toLong() shl 20) xor (strideU.toLong() shl 10) xor strideV.toLong()
            if (key != sourceKey || source.isEmpty()) {
                sourceKey = key
                source = describeSource(width, height, strideY, strideU, strideV)
            }
            copyPlane(srcY, strideY, width, height, y)
            copyPlane(srcU, strideU, cw, ch, u)
            copyPlane(srcV, strideV, cw, ch, v)
        }

        fun frame(range: String): VideoFrame =
            VideoFrame(y, width, height, width, chroma = ChromaPlanes(u, v, (width + 1) / 2), source = "$source, $range")

        private var scratch = ByteArray(0)

        /** Tam aralıklı kare sınırlı aralığa çevrilir (Y 16–235, U/V 16–240; yerel çözücünün limit_range'iyle aynı tablo). */
        fun limitRange() {
            mapPlane(y, XboxLumaRange.LUMA)
            mapPlane(u, XboxLumaRange.CHROMA)
            mapPlane(v, XboxLumaRange.CHROMA)
        }

        private fun mapPlane(plane: ByteBuffer, table: ByteArray) {
            val size = plane.capacity()
            if (scratch.size < size) scratch = ByteArray(size)
            val bytes = scratch
            plane.clear()
            plane.get(bytes, 0, size)
            for (i in 0 until size) bytes[i] = table[bytes[i].toInt() and 0xff]
            plane.clear()
            plane.put(bytes, 0, size)
            plane.clear()
        }

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

    internal companion object {
        /**
         * libwebrtc karesinin düzeni, telefon aramasının durum satırında (#1385): boyut, Y ve U/V adımları; kopya sıkı
         * paketlenmiş ayrı Y, U, V düzlemleridir (NV21 gibi iç içe değil).
         */
        fun describeSource(width: Int, height: Int, strideY: Int, strideU: Int, strideV: Int): String {
            val chroma = if (strideU == strideV) "$strideU" else "$strideU/$strideV"
            return "Xbox I420 $width×$height, Y adımı $strideY, U/V adımı $chroma (ayrı düzlemler, sıkı kopya)"
        }
    }

    /** Akışın parlaklık aralığı (libwebrtc bildirmez; karelerden ölçülür, #1385). Yalnız okuma hattında güncellenir. */
    private val range = XboxLumaRange()

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
                // Okuma hattı (telefon araması, ekran yazısı, renkler) PS5'teki gibi sınırlı aralıklı kare bekler.
                range.observe(slot.y, slot.width, slot.height, slot.width)
                if (range.full) slot.limitRange()
                process(slot.frame(range.describe()))
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
        range.reset()
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
 * Xbox akışının parlaklık aralığı (#1385). PS5'te yerel çözücü MediaCodec'in "color-range" bilgisiyle tam aralıklı kareyi
 * sınırlıya çevirir (video-decoder.c limit_range); libwebrtc ise kareyi olduğu gibi verir ve aralığı bildirmez. Okuma hattı
 * (telefon araması [com.couchsubs.mobile.ocr.phoneTone], ekran yazısı, renkler) sınırlı aralık (Y 16–235) varsayar: tam
 * aralıklı akışta 16'nın altındaki koyu tonlar kırpılır, karanlık sahnede telefonun hoparlör yarığı ve kamerası kasaya
 * karışır (gerçek telefon karelerinde ölçüldü: karanlık ana ekran tam aralıkta bulunmuyor). Aralık karelerden ölçülür:
 * [COLUMNS]×[ROWS] noktanın en az [SHARE_PERCENT]'i sınırlı aralığın belirgin dışındaysa ([LOW] altı ya da [HIGH] üstü; sınırlı
 * akışta kodlayıcının taşması bu kadar uzağa gitmez) kare bir oy alır; [VOTES] oyda akış tam aralıklı sayılır (bağlantı
 * boyunca). iPhone/Mac'in yazılım çözücüsü yolunda aynı ölçüm (XboxLumaRange.swift); VideoToolbox aralığı kendisi bilir.
 */
internal class XboxLumaRange {
    @Volatile var full = false
        private set
    @Volatile private var votes = 0
    /** Son ölçülen karede aralık dışı noktaların binde oranı (tanı). */
    @Volatile var outsidePerMille = 0
        private set

    fun observe(plane: ByteBuffer, width: Int, height: Int, stride: Int) {
        if (full || width <= 0 || height <= 0) return
        var outside = 0
        for (row in 0 until ROWS) {
            val y = ((row + 0.5) * height / ROWS).toInt().coerceIn(0, height - 1)
            for (column in 0 until COLUMNS) {
                val x = ((column + 0.5) * width / COLUMNS).toInt().coerceIn(0, width - 1)
                val value = plane.get(y * stride + x).toInt() and 0xff
                if (value < LOW || value > HIGH) outside++
            }
        }
        outsidePerMille = outside * 1000 / (COLUMNS * ROWS)
        if (outside * 100 >= SHARE_PERCENT * COLUMNS * ROWS && ++votes >= VOTES) full = true
    }

    fun reset() {
        full = false
        votes = 0
        outsidePerMille = 0
    }

    /** Durum satırının aralık kısmı. */
    fun describe(): String = if (full) "aralık tam, sınırlıya çevriliyor" else "aralık sınırlı"

    companion object {
        const val COLUMNS = 64
        const val ROWS = 36
        const val LOW = 12
        const val HIGH = 247
        const val SHARE_PERCENT = 2
        const val VOTES = 3

        /** Tam → sınırlı aralık tabloları (video-decoder.c limit_range ile aynı yuvarlama). */
        val LUMA = ByteArray(256) { (16 + (it * 219 + 127) / 255).toByte() }
        val CHROMA = ByteArray(256) { (16 + (it * 224 + 127) / 255).toByte() }
    }
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
