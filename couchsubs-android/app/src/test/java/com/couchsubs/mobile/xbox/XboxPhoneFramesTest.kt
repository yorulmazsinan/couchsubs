// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import com.couchsubs.mobile.core.GamePhoneFirstSightingTest
import com.couchsubs.mobile.core.GamePhoneGeometry
import com.couchsubs.mobile.ocr.LivePhoneImage
import com.couchsubs.mobile.remoteplay.VideoFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * Xbox karesinin telefon aramasına giden yolu (#1385): libwebrtc'nin I420 karesi (Y, U, V ayrı düzlemler, satır adımı
 * genişlikten büyük, adımın arası çöp) [XboxFrameHandoff]'tan geçip [LivePhoneImage] ile aranır. Gerçek telefon kareleri
 * (testdata/frames) RGB'den sınırlı aralıklı I420'ye çevrilir; aramanın ölçütü ve bulunan yer RGB karedekiyle aynı olmalı
 * (satır kayması, düzlem karışması, kırpma ya da tek genişlik telefonu bozmasın).
 */
class XboxPhoneFramesTest {
    private val loader = GamePhoneFirstSightingTest()

    /** libwebrtc düzeni: her düzlem kendi adımıyla, adımın arası parlak çöp (sızarsa telefonun kenarı bozulur). */
    private class I420(val width: Int, val height: Int, val y: ByteBuffer, val strideY: Int, val u: ByteBuffer, val v: ByteBuffer, val strideC: Int)

    private fun align(value: Int, to: Int) = (value + to - 1) / to * to

    /** RGB → BT.709 sınırlı aralıklı (Y 16–235) I420; [full] tam aralık (Y 0–255). */
    private fun encode(picture: GamePhoneFirstSightingTest.Picture, alignTo: Int, full: Boolean = false): I420 {
        val w = picture.width
        val h = picture.height
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        val strideY = align(w, alignTo) + alignTo
        val strideC = align(cw, alignTo) + alignTo
        val y = ByteBuffer.allocate(strideY * h)
        val u = ByteBuffer.allocate(strideC * ch)
        val v = ByteBuffer.allocate(strideC * ch)
        for (i in 0 until y.capacity()) y.put(i, 250.toByte())
        for (i in 0 until u.capacity()) { u.put(i, 0); v.put(i, 255.toByte()) }
        fun luma(c: Int): Double = 0.2126 * ((c shr 16) and 0xff) + 0.7152 * ((c shr 8) and 0xff) + 0.0722 * (c and 0xff)
        for (row in 0 until h) for (x in 0 until w) {
            val l = luma(picture.pixels[row * w + x])
            val value = if (full) l else 16 + l * 219 / 255
            y.put(row * strideY + x, Math.round(value).toInt().coerceIn(0, 255).toByte())
        }
        for (row in 0 until ch) for (x in 0 until cw) {
            val c = picture.pixels[minOf(h - 1, row * 2) * w + minOf(w - 1, x * 2)]
            val r = (c shr 16) and 0xff
            val g = (c shr 8) and 0xff
            val b = c and 0xff
            val cb = 128 + (-0.1146 * r - 0.3854 * g + 0.5 * b) * 224 / 255
            val cr = 128 + (0.5 * r - 0.4542 * g - 0.0458 * b) * 224 / 255
            u.put(row * strideC + x, Math.round(cb).toInt().coerceIn(0, 255).toByte())
            v.put(row * strideC + x, Math.round(cr).toInt().coerceIn(0, 255).toByte())
        }
        return I420(w, h, y, strideY, u, v, strideC)
    }

    /**
     * Karenin canlıdaki gibi aktarımdan geçip arandığı sonuç (okuma hattı doğrudan çalışır); [repeat] kez verilir (aralık
     * ölçümü birkaç kare ister), son karenin sonucu döner.
     */
    private fun searchThroughHandoff(frame: I420, repeat: Int = 1): Pair<GamePhoneGeometry.Search, VideoFrame> {
        var result: GamePhoneGeometry.Search? = null
        var seen: VideoFrame? = null
        val handoff = XboxFrameHandoff({ it.run() }) { f ->
            result = GamePhoneGeometry.search(LivePhoneImage(f))
            seen = VideoFrame(f.buffer, f.width, f.height, f.rowStride, chroma = f.chroma, source = f.source)
        }
        repeat(repeat) {
            assertTrue(handoff.offer(frame.width, frame.height, frame.y, frame.strideY, frame.u, frame.strideC, frame.v, frame.strideC))
        }
        return result!! to seen!!
    }

    private fun crop(picture: GamePhoneFirstSightingTest.Picture, width: Int, height: Int) =
        GamePhoneFirstSightingTest.Picture(width, height, IntArray(width * height) { i -> picture.pixels[(i / width) * picture.width + i % width] })

    private fun close(a: GamePhoneGeometry.Pose?, b: GamePhoneGeometry.Pose?): Boolean {
        if (a == null || b == null) return a == b
        return abs(a.topX - b.topX) < 0.01 && abs(a.topY - b.topY) < 0.01 && abs(a.bottomX - b.bottomX) < 0.01 && abs(a.bottomY - b.bottomY) < 0.01
    }

    /** Telefonlu gerçek kareler, 1080p ve 720p, 16/32/64'e yuvarlanmış adımla: sonuç RGB karedekiyle aynı. */
    @Test
    fun i420WithStridePaddingFindsThePhoneLikeTheRgbFrame() {
        val cases = listOf(
            "gta6-telefon-sohbet-1" to "none", "gta6-telefon-sohbet-2" to "none", "gta6-telefon-ana-1" to "none",
            "gta6-telefon-ana-2" to "none", "gta6-telefon-sohbet-1" to "scale720", "gta6-telefon-ana-1" to "dark",
            "gta6-telefon-ana-1" to "dark+scale720",
        )
        for ((name, transform) in cases) {
            val picture = loader.load(name, transform)
            val reference = GamePhoneGeometry.search(picture)
            for (alignTo in intArrayOf(16, 32, 64)) {
                val (search, frame) = searchThroughHandoff(encode(picture, alignTo))
                val label = "$name $transform adım $alignTo"
                assertEquals(label, reference.probe.step, search.probe.step)
                assertTrue("$label: ${reference.pose} / ${search.pose}", close(reference.pose, search.pose))
                assertEquals(label, picture.width, frame.width)
                assertEquals(label, picture.width, frame.rowStride)
            }
        }
    }

    /** Tek genişlik ve yükseklik (kırpılmış akış): satırlar kaymaz, telefon yine bulunur. */
    @Test
    fun oddSizedFramesKeepRowsStraight() {
        val picture = loader.load("gta6-telefon-sohbet-1", "none")
        val odd = crop(picture, picture.width - 1, picture.height - 1)
        val reference = GamePhoneGeometry.search(odd)
        assertNotNull(reference.pose)
        val (search, frame) = searchThroughHandoff(encode(odd, 64))
        assertEquals(reference.probe.step, search.probe.step)
        assertTrue("${reference.pose} / ${search.pose}", close(reference.pose, search.pose))
        assertEquals((odd.width + 1) / 2, frame.chroma!!.stride)
    }

    /** Renk düzlemleri karışmaz: U mavi farkı, V kırmızı farkı (I420; NV21 gibi iç içe değil). */
    @Test
    fun chromaPlanesKeepTheirOrder() {
        val w = 64
        val h = 36
        val red = GamePhoneFirstSightingTest.Picture(w, h, IntArray(w * h) { 0xFF0000 })
        val (_, frame) = searchThroughHandoff(encode(red, 32))
        val u = frame.chroma!!.u.get(5).toInt() and 0xff
        val v = frame.chroma!!.v.get(5).toInt() and 0xff
        assertTrue("U $u", u < 128)
        assertTrue("V $v", v > 200)
    }

    /** Durum satırının kare biçimi: kaynak düzen (adımlar ve düzlemler) satırda görünür. */
    @Test
    fun frameSourceIsDescribed() {
        val picture = loader.load("gta6-telefon-sohbet-1", "scale720")
        val (_, frame) = searchThroughHandoff(encode(picture, 64))
        val line = com.couchsubs.mobile.ocr.PhoneFrames.describe(frame)
        assertTrue(line, line.startsWith("Xbox I420 1280×720, Y adımı 1344, U/V adımı 704 (ayrı düzlemler, sıkı kopya), aralık sınırlı, renk var"))
        assertTrue(line, line.contains("(sınırlı aralıkta)"))
    }

    /**
     * Tam aralıklı akış (libwebrtc aralığı bildirmez): karanlık sahnede telefon, sınırlı aralık sanılınca koyu tonlar kırpılıp
     * bulunmuyordu. Aralık karelerden ölçülür, kare sınırlıya çevrilir; sonuç sınırlı aralıklı akıştakiyle aynı. Çevrilmemiş
     * ilk kare artık ıska sayılmaz: karanlık sahnede ton eşitleme ([GamePhoneGeometry.equalization]) kırpılmış koyu tonlarda
     * da telefonu bulabiliyor.
     */
    @Test
    fun fullRangeStreamIsLimitedLikeThePs5Decoder() {
        for (transform in listOf("dark", "night", "dark+scale720")) {
            val picture = loader.load("gta6-telefon-ana-1", transform)
            val limited = searchThroughHandoff(encode(picture, 64)).first
            val full = encode(picture, 64, full = true)
            // Tek karede çevrilmez (ölçüm birkaç kare ister).
            val (_, firstFrame) = searchThroughHandoff(full)
            assertTrue(firstFrame.source!!, firstFrame.source!!.endsWith("aralık sınırlı"))
            val (search, frame) = searchThroughHandoff(full, repeat = XboxLumaRange.VOTES)
            assertTrue(frame.source!!, frame.source!!.endsWith("aralık tam, sınırlıya çevriliyor"))
            assertNotNull(transform, limited.pose)
            assertEquals(transform, limited.probe.step, search.probe.step)
            assertTrue("$transform: ${limited.pose} / ${search.pose}", close(limited.pose, search.pose))
        }
    }

    /** Sınırlı aralıklı gerçek kareler (karanlık, gece, açık hâlleriyle) hiçbir zaman tam aralık sayılmaz. */
    @Test
    fun limitedRangeFramesNeverFlipToFull() {
        val directory = loader.frames ?: return
        val names = directory.listFiles { f -> f.name.endsWith(".jpg") }!!.map { it.name.removeSuffix(".jpg") }.sorted()
        assertTrue(names.size > 20)
        for (name in names) {
            for (transform in listOf("none", "night", "gamma")) {
                val picture = loader.load(name, transform)
                val i420 = encode(picture, 64)
                val range = XboxLumaRange()
                repeat(XboxLumaRange.VOTES + 2) { range.observe(i420.y, i420.width, i420.height, i420.strideY) }
                assertTrue("$name $transform: ${range.outsidePerMille}‰", !range.full)
            }
            // Yükleyicinin önbelleği ortaktır; 75 kare belleği doldurur.
            GamePhoneFirstSightingTest.cache.remove(name)
        }
    }

    /**
     * Otomatik ekran yazısı Xbox karesinden de alan bulur: bulucu aktarımdan geçen Xbox karesinde, PS5 çözücüsünün sıkı
     * paketlenmiş Y düzlemindekiyle aynı alanları bulur (TranslationService.offerScreenText'teki gibi okunur).
     */
    @Test
    fun screenTextAreasFromXboxFramesMatchThePs5Layout() {
        var found = 0
        for (name in listOf("gta6-n4-bildirim", "gta6-20-gorev", "gta6-harita-kart", "gta6-menu-gorevler")) {
            val picture = loader.load(name, "none")
            val i420 = encode(picture, 64)
            val packed = ByteArray(i420.width * i420.height)
            for (row in 0 until i420.height) for (x in 0 until i420.width) packed[row * i420.width + x] = i420.y.get(row * i420.strideY + x)
            val xbox = com.couchsubs.mobile.core.ScreenTextDetector()
            val ps5 = com.couchsubs.mobile.core.ScreenTextDetector()
            var xboxAreas = emptyList<com.couchsubs.mobile.core.ExtraArea>()
            var ps5Areas = emptyList<com.couchsubs.mobile.core.ExtraArea>()
            var now = 0L
            val handoff = XboxFrameHandoff({ it.run() }) { f ->
                val buffer = f.buffer
                val stride = f.rowStride
                xboxAreas = xbox.update(xbox.sample(f.width, f.height) { x, y -> buffer.get(y * stride + x).toInt() and 0xff }, emptyList(), now)
            }
            repeat(40) {
                handoff.offer(i420.width, i420.height, i420.y, i420.strideY, i420.u, i420.strideC, i420.v, i420.strideC)
                ps5Areas = ps5.update(ps5.sample(i420.width, i420.height) { x, y -> packed[y * i420.width + x].toInt() and 0xff }, emptyList(), now)
                now += 100
            }
            if (xboxAreas.isNotEmpty()) found++
            assertEquals(name, ps5Areas.map { it.region }, xboxAreas.map { it.region })
        }
        assertTrue("Xbox karesinde hiç ekran yazısı alanı bulunmadı", found >= 2)
    }
}
