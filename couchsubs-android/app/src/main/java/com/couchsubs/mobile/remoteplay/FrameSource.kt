// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import android.content.Context
import android.media.Image

/** Okuma hattına kare veren kaynak: gerçekte PS5 Remote Play oturumu ([StreamSession]). */
interface FrameSource {
    fun start()

    /** Bloklamaz: kaynak arka planda kapatılır. */
    fun dispose()

    /** Gelen kare sayısı (tanı: görüntü geliyor mu). */
    val framesReceived: Long
}

/** PS5 oturumunun yerine kare kaynağı kuran üretici (yalnız geliştirme yapısında kullanılır). */
fun interface FrameSourceFactory {
    fun create(context: Context, onFrame: (Image) -> Unit, onState: (SessionState) -> Unit): FrameSource
}

/**
 * Çeviri hizmeti kare kaynağını buradan seçer. Sürüm yapısında [replacement] hep null'dır ve PS5 oturumu açılır;
 * debug yapısı (app/src/debug) Play ekran görüntüleri için PS5 yerine kayıtlı bir klip oynatan kaynak kurabilir.
 */
object FrameSources {
    @Volatile var replacement: FrameSourceFactory? = null
}
