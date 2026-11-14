// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ocr

import android.media.Image
import com.couchsubs.mobile.core.CropRegion
import com.couchsubs.mobile.core.Reading
import com.couchsubs.mobile.core.TextBox
import com.couchsubs.mobile.core.TextLine
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.util.concurrent.TimeUnit

/** Karenin altyazı bölgesinden kopyalanmış parlaklık (Y) düzlemi: yazı tanımaya bu gider, kare hemen bırakılır. */
class RegionPixels(val nv21: ByteArray, val width: Int, val height: Int, val signature: Long)

/**
 * Altyazı bölgesini Google ML Kit (cihaz üstü, Latin modeli uygulamayla gelir) ile okur. Renk gerekmez: yalnız parlaklık
 * düzlemi kopyalanır, renk düzlemleri nötr (128) bırakılır; bu hem hızlıdır hem beyaz/sarı altyazıyı aynı okur.
 */
class SubtitleReader : AutoCloseable {
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    companion object {
        /** YUV_420_888 karenin bölgesini NV21 gri görüntüye kopyalar (en ve boy çift sayıya yuvarlanır). */
        fun copyRegion(image: Image, region: CropRegion): RegionPixels? {
            val crop = image.cropRect
            val frameWidth = crop.width()
            val frameHeight = crop.height()
            if (frameWidth <= 0 || frameHeight <= 0) return null
            val left = (crop.left + region.left * frameWidth).toInt() and 1.inv()
            val top = (crop.top + region.top * frameHeight).toInt() and 1.inv()
            val width = ((region.right - region.left) * frameWidth).toInt().coerceAtMost(crop.right - left) and 1.inv()
            val height = ((region.bottom - region.top) * frameHeight).toInt().coerceAtMost(crop.bottom - top) and 1.inv()
            if (width < 16 || height < 16) return null
            val plane = image.planes[0]
            val buffer = plane.buffer
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val out = ByteArray(width * height * 3 / 2)
            var signature = 1125899906842597L
            val row = ByteArray(if (pixelStride == 1) width else (width - 1) * pixelStride + 1)
            for (y in 0 until height) {
                buffer.position((top + y) * rowStride + left * pixelStride)
                buffer.get(row, 0, row.size)
                val base = y * width
                if (pixelStride == 1) System.arraycopy(row, 0, out, base, width)
                else for (x in 0 until width) out[base + x] = row[x * pixelStride]
                // Kare değişmediyse yeniden okunmasın diye kaba bir imza (her 8. piksel).
                if (y % 8 == 0) for (x in 0 until width step 8) signature = 31 * signature + (out[base + x].toInt() and 0xf0)
            }
            java.util.Arrays.fill(out, width * height, out.size, 128.toByte())
            return RegionPixels(out, width, height, signature)
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
                lines.add(TextLine(line.text, box))
            }
        }
        // Yukarıdan aşağı (ML Kit blok sırası her zaman öyle değil).
        return Reading(lines.sortedBy { it.box?.top ?: 0.0 })
    }

    override fun close() = recognizer.close()
}
