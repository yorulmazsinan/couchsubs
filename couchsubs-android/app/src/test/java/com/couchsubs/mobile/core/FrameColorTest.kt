// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import com.couchsubs.mobile.ocr.LivePhoneImage
import com.couchsubs.mobile.remoteplay.VideoFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * Kullanıcı bildirimi (X, Mac mini, beta-101): aynı kare dosyadan verilince telefon bulunuyor, canlıda bulunmuyordu (renk
 * uzayı/aralık farkı). Android'de çözücünün karesi YUV'dur; yerel çözücü tam aralıklı akışı sınırlı aralığa çevirir
 * (video-decoder.c limit_range), [LivePhoneImage] sınırlı aralığı tam aralıklı sRGB tonuna açar. Aynı sentetik telefon
 * RGB karede ve sınırlı ya da (sınırlıya çevrilmiş) tam aralıklı Y karesinde aynı tonla okunur, aynı yerde bulunur
 * (Mac/iPhone FrameColorTests.swift aynı telefonu kare biçimlerinde dener).
 */
class FrameColorTest {
    /** Yerel çözücünün tablosu (video-decoder.c limit_range): tam aralık → sınırlı. */
    private fun limited(full: Int) = 16 + (full * 219 + 127) / 255

    private fun frame(source: PhoneImage, luma: (Int) -> Int): VideoFrame {
        val buffer = ByteBuffer.allocateDirect(source.width * source.height)
        for (y in 0 until source.height) for (x in 0 until source.width) {
            buffer.put(y * source.width + x, luma((source.rgb(x, y) shr 8) and 0xff).toByte())
        }
        return VideoFrame(buffer, source.width, source.height, source.width)
    }

    @Test
    fun samePhoneInRgbAndYuvFrames() {
        val rgb = TestPhoneImage.phone()
        val expected = assertNotNullPose(GamePhoneGeometry.locate(rgb))
        // Sınırlı aralıklı akış (Y = 16 + 219·g/255); tam aralıklı akış (Y = g) çözücüde aynı tabloyla buna çevrilir.
        val full = frame(rgb) { it }
        val mapped = ByteBuffer.allocateDirect(rgb.width * rgb.height)
        for (i in 0 until rgb.width * rgb.height) mapped.put(i, limited(full.buffer.get(i).toInt() and 0xff).toByte())
        for ((name, image) in listOf("sınırlı aralık" to LivePhoneImage(frame(rgb) { limited(it) }),
                                     "tam aralık, sınırlıya çevrilmiş" to LivePhoneImage(VideoFrame(mapped, rgb.width, rgb.height, rgb.width)))) {
            var worst = 0
            for (y in 0 until rgb.height) for (x in 0 until rgb.width) {
                worst = maxOf(worst, abs((image.tone(x, y) shr 8) - (rgb.tone(x, y) shr 8)))
            }
            assertTrue("$name: en büyük ton farkı $worst", worst <= 2)
            val pose = assertNotNullPose(GamePhoneGeometry.locate(image))
            assertEquals(name, expected.topX, pose.topX, 0.01)
            assertEquals(name, expected.topY, pose.topY, 0.01)
            assertEquals(name, expected.bottomX, pose.bottomX, 0.01)
            assertEquals(name, expected.bottomY, pose.bottomY, 0.01)
        }
    }

    @Test
    fun limitedRangeEndsMapToBlackAndWhite() {
        assertEquals(16, limited(0))
        assertEquals(235, limited(255))
        val image = LivePhoneImage(frame(TestPhoneImage(2, 1) { x, _ -> TestPhoneImage.gray(if (x == 0) 0 else 255) }) { limited(it) })
        assertEquals(0, image.tone(0, 0) shr 8)
        assertEquals(254, image.tone(1, 0) shr 8)
    }

    private fun assertNotNullPose(pose: GamePhoneGeometry.Pose?): GamePhoneGeometry.Pose {
        assertNotNull(pose)
        return pose!!
    }
}
