// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import android.graphics.ImageFormat
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Bağlantının neden koptuğu; kullanıcıya anlatılabilecek biçimde (Windows: DisconnectKind). */
enum class DisconnectKind { STOPPED, IN_USE, REFUSED, NETWORK, NOT_FOUND, CONSOLE_ASLEEP, LOGIN_PASSCODE, OTHER }

sealed class SessionState {
    data object Connecting : SessionState()
    data object Streaming : SessionState()
    data class Disconnected(val kind: DisconnectKind, val detail: String? = null) : SessionState()
}

/** Bağlantı koptuğunda yeniden deneme aralıkları: 2, 4, 8, 16, en çok 30 sn (Windows ile aynı). */
class ReconnectPolicy {
    private var attempt = 0
    fun nextDelaySeconds(): Int {
        val delay = minOf(30, 2 shl attempt)
        attempt = minOf(attempt + 1, 5)
        return delay
    }
    fun reset() {
        attempt = 0
    }
}

/**
 * PS5'e (ikinci hesapla) Remote Play bağlantısı kurar; görüntü MediaCodec'le bir ImageReader'a çözülür ve kare kare
 * [onFrame]'e verilir (kare yalnız çağrı süresince geçerlidir). Ses kapalıdır, kol girdisi gönderilmez. Bağlantı koparsa
 * kendiliğinden yeniden bağlanır; PS5 uyuyorsa uyandırılır, adresi değiştiyse ağda yeniden bulunur. Windows'taki
 * StreamSession.cs ile aynı akış.
 */
class StreamSession(
    console: RegisteredConsole,
    private val accountId: ByteArray,
    private val onFrame: (Image) -> Unit,
    private val onState: (SessionState) -> Unit,
    private val onConsoleMoved: (RegisteredConsole) -> Unit = {},
    private val width: Int = 1920,
    private val height: Int = 1080,
) : FrameSource {
    private companion object {
        const val TAG = "CouchSubsSession"
        const val RELOCATE_INTERVAL_MS = 30_000L
    }

    @Volatile private var console = console
    private val queue = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs session").apply { isDaemon = true } }
    private val imageThread = HandlerThread("CouchSubs frames").apply { start() }
    private val policy = ReconnectPolicy()
    private val stateLock = Any()
    private var running = false
    private var generation = 0
    private var nextRelocate = 0L
    private var searchAnswered = true

    /** Yalnız kuyrukta okunur/yazılır. */
    private var native = 0L
    private var nativeGeneration = 0
    private var reader: ImageReader? = null

    override fun start() {
        val current = bump(true)
        queue.execute {
            policy.reset()
            connect(current)
        }
    }

    /** Bloklamaz: oturum arka planda kapatılır. */
    fun stop() {
        bump(false)
        queue.execute(::closeNative)
    }

    override fun dispose() {
        stop()
        queue.execute {
            imageThread.quitSafely()
            queue.shutdown()
        }
    }

    /** Ağ değiştiğinde uygulama çağırır. */
    fun reconnectNow() {
        if (!isRunning) return
        val current = bump(true)
        queue.execute {
            closeNative()
            policy.reset()
            connect(current)
        }
    }

    /** ImageReader'a gelen kare sayısı (tanı: görüntü geliyor mu). */
    @Volatile override var framesReceived = 0L
        private set

    private val isRunning get() = synchronized(stateLock) { running }

    private fun bump(value: Boolean) = synchronized(stateLock) {
        running = value
        ++generation
    }

    private fun isCurrent(value: Int) = synchronized(stateLock) { running && generation == value }

    private fun connect(current: Int) {
        if (!isCurrent(current) || native != 0L) return
        emit(SessionState.Connecting)
        val info = ConsoleDiscovery.discover(console.host, 2000).firstOrNull() ?: relocate()
        searchAnswered = info != null
        Log.i(TAG, if (info == null) "PS5 ${console.host} aramaya yanıt vermedi, yine de bağlanılıyor"
            else "PS5 ${info.name} ${info.host} ${if (info.isAwake) "uyanık" else "dinlenmede, uyandırılıyor"}")
        if (info != null && !info.isAwake) {
            try {
                ConsoleDiscovery.wake(console)
            } catch (error: Exception) {
                Log.w(TAG, "wake: ${error.message}")
            }
            waitForWake(current, System.currentTimeMillis() + 20_000)
            return
        }
        openSession(current)
    }

    private fun relocate(): ConsoleInfo? {
        val now = System.currentTimeMillis()
        if (now < nextRelocate) return null
        nextRelocate = now + RELOCATE_INTERVAL_MS
        val moved = ConsoleDiscovery.pickMoved(ConsoleDiscovery.discover(null, 3000), console.name)
        if (moved == null || moved.host == console.host) return null
        Log.i(TAG, "PS5 yeni adreste: ${console.host} -> ${moved.host}")
        console = console.withHost(moved.host)
        onConsoleMoved(console)
        return moved
    }

    private fun waitForWake(current: Int, deadline: Long) {
        queue.schedule({
            if (!isCurrent(current)) return@schedule
            when {
                ConsoleDiscovery.discover(console.host, 2000).any { it.isAwake } -> openSession(current)
                System.currentTimeMillis() < deadline -> waitForWake(current, deadline)
                else -> scheduleReconnect(current, SessionState.Disconnected(DisconnectKind.CONSOLE_ASLEEP))
            }
        }, 2, TimeUnit.SECONDS)
    }

    private fun openSession(current: Int) {
        if (!isCurrent(current) || native != 0L) return
        val imageReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 3)
        imageReader.setOnImageAvailableListener({ source ->
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
        val outcome = NativeOutcome()
        val listener = NativeSessionListener { type, reason, text -> handle(type, reason, text, current) }
        val c = console
        val ptr = NativeBridge.sessionStart(c.host, c.registKey, c.morning, accountId, width, height, imageReader.surface, listener, outcome)
        if (ptr == 0L) {
            imageReader.close()
            Log.w(TAG, "PS5 oturumu başlatılamadı (${c.host}): ${outcome.errors}")
            scheduleReconnect(current, SessionState.Disconnected(DisconnectKind.OTHER, outcome.errorLines.lastOrNull() ?: "session could not be started"))
            return
        }
        native = ptr
        nativeGeneration = current
        reader = imageReader
    }

    /** Oturumu kapatır (join içerir; yalnız kuyrukta, asla yerel geri çağrıdan değil). */
    private fun closeNative() {
        val ptr = native
        if (ptr == 0L) return
        native = 0L
        NativeBridge.sessionStop(ptr)
        reader?.close()
        reader = null
    }

    /** libchiaki'nin iş parçacığından çağrılır. */
    private fun handle(type: Int, reason: Int, text: String?, eventGeneration: Int) {
        when (type) {
            NativeBridge.EVENT_CONNECTED -> queue.execute {
                if (nativeGeneration != eventGeneration || native == 0L) return@execute
                policy.reset()
                emit(SessionState.Streaming)
            }
            // Kol girdisi göndermediğimiz için şifre giremeyiz; yeniden denemek de aynı yere çıkar.
            NativeBridge.EVENT_LOGIN_PIN -> queue.execute {
                if (nativeGeneration != eventGeneration) return@execute
                bump(false)
                closeNative()
                emit(SessionState.Disconnected(DisconnectKind.LOGIN_PASSCODE))
            }
            NativeBridge.EVENT_QUIT -> {
                val kind = when (reason) {
                    NativeBridge.QUIT_STOPPED -> DisconnectKind.STOPPED
                    NativeBridge.QUIT_IN_USE -> DisconnectKind.IN_USE
                    NativeBridge.QUIT_REFUSED -> DisconnectKind.REFUSED
                    NativeBridge.QUIT_NETWORK -> DisconnectKind.NETWORK
                    else -> DisconnectKind.OTHER
                }
                Log.i(TAG, "Oturum kapandı: $kind $text")
                queue.execute {
                    if (nativeGeneration != eventGeneration || native == 0L) return@execute
                    closeNative()
                    scheduleReconnect(eventGeneration, SessionState.Disconnected(kind, text))
                }
            }
        }
    }

    private fun scheduleReconnect(current: Int, state: SessionState.Disconnected) {
        // Ağ hatasıyla düştüyse ve PS5 aramaya da yanıt vermediyse neden "bulunamadı"dır.
        val classified = if (!searchAnswered && (state.kind == DisconnectKind.NETWORK || state.kind == DisconnectKind.OTHER))
            SessionState.Disconnected(DisconnectKind.NOT_FOUND, console.host) else state
        emit(classified)
        if (!isCurrent(current)) return
        queue.schedule({ connect(current) }, policy.nextDelaySeconds().toLong(), TimeUnit.SECONDS)
    }

    private fun emit(state: SessionState) {
        try {
            onState(state)
        } catch (error: RuntimeException) {
            Log.e(TAG, "state handler", error)
        }
    }
}
