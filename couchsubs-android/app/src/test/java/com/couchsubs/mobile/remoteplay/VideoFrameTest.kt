// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import com.couchsubs.mobile.core.CropRegion
import com.couchsubs.mobile.ocr.SubtitleReader
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer

/** Yerel çözücünün verdiği Y düzleminden altyazı bölgesinin kopyalanması (ImageReader'sız kare yolu). */
class VideoFrameTest {
    private fun frame(width: Int, height: Int, stride: Int): VideoFrame {
        val buffer = ByteBuffer.allocateDirect(stride * height)
        for (y in 0 until height) for (x in 0 until stride) buffer.put(y * stride + x, if (x < width) (y + x).toByte() else 0x7f.toByte())
        return VideoFrame(buffer, width, height, stride)
    }

    @Test fun copiesRegionRowsWithStride() {
        val source = frame(64, 48, 80)
        val pixels = SubtitleReader.copyRegion(source, CropRegion(top = 0.5, bottom = 1.0, left = 0.25, right = 0.75))
        assertNotNull(pixels)
        assertEquals(32, pixels!!.width)
        assertEquals(24, pixels.height)
        assertEquals(32 * 24 * 3 / 2, pixels.nv21.size)
        // İlk satır: y = 24, x = 16.
        assertEquals((24 + 16).toByte(), pixels.nv21[0])
        assertEquals((24 + 16 + 31).toByte(), pixels.nv21[31])
        assertEquals((47 + 16).toByte(), pixels.nv21[23 * 32])
        // Renk düzlemi nötr.
        assertEquals(128.toByte(), pixels.nv21[32 * 24])
    }

    @Test fun skipsFrameThatIsTooSmallForItsStride() {
        // Arabellek biçimin söylediğinden küçük: okuma sınır dışına taşmaz, kare atlanır.
        val small = VideoFrame(ByteBuffer.allocateDirect(64 * 10), 64, 48, 64)
        assertNull(SubtitleReader.copyRegion(small, CropRegion(top = 0.5, bottom = 1.0, left = 0.0, right = 1.0)))
    }

    /** Bütün kare kopyası önceki kopyanın dizilerine yazılır; sonuç yeni kopyayla aynı, boyu tutmayan dizi kullanılmaz. */
    @Test fun reusesPreviousCopyArrays() {
        val width = 64
        val height = 48
        val buffer = ByteBuffer.allocateDirect(width * height * 3 / 2)
        for (i in 0 until buffer.capacity()) buffer.put(i, (i * 7).toByte())
        val source = VideoFrame(buffer, width, height, width, chroma = ChromaPlanes.after(buffer, width, height))
        val whole = CropRegion(0.0, 1.0, 0.0, 1.0)
        val first = SubtitleReader.copyRegion(source, whole)!!
        java.util.Arrays.fill(first.nv21, 3)
        java.util.Arrays.fill(first.chroma!!, 9)
        val reused = SubtitleReader.copyRegion(source, whole, first)!!
        val fresh = SubtitleReader.copyRegion(source, whole)!!
        assertTrue(reused.nv21 === first.nv21)
        assertTrue(reused.chroma === first.chroma)
        assertArrayEquals(fresh.nv21, reused.nv21)
        assertArrayEquals(fresh.chroma, reused.chroma)
        assertEquals(fresh.signature, reused.signature)
        val other = SubtitleReader.copyRegion(source, CropRegion(top = 0.5, bottom = 1.0, left = 0.0, right = 1.0), first)!!
        assertFalse(other.nv21 === first.nv21)
    }

    @Test fun rejectsStrideBelowWidth() {
        assertNull(SubtitleReader.copyRegion(VideoFrame(ByteBuffer.allocateDirect(4096), 64, 48, 32), CropRegion()))
    }
}
