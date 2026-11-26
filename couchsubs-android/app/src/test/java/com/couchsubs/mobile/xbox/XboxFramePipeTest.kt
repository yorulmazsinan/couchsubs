// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import com.couchsubs.mobile.remoteplay.VideoFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.util.concurrent.Executor

/** Xbox görüntü alıcısından okuma hattına kare aktarımı (#1308): alıcı beklemez, yalnız en son kare işlenir, bellek sabit. */
class XboxFramePipeTest {
    /** Elle çalıştırılan iş kuyruğu: okuma hattı yavaşken alıcıya kare gelmeye devam eder. */
    private class ManualExecutor : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.addLast(command) }
        fun runAll() { while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    /** width × height I420 kare; Y düzlemi [stride] aralıklı, tüm baytlar [value]. */
    private fun plane(stride: Int, rows: Int, value: Int) = ByteBuffer.allocateDirect(stride * rows).apply {
        for (i in 0 until capacity()) put(i, value.toByte())
    }

    private fun offer(handoff: XboxFrameHandoff, value: Int, width: Int = 8, height: Int = 4, stride: Int = 16) =
        handoff.offer(width, height, plane(stride, height, value), stride, plane(stride / 2, height / 2, value + 1), stride / 2,
            plane(stride / 2, height / 2, value + 2), stride / 2)

    @Test fun onlyTheLatestFrameIsProcessedAndOneTaskIsScheduled() {
        val executor = ManualExecutor()
        val stats = XboxFramePipeStats()
        val seen = ArrayList<Int>()
        val handoff = XboxFrameHandoff(executor, stats) { frame -> seen += frame.buffer.get(0).toInt() }
        assertTrue(offer(handoff, 1))
        assertTrue(offer(handoff, 2))
        assertTrue(offer(handoff, 3))
        assertEquals("okuma hattına tek iş kurulur", 1, executor.tasks.size)
        executor.runAll()
        assertEquals(listOf(3), seen)
        assertTrue(offer(handoff, 4))
        assertEquals(1, executor.tasks.size)
        executor.runAll()
        assertEquals(listOf(3, 4), seen)
        repeat(4) { stats.sink(100_000) }
        val line = stats.take(10_000, "bellek 1 MB")!!
        assertTrue(line, line.startsWith("kare hattı (10 sn): gelen 4, aktarılan 4, işlenen 2, atlanan 2;"))
    }

    @Test fun framesArePackedWithoutStridePaddingAndCarryChroma() {
        val executor = ManualExecutor()
        var frame: VideoFrame? = null
        var u = -1
        var v = -1
        val handoff = XboxFrameHandoff(executor) {
            frame = VideoFrame(it.buffer, it.width, it.height, it.rowStride, chroma = it.chroma)
            u = it.chroma!!.u.get(0).toInt()
            v = it.chroma!!.v.get(3).toInt()
        }
        offer(handoff, 7, width = 8, height = 4, stride = 16)
        executor.runAll()
        val got = frame!!
        assertEquals(8, got.width)
        assertEquals(8, got.rowStride)
        assertEquals(32, got.buffer.capacity())
        assertEquals(7, got.buffer.get(31).toInt())
        assertEquals(4, got.chroma!!.stride)
        assertEquals(8, u)
        assertEquals(9, v)
    }

    /** Okuma hattı takılı kalsa da alıcı beklemez ve en çok üç kare arabelleği ayrılır. */
    @Test fun slowReaderKeepsMemoryBounded() {
        val executor = ManualExecutor()
        val stats = XboxFramePipeStats()
        val handoff = XboxFrameHandoff(executor, stats) {}
        repeat(500) { offer(handoff, it % 100) }
        assertEquals(1, executor.tasks.size)
        assertTrue(handoff.slotsAllocated() <= 3)
        executor.runAll()
        assertTrue(handoff.slotsAllocated() <= 3)
        stats.sink(100_000)
        assertTrue(stats.take(10_000, "")!!.contains("aktarılan 500, işlenen 1, atlanan 499"))
    }

    @Test fun clearedAndClosedHandoffDropsFrames() {
        val executor = ManualExecutor()
        var count = 0
        val handoff = XboxFrameHandoff(executor) { count++ }
        offer(handoff, 1)
        handoff.clear()
        executor.runAll()
        assertEquals("bağlantı bitince bekleyen kare işlenmez", 0, count)
        handoff.close()
        assertFalse(offer(handoff, 2))
        executor.runAll()
        assertEquals(0, count)
    }

    @Test fun readerErrorDoesNotStopTheNextFrame() {
        val executor = ManualExecutor()
        var count = 0
        val handoff = XboxFrameHandoff(executor) { count++; if (count == 1) throw IllegalStateException("bozuk") }
        offer(handoff, 1)
        executor.runAll()
        offer(handoff, 2)
        executor.runAll()
        assertEquals(2, count)
    }

    @Test fun statsLineAndReset() {
        val stats = XboxFramePipeStats()
        assertNull("kare gelmediyse satır yok", stats.take(10_000, "bellek"))
        stats.sink(1_000_000)
        stats.sink(3_000_000)
        stats.handed()
        stats.processed(40_000_000)
        assertEquals("kare hattı (10 sn): gelen 2, aktarılan 1, işlenen 1, atlanan 0; alıcı ort 2.0 ms, en çok 3.0 ms; " +
            "işleme ort 40.0 ms, en çok 40.0 ms; bellek java 40 MB, yerel 190 MB", stats.take(10_000, "bellek java 40 MB, yerel 190 MB"))
        assertNull(stats.take(10_000, "bellek"))
    }

    /** Kare onayı döngüsü takılırsa (Xbox onay alamayıp görüntü kanalını kapatır) satırda en uzun aralık ve geç tur sayısı. */
    @Test fun ackGapsAreReported() {
        val stats = XboxFramePipeStats()
        stats.sink(1_000_000)
        stats.ackTick(16_000_000)
        stats.ackTick(1_200_000_000)
        stats.ackTick(300_000_000)
        assertEquals("kare hattı (10 sn): gelen 1, aktarılan 0, işlenen 0, atlanan 0; alıcı ort 1.0 ms, en çok 1.0 ms; " +
            "işleme ort 0.0 ms, en çok 0.0 ms; onay aralığı en çok 1200.0 ms, 250 ms üstü 2; bellek 1 MB", stats.take(10_000, "bellek 1 MB"))
        stats.sink(1_000_000)
        assertFalse("sayaçlar sıfırlanır", stats.take(10_000, "")!!.contains("onay aralığı"))
    }

    @Test fun closeContextNamesLastFrameAndAck() {
        assertEquals("son kare 0.2 sn önce, son onay 3.5 sn önce, onay 1200", XboxCloseContext.describe(10_000, 9_800, 6_500, 1200))
        assertEquals("kare gelmedi, onay gönderilmedi", XboxCloseContext.describe(10_000, 0, 0, 0))
    }
}
