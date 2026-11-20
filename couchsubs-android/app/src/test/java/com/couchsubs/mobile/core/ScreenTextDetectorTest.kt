// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Ekran yazısı bulucu: sentetik karelerle (Windows ScreenTextDetectorTests ve Mac ile aynı durumlar). */
class ScreenTextDetectorTest {
    private val width = 640
    private val height = 360

    /** Kare: her örnekte değişen gürültülü zemin; [box] (x0, y0, x1, y1 piksel) içinde koyu kutu ve beyaz "yazı" çizgileri. */
    private fun frame(seed: Int, box: IntArray? = null): ByteArray {
        val random = Random(seed)
        val pixels = ByteArray(width * height) { random.nextInt(256).toByte() }
        if (box != null) drawBox(pixels, width, box)
        return pixels
    }

    private fun drawBox(pixels: ByteArray, stride: Int, box: IntArray) {
        for (y in box[1] until box[3]) for (x in box[0] until box[2]) {
            val text = (y - box[1]) % 8 in 3..4 && x % 4 != 0
            pixels[y * stride + x] = (if (text) 230 else 25).toByte()
        }
    }

    private fun ScreenTextDetector.step(pixels: ByteArray, now: Long, excluded: List<CropRegion> = emptyList()): List<ExtraArea> =
        update(sample(width, height) { x, y -> pixels[y * width + x].toInt() and 0xff }, excluded, now)

    private val quest = intArrayOf(20, 20, 180, 80)

    @Test
    fun boxThatStaysIsProposedAfterItSettles() {
        val detector = ScreenTextDetector()
        for (t in 0L..200L step 100) assertTrue(detector.step(frame(t.toInt(), quest), t).isEmpty())
        val areas = detector.step(frame(300, quest), 300)
        assertEquals(1, areas.size)
        val area = areas.single()
        assertTrue(area.auto)
        assertEquals("Screen text", area.name)
        assertTrue(area.id.startsWith("auto-"))
        // Kutunun karoları (sütun 1-8, satır 1-3) yarım karo genişletilir.
        assertEquals(0.5 / 32, area.region.left, 1e-9)
        assertEquals(9.5 / 32, area.region.right, 1e-9)
        assertEquals(0.5 / 18, area.region.top, 1e-9)
        assertEquals(4.5 / 18, area.region.bottom, 1e-9)
        // Sonraki örneklerde kimlik korunur.
        assertEquals(area.id, detector.step(frame(400, quest), 400).single().id)
    }

    @Test
    fun movingBoxIsNotProposed() {
        val detector = ScreenTextDetector()
        for (i in 0 until 15) {
            val shift = i * 7
            val box = intArrayOf(20 + shift, 20 + shift, 180 + shift, 80 + shift)
            assertTrue(detector.step(frame(i, box), i * 100L).isEmpty())
        }
    }

    @Test
    fun boxInsideTheSubtitleOrUserAreaIsNotProposed() {
        val detector = ScreenTextDetector()
        val excluded = listOf(CropRegion(top = 0.0, bottom = 0.5, left = 0.0, right = 0.5))
        for (t in 0L..1000L step 100) assertTrue(detector.step(frame(t.toInt(), quest), t, excluded).isEmpty())
    }

    @Test
    fun rejectedAreaIsNotProposedAgainUntilItChanges() {
        val detector = ScreenTextDetector()
        var areas = emptyList<ExtraArea>()
        for (t in 0L..300L step 100) areas = detector.step(frame(t.toInt(), quest), t)
        detector.rejected(areas.single().id)
        assertTrue(detector.areas.isEmpty())
        for (t in 400L..2000L step 100) assertTrue(detector.step(frame(t.toInt(), quest), t).isEmpty())
        // Görüntü değişince (başka yazı) yeniden aday olur.
        val other = intArrayOf(20, 24, 180, 84)
        var again = emptyList<ExtraArea>()
        for (t in 2100L..2500L step 100) again = detector.step(frame(t.toInt(), other), t)
        assertEquals(1, again.size)
    }

    @Test
    fun areaIsRemoved700msAfterTheBoxDisappears() {
        val detector = ScreenTextDetector()
        for (t in 0L..300L step 100) detector.step(frame(t.toInt(), quest), t)
        for (t in 400L..900L step 100) assertEquals("t=$t", 1, detector.step(frame(t.toInt()), t).size)
        assertTrue(detector.step(frame(1000), 1000).isEmpty())
    }

    @Test
    fun largeComponentIsSkipped() {
        val detector = ScreenTextDetector()
        val scene = intArrayOf(0, 0, 400, 300)
        for (t in 0L..1000L step 100) assertTrue(detector.step(frame(t.toInt(), scene), t).isEmpty())
    }

    @Test
    fun sampleGateIsSingleFlightAndAtMost10Hz() {
        val detector = ScreenTextDetector()
        assertTrue(detector.begin(0))
        assertFalse(detector.begin(200))
        detector.finished()
        assertFalse(detector.begin(50))
        assertTrue(detector.begin(100))
        detector.finished()
        detector.reset()
        assertTrue(detector.begin(301))
    }

    @Test
    fun noiseRules() {
        listOf("$1,250", "12:45", "PAUSE", "HONOR", "LIQUOR STORE", "x3 Ammo").forEach {
            assertTrue(it, ScreenTextNoise.isNoise(it))
        }
        listOf("Go to the Saloon.", "Follow Paulie to the car.", "Lamar has sent you a message.", "Press ✕ to open the map.").forEach {
            assertFalse(it, ScreenTextNoise.isNoise(it))
        }
    }

    /** Ölçüm: 1920×1080 karede bir örnek (örnekleme + işleme). */
    @Test
    fun measureFullHdSample() {
        val w = 1920
        val h = 1080
        // Zemin her örnekte değişir (oyun sahnesi), kutu durur.
        val frames = (0 until 2).map { seed ->
            val random = Random(seed)
            ByteArray(w * h) { random.nextInt(256).toByte() }.also { drawBox(it, w, intArrayOf(60, 60, 540, 240)) }
        }
        val detector = ScreenTextDetector()
        repeat(20) { i -> val pixels = frames[i % 2]; detector.update(detector.sample(w, h) { x, y -> pixels[y * w + x].toInt() and 0xff }, emptyList(), i * 100L) }
        val times = (0 until 100).map { i ->
            val pixels = frames[i % 2]
            val start = System.nanoTime()
            detector.update(detector.sample(w, h) { x, y -> pixels[y * w + x].toInt() and 0xff }, emptyList(), 2000L + i * 100L)
            (System.nanoTime() - start) / 1e6
        }
        println("ScreenTextDetector 1920x1080: ortalama %.3f ms, en kötü %.3f ms (100 örnek)".format(times.average(), times.max()))
        assertEquals(1, detector.areas.size)
    }
}
