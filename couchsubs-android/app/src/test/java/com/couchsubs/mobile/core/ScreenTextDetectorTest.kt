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
        // Zemin her karede değişiyor (kamera hareketi): arayüz kutusu 600 ms yerinde kalınca önerilir.
        for (t in 0L..500L step 100) assertTrue(detector.step(frame(t.toInt(), quest), t).isEmpty())
        val areas = detector.step(frame(600, quest), 600)
        assertEquals(1, areas.size)
        val area = areas.single()
        assertTrue(area.auto)
        assertEquals("Screen text", area.name)
        assertTrue(area.id.startsWith("auto-"))
        // Kutunun karoları (sütun 1-8, satır 1-3) yatayda bir, dikeyde yarım karo genişletilir.
        assertEquals(0.0, area.region.left, 1e-9)
        assertEquals(10.0 / 32, area.region.right, 1e-9)
        assertEquals(0.5 / 18, area.region.top, 1e-9)
        assertEquals(4.5 / 18, area.region.bottom, 1e-9)
        // Sonraki örneklerde kimlik korunur.
        assertEquals(area.id, detector.step(frame(700, quest), 700).single().id)
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
        for (t in 0L..600L step 100) areas = detector.step(frame(t.toInt(), quest), t)
        detector.rejected(areas.single().id)
        assertTrue(detector.areas.isEmpty())
        for (t in 700L..2000L step 100) assertTrue(detector.step(frame(t.toInt(), quest), t).isEmpty())
        // Görüntü değişince (başka yazı) yeniden aday olur.
        val other = intArrayOf(20, 24, 180, 84)
        var again = emptyList<ExtraArea>()
        for (t in 2100L..2800L step 100) again = detector.step(frame(t.toInt(), other), t)
        assertEquals(1, again.size)
    }

    @Test
    fun areaIsRemoved700msAfterTheBoxDisappears() {
        val detector = ScreenTextDetector()
        for (t in 0L..600L step 100) detector.step(frame(t.toInt(), quest), t)
        for (t in 700L..1200L step 100) assertEquals("t=$t", 1, detector.step(frame(t.toInt()), t).size)
        assertTrue(detector.step(frame(1300), 1300).isEmpty())
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

    // --- Dünya yazısı (poster, plaka, tabela): yanlış pozitif ölçümü ---

    /** Sabit dünya dokusu (yüksek sapmalı), [shift] piksel kaydırılmış (kamera kaydırması). */
    private fun world(shift: Int): ByteArray {
        val pixels = ByteArray(width * height)
        for (y in 0 until height) for (x in 0 until width) {
            val wx = x + shift
            val h = (wx * 73856093) xor (y * 19349663)
            pixels[y * width + x] = (40 + (h ushr 8) % 180).toByte()
        }
        return pixels
    }

    /** Dünyada duran yazı: dokulu zemin üstünde açık harf çizgileri (zemin düz değil). */
    private fun poster(pixels: ByteArray, x0: Int, y0: Int, x1: Int, y1: Int) {
        for (y in y0 until y1) for (x in x0 until x1) {
            if (x < 0 || x >= width) continue
            val text = (y - y0) % 8 in 3..4 && x % 4 != 0
            val h = (x * 2654435761L.toInt()) xor (y * 40503)
            pixels[y * width + x] = (if (text) 235 else 10 + (h ushr 4) % 90).toByte()
        }
    }

    @Test
    fun worldTextIsNeverProposedHudIs() {
        var falsePositives = 0
        // 1) Kamera kayıyor: dünya ve üstündeki poster her karede 8 px kayar, HUD kutusu (düz koyu zemin) sabit.
        run {
            val detector = ScreenTextDetector()
            detector.debug = { if (System.getenv("DBG") != null) println(it) }
            var areas = emptyList<ExtraArea>()
            for (i in 0 until 20) {
                val pixels = world(i * 8)
                poster(pixels, 300 - i * 8, 200, 460 - i * 8, 260)
                drawBox(pixels, width, quest)
                areas = detector.step(pixels, i * 100L)
            }
            falsePositives += areas.count { it.region.top > 0.4 }
            assertEquals(1, areas.size)
            assertTrue(areas.single().region.top < 0.1)
        }
        // 2) Kamera durgun: dokulu duvardaki yazı (zemin düz değil) arayüz kanıtı vermez.
        run {
            val detector = ScreenTextDetector()
            var areas = emptyList<ExtraArea>()
            for (i in 0 until 20) {
                val pixels = world(0)
                poster(pixels, 300, 200, 460, 260)
                drawBox(pixels, width, quest)
                areas = detector.step(pixels, i * 100L)
            }
            falsePositives += areas.count { it.region.top > 0.4 }
            assertEquals(1, areas.size)
        }
        println("Dünya yazısı yanlış pozitif: $falsePositives (hedef 0)")
        assertEquals(0, falsePositives)
    }

    @Test
    fun tiltedLineIsWorldText() {
        val words = listOf(TextWord("GRAND", TextBox(0.1, 0.10, 0.3, 0.20)), TextWord("OPENING", TextBox(0.32, 0.16, 0.6, 0.26)))
        val tilted = TextLine("GRAND OPENING TODAY", TextBox(0.1, 0.1, 0.6, 0.26), words = words)
        val straight = TextLine("Go to the Saloon now", TextBox(0.1, 0.4, 0.6, 0.5),
            words = listOf(TextWord("Go", TextBox(0.1, 0.4, 0.2, 0.5)), TextWord("now", TextBox(0.5, 0.41, 0.6, 0.5))))
        assertEquals(listOf("Go to the Saloon now"), AutoText.clean(Reading(listOf(tilted, straight)), menu = false).lines.map { it.text })
    }

    @Test
    fun textSeenElsewhereIsWorldTextForTheSession() {
        val sent = mutableListOf<String>()
        val sender = object : RegionSender {
            override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) { sent.add(text) }
            override fun clearRegions() {}
        }
        var box = TextBox(0.1, 0.1, 0.6, 0.2)
        val rejected = mutableListOf<String>()
        val watcher = RegionWatcher({ Reading(listOf(TextLine("Grand opening of the Saloon", box))) }, { "Salonun açılışı" }, sender)
        watcher.onAutoRejected = { rejected.add(it) }
        val area = ExtraArea("auto-1", ScreenTextDetector.NAME, CropRegion(0.0, 1.0, 0.0, 1.0), auto = true)
        fun pass(value: Int) = watcher.pass(setOf(area.id), listOf(area to RegionWatcher.Crop(Unit, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { value.toByte() })))
        pass(1)
        // Kamera döndü: aynı yazı başka yerde ve boyda okundu.
        box = TextBox(0.3, 0.4, 0.9, 0.55)
        pass(100)
        assertEquals(listOf("auto-1"), rejected)
        box = TextBox(0.1, 0.1, 0.6, 0.2)
        pass(1)
        assertEquals(listOf("auto-1", "auto-1"), rejected)
    }
}
