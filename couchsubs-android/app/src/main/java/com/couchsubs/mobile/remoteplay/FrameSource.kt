// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import android.content.Context
import java.nio.ByteBuffer

/**
 * Bir karenin parlaklık (Y) düzlemi, görünür alana kırpılmış: [width] x [height] piksel, satırlar [rowStride] bayt
 * arayla (piksel aralığı 1). [buffer] yalnız çağrı süresince geçerlidir; sonraki kare aynı arabelleğe yazılır, yani
 * saklanacaksa kopyalanmalıdır. [colorFormat] çözücünün kare biçimi (tanı için; MediaCodecInfo renk biçimi).
 */
class VideoFrame(
    val buffer: ByteBuffer, val width: Int, val height: Int, val rowStride: Int, val colorFormat: Int = 0,
    /** Renk düzlemleri (yarım çözünürlük); çözücü biçimi bilinmiyorsa null (stil gri tonla bulunur). */
    val chroma: ChromaPlanes? = null,
    /**
     * Karenin kaynaktaki düzeni (tanı, telefon aramasının durum satırı; #1385): Xbox'ta libwebrtc karesinin boyutu, düzlem
     * adımları ve düzlem düzeni. Yerel çözücüde null ([colorFormat] yazılır).
     */
    val source: String? = null,
)

/**
 * Karenin yarım çözünürlüklü U ve V düzlemleri: (x, y) noktasının rengi [u] ve [v]'de (y / 2) * [stride] + x / 2'dedir.
 * Yalnız ekran yazısının özgün renklerini bulmak için (yazı tanıma parlaklıkla okur). Arabellekler yalnız çağrı
 * süresince geçerlidir.
 */
class ChromaPlanes(val u: ByteBuffer, val v: ByteBuffer, val stride: Int) {
    companion object {
        /** Yerel çözücünün kare arabelleği: Y (width × height), ardından U ve V ((width / 2) × (height / 2)). */
        fun after(buffer: ByteBuffer, width: Int, height: Int): ChromaPlanes? {
            val cw = width / 2
            val ch = height / 2
            val u = width * height
            if (cw <= 0 || ch <= 0 || buffer.capacity() < u + 2 * cw * ch) return null
            fun slice(at: Int): ByteBuffer = buffer.duplicate().apply { position(at); limit(at + cw * ch) }.slice()
            return ChromaPlanes(slice(u), slice(u + cw * ch), cw)
        }
    }
}

/** Okuma hattına kare veren kaynak: gerçekte PS5 Remote Play oturumu ([StreamSession]). */
interface FrameSource {
    fun start()

    /** Bloklamaz: kaynak arka planda kapatılır. */
    fun dispose()

    /** Gelen kare sayısı (tanı: görüntü geliyor mu). */
    val framesReceived: Long

    /** Oturum yeniden denemeyi kendisi bıraktı (kullanıcı durdurmadı); ana ekranda "Yeniden bağlan" hemen görünür. */
    val hasGivenUp: Boolean get() = false

    /** Xbox: "Xbox sesini bu cihazda çal" çeviri sürerken değişti; yalnız yerel ses açılır/kısılır (#871). */
    fun setPlayAudio(enabled: Boolean) {}

    /** PS5: bağlanırken son adım; "Bağlanıyor…" 30 sn'yi geçince nedeni söylenir (Xbox ve deneme modunda yok). */
    val connectStep: com.couchsubs.mobile.core.ConnectStep? get() = null
}

/** PS5 oturumunun yerine kare kaynağı kuran üretici (yalnız geliştirme yapısında kullanılır). */
fun interface FrameSourceFactory {
    fun create(context: Context, onFrame: (VideoFrame) -> Unit, onState: (SessionState) -> Unit): FrameSource
}

/**
 * Çeviri hizmeti kare kaynağını buradan seçer. Sürüm yapısında [replacement] hep null'dır ve PS5 oturumu açılır;
 * debug yapısı (app/src/debug) Play ekran görüntüleri için PS5 yerine kayıtlı bir klip oynatan kaynak kurabilir.
 */
object FrameSources {
    @Volatile var replacement: FrameSourceFactory? = null
}
