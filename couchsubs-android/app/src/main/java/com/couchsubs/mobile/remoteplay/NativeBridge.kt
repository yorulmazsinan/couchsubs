// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import android.view.Surface

/** Yerel kayıt ya da oturum başlatma sonucu; alanları yerel taraf (couchsubs-jni.c) doldurur. */
class NativeOutcome {
    /** 0 başarı, 1 PS5 reddetti ya da hata, 2 yanıt yok, -1 başlatılamadı. */
    @JvmField var code: Int = -1
    /** PS5'in bildirdiği neden (0x80108b02 gibi); yoksa 0. */
    @JvmField var reason: Int = 0
    @JvmField var nickname: String? = null
    @JvmField var registKey: ByteArray? = null
    @JvmField var morning: ByteArray? = null
    /** libchiaki'nin hata satırları, alt alta. */
    @JvmField var errors: String? = null

    val errorLines: List<String> get() = errors?.split('\n')?.filter { it.isNotBlank() } ?: emptyList()
}

/** Oturum olayları libchiaki'nin iş parçacığından gelir. */
fun interface NativeSessionListener {
    fun onEvent(type: Int, reason: Int, text: String?)
}

/** libchiaki'ye JNI köprüsü (app/src/main/cpp/couchsubs-jni.c). */
object NativeBridge {
    const val EVENT_CONNECTED = 1
    const val EVENT_LOGIN_PIN = 2
    const val EVENT_QUIT = 3
    const val QUIT_STOPPED = 1
    const val QUIT_IN_USE = 2
    const val QUIT_REFUSED = 3
    const val QUIT_NETWORK = 4
    const val QUIT_OTHER = 5

    /** Yerel kütüphane yüklenebildi mi (yalnız Kotlin derlemesinde ya da desteklenmeyen işlemcide false). */
    val available: Boolean by lazy {
        try {
            System.loadLibrary("couchsubs-jni")
            init() == 0
        } catch (error: UnsatisfiedLinkError) {
            false
        }
    }

    @JvmStatic private external fun init(): Int
    @JvmStatic external fun discover(targets: Array<String>, timeoutMs: Int): Array<String>?
    @JvmStatic external fun wake(host: String, credential: Long): Int
    @JvmStatic external fun register(host: String, accountId: ByteArray, pin: Int, outcome: NativeOutcome)
    @JvmStatic external fun sessionStart(
        host: String, registKey: ByteArray, morning: ByteArray, accountId: ByteArray, width: Int, height: Int,
        surface: Surface, listener: NativeSessionListener, outcome: NativeOutcome,
    ): Long
    @JvmStatic external fun sessionStop(ptr: Long)
    @JvmStatic external fun sessionErrors(ptr: Long): String?
    @JvmStatic external fun sessionFrames(ptr: Long): Long
}
