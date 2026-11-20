// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import java.util.concurrent.atomic.AtomicLong

/**
 * Ev yayını oturumunun durum makinesi (ağdan bağımsız; birim testli). Windows'taki XboxStreamSession.RunAsync ile aynı
 * kurallar: `/state` saniyede bir, en çok 90 kez sorulur; `ReadyToConnect` görülünce aktarım jetonu gönderilir,
 * `Provisioned` olunca WebRTC el sıkışması başlar. Hata ya da kopmada 5, 15, 45 sn sonra baştan denenir; üç ardışık
 * denemeden sonra durulur (konsol "oyun başka yerde açıldı" deyip yayını kesince eskiden her 5 sn'de bir yeniden
 * açılıyordu). Konsol `Failed` ya da `errorDetails` dönerse, yeniden giriş gerekirse (ör. yenileme jetonu geçersiz)
 * hiç denenmez. Yayın [healthyStreamMs] ayakta kaldıysa deneme sayısı sıfırlanır.
 */
class XboxSessionMachine(
    val maxPolls: Int = 90,
    val pollIntervalMs: Long = 1000,
    val retryDelaysMs: List<Long> = listOf(5000, 15000, 45000),
    val healthyStreamMs: Long = 60_000,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    sealed class Phase {
        data object Idle : Phase()
        data object Starting : Phase()
        data class Provisioning(val polls: Int, val connectSent: Boolean) : Phase()
        data object Negotiating : Phase()
        data object Streaming : Phase()
        /** [attempt]: bu kopmadan sonraki ardışık deneme (1…3); denenmiyorsa 0. */
        data class Failed(val kind: XboxError, val message: String, val willRetry: Boolean, val attempt: Int = 0) : Phase()
        data object Stopped : Phase()
    }

    sealed class Action {
        /** `/play` gönder. */
        data object Play : Action()
        /** [delayMs] bekle, `/state` sor. */
        data class PollState(val delayMs: Long) : Action()
        /** Aktarım jetonuyla `/connect` gönder, sonra yine sor. */
        data object Connect : Action()
        /** SDP ve ICE el sıkışması. */
        data object Negotiate : Action()
        /** Oturumu kapat ([delayMs] sonra baştan başla; null ise durul). */
        data class Retry(val delayMs: Long?) : Action()
        data object Nothing : Action()
    }

    /** Yayın durunca kullanıcıya gösterilen metnin türü (Windows'taki XboxStop.Classify ile aynı kurallar). */
    enum class StopKind { BUSY, CONSOLE_UNAVAILABLE, OTHER }

    @Volatile var phase: Phase = Phase.Idle
        private set

    /** Ardışık başarısız deneme sayısı. */
    private var failures = 0
    private var streamingSince = 0L

    fun start(): Action {
        if (phase == Phase.Stopped) return Action.Nothing
        phase = Phase.Starting
        return Action.Play
    }

    fun played(): Action {
        if (phase != Phase.Starting) return Action.Nothing
        phase = Phase.Provisioning(0, false)
        return Action.PollState(0)
    }

    /** `/state` yanıtı geldi. */
    fun status(state: String, errorDetails: String?): Action {
        val current = phase as? Phase.Provisioning ?: return Action.Nothing
        // Konsol yayını kendisi reddetti: yeniden denemek konsolu yeniden tetikler, denenmez.
        if (state == "Failed" || (state != "Provisioned" && hasErrorDetails(errorDetails)))
            return fail(classifyFailure(errorDetails), errorDetails ?: "Xbox yayını açılamadı", permanent = true)
        return when (state) {
            "Provisioned" -> {
                phase = Phase.Negotiating
                Action.Negotiate
            }
            "ReadyToConnect" -> if (!current.connectSent) {
                phase = current.copy(connectSent = true)
                Action.Connect
            } else poll(current)
            else -> poll(current)
        }
    }

    /** `/connect` gönderildi. */
    fun connected(): Action {
        val current = phase as? Phase.Provisioning ?: return Action.Nothing
        return poll(current)
    }

    private fun poll(current: Phase.Provisioning): Action {
        val polls = current.polls + 1
        if (polls >= maxPolls) return fail(XboxError.TIMEOUT, "Xbox yayını hazır olmayı beklerken zaman aşımına uğradı")
        phase = current.copy(polls = polls)
        return Action.PollState(pollIntervalMs)
    }

    /** İlk kare geldi. */
    fun streaming(): Boolean {
        if (phase != Phase.Negotiating) return false
        phase = Phase.Streaming
        streamingSince = clock()
        return true
    }

    /** [permanent]: konsol yayını reddetti (`Failed` ya da `errorDetails`); yeniden denenmez. */
    fun fail(kind: XboxError, message: String, permanent: Boolean = false): Action {
        if (phase == Phase.Stopped) return Action.Nothing
        // Yayın en az [healthyStreamMs] sürdüyse bu kopma yeni bir dizinin ilkidir.
        if (streamingSince > 0 && clock() - streamingSince >= healthyStreamMs) failures = 0
        streamingSince = 0
        failures++
        val retry = !permanent && kind !in FATAL && failures <= retryDelaysMs.size
        phase = Phase.Failed(kind, message, retry, if (retry) failures else 0)
        return Action.Retry(if (retry) retryDelaysMs[failures - 1] else null)
    }

    fun stop() {
        phase = Phase.Stopped
    }

    companion object {
        /** Yeniden denemenin işe yaramadığı hatalar: kullanıcı bir şey yapmalı. */
        val FATAL = setOf(XboxError.SIGN_IN_REQUIRED, XboxError.NO_XBOX_ACCOUNT)

        /** `errorDetails` gerçek bir hata mı (boş nesne ya da tüm alanları null olan nesne sayılmaz). */
        fun hasErrorDetails(details: String?): Boolean {
            val text = details?.replace(" ", "").orEmpty()
            if (text.isEmpty() || text == "{}" || text == "null") return false
            return !Regex("""^\{("[^"]*":(null|""),?)*\}$""").matches(text)
        }

        /** Kullanıcı metninde gösterilen ham nedenin en çok uzunluğu (Xbox hizmeti uzun JSON dönebilir). */
        const val REASON_LIMIT = 120

        /**
         * Denemeler bitince ya da konsol yayını reddedince hangi metin gösterilir. Ham neden ayrıntıya bakılır: ilk kare
         * gelmeyince de CONSOLE_UNAVAILABLE sayılır ama o durumda "Xbox'a ulaşılamadı" yanlış olur.
         */
        fun stopKind(kind: XboxError, detail: String?): StopKind {
            val text = detail.orEmpty()
            return when {
                kind == XboxError.BUSY || text.contains("InUse", true) || text.contains("Busy", true) ||
                    text.contains("AlreadyStreaming", true) -> StopKind.BUSY
                text.contains("Offline", true) || text.contains("NotFound", true) || text.contains("Unavailable", true) ||
                    text.contains("PowerOff", true) || text.contains("StreamingDisabled", true) -> StopKind.CONSOLE_UNAVAILABLE
                else -> StopKind.OTHER
            }
        }

        /** Ham nedeni tek satıra indirir ve [REASON_LIMIT] karakterde keser. */
        fun shortReason(detail: String?, fallback: String): String {
            val line = detail?.trim()?.replace(Regex("\\s+"), " ").takeUnless { it.isNullOrEmpty() } ?: fallback
            return if (line.length <= REASON_LIMIT) line else line.take(REASON_LIMIT - 1) + "…"
        }

        /** `errorDetails` içinden anlaşılan neden. */
        fun classifyFailure(details: String?): XboxError {
            val text = details.orEmpty()
            return when {
                text.contains("InUse", true) || text.contains("Busy", true) || text.contains("AlreadyStreaming", true) -> XboxError.BUSY
                text.contains("Offline", true) || text.contains("NotFound", true) || text.contains("Unavailable", true) ||
                    text.contains("PowerOff", true) || text.contains("StreamingDisabled", true) -> XboxError.CONSOLE_UNAVAILABLE
                else -> XboxError.CONSOLE_UNAVAILABLE
            }
        }
    }
}

/** Ömür boyu tanı sayacını korurken her yeni WebRTC bağlantısının ilk karesini ayrı tanır. */
internal class XboxFrameCounter {
    private val total = AtomicLong()
    private val lock = Any()
    private var currentSession: Session? = null
    private var currentSessionFrames = 0L

    class Session internal constructor()

    val totalFrames: Long get() = total.get()

    fun beginSession(): Session = synchronized(lock) {
        Session().also {
            currentSession = it
            currentSessionFrames = 0
        }
    }

    fun endSession(session: Session) {
        synchronized(lock) {
            if (currentSession === session) {
                currentSession = null
                currentSessionFrames = 0
            }
        }
    }

    fun recordFrame(session: Session): Long? = synchronized(lock) {
        if (currentSession !== session) return null
        total.incrementAndGet()
        ++currentSessionFrames
    }

    fun framesInSession(session: Session): Long = synchronized(lock) {
        if (currentSession === session) currentSessionFrames else 0
    }

    fun runIfCurrent(session: Session, action: () -> Unit) {
        synchronized(lock) {
            if (currentSession === session) action()
        }
    }
}
