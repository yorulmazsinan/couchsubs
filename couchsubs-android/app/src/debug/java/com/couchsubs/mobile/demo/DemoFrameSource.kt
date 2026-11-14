// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.demo

import android.content.Context
import android.graphics.ImageFormat
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.couchsubs.mobile.remoteplay.DisconnectKind
import com.couchsubs.mobile.remoteplay.FrameSource
import com.couchsubs.mobile.remoteplay.SessionState
import java.io.File

/**
 * Klibin karelerini gerçek zamanında gösterir: her döngü turunda ilk karenin anı saate bağlanır, sonraki kareler
 * sunum zamanlarına göre beklenir. Klip bitince baştan başlar. [speed] 1'den küçükse klip yavaşlar (yavaş öykünücüde
 * yazı tanıma her altyazıyı yakalayabilsin diye).
 */
class ClipClock(private val nowMs: () -> Long, private val speed: Double = 1.0) {
    private var baseWallMs = -1L
    private var basePtsUs = 0L

    /** Yeni tur (ilk kare ya da klip başa sardı): sonraki kare hemen gösterilir. */
    fun restart() {
        baseWallMs = -1L
    }

    /** [ptsUs] sunum zamanlı karenin gösterilmesine kalan süre (ms, en az 0). */
    fun delayFor(ptsUs: Long): Long {
        val now = nowMs()
        if (baseWallMs < 0) {
            baseWallMs = now
            basePtsUs = ptsUs
            return 0
        }
        return (((ptsUs - basePtsUs) / 1000) / speed - (now - baseWallMs)).toLong().coerceAtLeast(0)
    }
}

/**
 * Demo kaynağı (yalnız debug yapısı): PS5 Remote Play oturumu yerine kayıtlı bir klibi MediaCodec ile aynı biçimde
 * (YUV_420_888 ImageReader) çözer ve kareleri okuma hattına verir. Önce "bağlanılıyor", ardından "akış" durumu bildirilir;
 * böylece ana ekran ve telefon altyazı ekranı gerçek bağlantıdaki gibi görünür.
 */
class DemoFrameSource(
    @Suppress("unused") private val context: Context,
    private val clip: File,
    private val speed: Double,
    private val onFrame: (Image) -> Unit,
    private val onState: (SessionState) -> Unit,
) : FrameSource {
    private companion object {
        const val TAG = "CouchSubsDemo"
        const val CONNECT_DELAY_MS = 1500L
        const val TIMEOUT_US = 10_000L
    }

    @Volatile private var running = false
    @Volatile override var framesReceived = 0L
        private set
    private val imageThread = HandlerThread("CouchSubs demo frames").apply { start() }
    private var decoderThread: Thread? = null

    override fun start() {
        running = true
        decoderThread = Thread(::run, "CouchSubs demo").apply {
            isDaemon = true
            start()
        }
    }

    override fun dispose() {
        running = false
        decoderThread?.interrupt()
    }

    private fun run() {
        onState(SessionState.Connecting)
        try {
            Thread.sleep(CONNECT_DELAY_MS)
            decode()
        } catch (error: InterruptedException) {
            // Kapatıldı.
        } catch (error: Exception) {
            Log.e(TAG, "Demo klibi oynatılamadı: $clip", error)
            onState(SessionState.Disconnected(DisconnectKind.OTHER, error.message))
        } finally {
            imageThread.quitSafely()
        }
    }

    private fun decode() {
        val extractor = MediaExtractor().apply { setDataSource(clip.absolutePath) }
        val track = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
        } ?: throw IllegalStateException("Klipte görüntü izi yok")
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val width = format.getInteger(MediaFormat.KEY_WIDTH)
        val height = format.getInteger(MediaFormat.KEY_HEIGHT)

        // PS5 oturumundaki gibi: kareler ImageReader'a çözülür, yalnız çağrı süresince geçerlidir.
        val reader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 3)
        reader.setOnImageAvailableListener({ source ->
            val image = try {
                source.acquireLatestImage()
            } catch (error: IllegalStateException) {
                null
            } ?: return@setOnImageAvailableListener
            framesReceived++
            try {
                onFrame(image)
            } catch (error: RuntimeException) {
                Log.e(TAG, "frame handler", error)
            } finally {
                image.close()
            }
        }, Handler(imageThread.looper))

        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, reader.surface, null, 0)
        codec.start()
        onState(SessionState.Streaming)
        Log.i(TAG, "Demo klibi oynatılıyor: ${clip.name} ${width}x$height ${speed}x (${codec.name})")

        val clock = ClipClock(System::currentTimeMillis, speed)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        try {
            while (running) {
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val size = extractor.readSampleData(codec.getInputBuffer(index)!!, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val out = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (out < 0) continue
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    codec.releaseOutputBuffer(out, false)
                    // Klip bitti: baştan.
                    extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    codec.flush()
                    clock.restart()
                    inputDone = false
                    continue
                }
                val wait = clock.delayFor(info.presentationTimeUs)
                if (wait > 0) Thread.sleep(wait)
                codec.releaseOutputBuffer(out, info.size > 0)
            }
        } finally {
            runCatching { codec.stop() }
            codec.release()
            extractor.release()
            reader.close()
        }
    }
}
