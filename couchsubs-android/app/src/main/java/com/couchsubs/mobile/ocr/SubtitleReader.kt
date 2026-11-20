// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ocr

import com.couchsubs.mobile.core.CropRegion
import com.couchsubs.mobile.core.GrayFrame
import com.couchsubs.mobile.core.Reading
import com.couchsubs.mobile.core.TextBox
import com.couchsubs.mobile.core.TextLine
import com.couchsubs.mobile.core.TextWord
import com.couchsubs.mobile.remoteplay.VideoFrame
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.util.concurrent.TimeUnit

/** Karenin altyazı bölgesinden kopyalanmış parlaklık (Y) düzlemi: yazı tanımaya bu gider, kare hemen bırakılır. */
class RegionPixels(
    val nv21: ByteArray, val width: Int, val height: Int, val signature: Long,
    /** Bölgenin yarım çözünürlüklü U ve V düzlemleri (önce U, sonra V); kare renk taşımıyorsa null. */
    val chroma: ByteArray? = null,
) {
    /** Kumanda simgelerinin kesileceği gri kare (NV21'in başı parlaklık düzlemidir; kopya alınmaz). */
    val gray: GrayFrame get() = GrayFrame(nv21, width, height)

    /**
     * (x, y) noktasının rengi (0xRRGGBB; BT.601, sınırlı aralık): ekran yazısının özgün zemin ve yazı rengi için. Renk
     * yoksa null; stil gri tonla bulunur.
     */
    val color: ((Int, Int) -> Int)?
        get() {
            val uv = chroma ?: return null
            val cw = width / 2
            val plane = cw * (height / 2)
            return { x, y ->
                val luma = (nv21[y * width + x].toInt() and 0xff) - 16
                val i = (y / 2) * cw + (x / 2).coerceAtMost(cw - 1)
                val u = (uv[i].toInt() and 0xff) - 128
                val v = (uv[plane + i].toInt() and 0xff) - 128
                val c = 1.164 * luma
                fun ch(value: Double) = value.toInt().coerceIn(0, 255)
                (ch(c + 1.596 * v) shl 16) or (ch(c - 0.392 * u - 0.813 * v) shl 8) or ch(c + 2.017 * u)
            }
        }
}

/**
 * Altyazı bölgesini Google ML Kit (cihaz üstü, Latin modeli uygulamayla gelir) ile okur. Renk gerekmez: yalnız parlaklık
 * düzlemi kopyalanır, renk düzlemleri nötr (128) bırakılır; bu hem hızlıdır hem beyaz/sarı altyazıyı aynı okur.
 */
class SubtitleReader : AutoCloseable {
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    companion object {
        /** Karenin (Y düzlemi) bölgesini NV21 gri görüntüye kopyalar (en ve boy çift sayıya yuvarlanır). */
        fun copyRegion(frame: VideoFrame, region: CropRegion): RegionPixels? {
            val frameWidth = frame.width
            val frameHeight = frame.height
            if (frameWidth <= 0 || frameHeight <= 0 || frame.rowStride < frameWidth) return null
            val left = (region.left * frameWidth).toInt().coerceIn(0, frameWidth) and 1.inv()
            val top = (region.top * frameHeight).toInt().coerceIn(0, frameHeight) and 1.inv()
            val width = ((region.right - region.left) * frameWidth).toInt().coerceAtMost(frameWidth - left) and 1.inv()
            val height = ((region.bottom - region.top) * frameHeight).toInt().coerceAtMost(frameHeight - top) and 1.inv()
            if (width < 16 || height < 16) return null
            // Yerel taraf arabelleği her karede yeniden yazar: konum ve sınır başkasının işini bozmasın diye kopya.
            val buffer = frame.buffer.duplicate()
            val rowStride = frame.rowStride
            if ((top + height - 1).toLong() * rowStride + left + width > buffer.capacity()) return null
            val out = ByteArray(width * height * 3 / 2)
            var signature = 1125899906842597L
            for (y in 0 until height) {
                val base = y * width
                buffer.position((top + y) * rowStride + left)
                buffer.get(out, base, width)
                // Kare değişmediyse yeniden okunmasın diye kaba bir imza (her 8. piksel).
                if (y % 8 == 0) for (x in 0 until width step 8) signature = 31 * signature + (out[base + x].toInt() and 0xf0)
            }
            java.util.Arrays.fill(out, width * height, out.size, 128.toByte())
            // Renk düzlemleri ayrı tutulur (yazı tanıma gri okur; renk yalnız stil içindir).
            val chroma = frame.chroma?.let { planes ->
                val cw = width / 2
                val ch = height / 2
                val result = ByteArray(2 * cw * ch)
                val u = planes.u.duplicate()
                val v = planes.v.duplicate()
                val end = ((top / 2 + ch - 1) * planes.stride + left / 2 + cw).toLong()
                if (end > u.capacity() || end > v.capacity()) null else {
                    for (y in 0 until ch) {
                        val at = (top / 2 + y) * planes.stride + left / 2
                        u.position(at); u.get(result, y * cw, cw)
                        v.position(at); v.get(result, cw * ch + y * cw, cw)
                    }
                    result
                }
            }
            return RegionPixels(out, width, height, signature, chroma)
        }
    }

    /** Bölgeyi okur (bloklar; okuma iş parçacığında çağrılır). Satır kutuları bölgeye oranladır. */
    fun read(pixels: RegionPixels): Reading {
        val input = InputImage.fromByteArray(pixels.nv21, pixels.width, pixels.height, 0, InputImage.IMAGE_FORMAT_NV21)
        val text = Tasks.await(recognizer.process(input), 5, TimeUnit.SECONDS)
        val lines = mutableListOf<TextLine>()
        for (block in text.textBlocks) {
            for (line in block.lines) {
                val box = line.boundingBox?.let {
                    TextBox(
                        it.left.toDouble() / pixels.width, it.top.toDouble() / pixels.height,
                        it.right.toDouble() / pixels.width, it.bottom.toDouble() / pixels.height,
                    )
                }
                // Sözcük yerleri yazının içindeki kumanda simgesini bulmaya yarar (ButtonIcons); yeri eksik sözcük varsa hiçbiri verilmez.
                val words = line.elements.mapNotNull { element ->
                    element.boundingBox?.let {
                        TextWord(element.text, TextBox(
                            it.left.toDouble() / pixels.width, it.top.toDouble() / pixels.height,
                            it.right.toDouble() / pixels.width, it.bottom.toDouble() / pixels.height,
                        ))
                    }
                }
                lines.add(TextLine(line.text, box, words = if (words.isNotEmpty() && words.size == line.elements.size) words else null,
                    confidence = line.confidence))
            }
        }
        // Yukarıdan aşağı (ML Kit blok sırası her zaman öyle değil).
        return Reading(lines.sortedBy { it.box?.top ?: 0.0 })
    }

    override fun close() = recognizer.close()
}
