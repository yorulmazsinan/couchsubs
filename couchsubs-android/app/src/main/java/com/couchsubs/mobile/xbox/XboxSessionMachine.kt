// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import java.util.Locale
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
    /**
     * SERVICE_NOT_READY: Xbox uzaktan oynatma hizmetini başlatamadı ("Timed out waiting for Cloud Streaming Service to be
     * ready", 0x8007139F); START_FAILED: Xbox bilinmeyen bir hata koduyla yayını reddetti (#871).
     */
    enum class StopKind { BUSY, CONSOLE_UNAVAILABLE, NO_PICTURE, SERVICE_NOT_READY, START_FAILED, OTHER }

    @Volatile var phase: Phase = Phase.Idle
        private set

    /** Ardışık başarısız deneme sayısı. */
    private var failures = 0
    private var streamingSince = 0L
    /** Ardışık, Xbox'tan tek kare gelmeden biten bağlantılar. */
    private var noPictureConnections = 0

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
        noPictureConnections = 0
        return true
    }

    /**
     * [permanent]: konsol yayını reddetti (`Failed` ya da `errorDetails`); yeniden denenmez. [XboxError.NO_FIRST_FRAME]
     * (bağlantı kuruldu, Xbox tek kare göndermedi) ayrıca sayılır: [MAX_NO_PICTURE_ATTEMPTS] ardışık bağlantıda görüntü
     * gelmezse durulur. Eskiden her biri ~60 sn sürüp Xbox'ta "uzaktan oynatma başlatıldı / durduruldu" bildirimiyle
     * dört kez açılıp kapanıyordu (Windows'taki XboxRetryPlan ile aynı).
     */
    fun fail(kind: XboxError, message: String, permanent: Boolean = false): Action {
        if (phase == Phase.Stopped) return Action.Nothing
        // Yayın en az [healthyStreamMs] sürdüyse bu kopma yeni bir dizinin ilkidir.
        if (streamingSince > 0 && clock() - streamingSince >= healthyStreamMs) failures = 0
        streamingSince = 0
        failures++
        if (kind == XboxError.NO_FIRST_FRAME) noPictureConnections++
        // Xbox uzaktan oynatma hizmetini başlatamadı (HTTP hatası olarak gelse de): yeniden denemek işe yaramaz (#871).
        val retry = !permanent && !isPermanent(message) && kind !in FATAL && failures <= retryDelaysMs.size && noPictureConnections < MAX_NO_PICTURE_ATTEMPTS
        phase = Phase.Failed(kind, message, retry, if (retry) failures else 0)
        return Action.Retry(if (retry) retryDelaysMs[failures - 1] else null)
    }

    fun stop() {
        phase = Phase.Stopped
    }

    companion object {
        /** Yeniden denemenin işe yaramadığı hatalar: kullanıcı bir şey yapmalı. */
        val FATAL = setOf(XboxError.SIGN_IN_REQUIRED, XboxError.NO_XBOX_ACCOUNT)

        /** Xbox'tan hiç görüntü gelmeyen bu kadar ardışık bağlantıdan sonra yeniden denenmez. */
        const val MAX_NO_PICTURE_ATTEMPTS = 2

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
                kind == XboxError.NO_FIRST_FRAME -> StopKind.NO_PICTURE
                kind == XboxError.BUSY || text.contains("InUse", true) || text.contains("Busy", true) ||
                    text.contains("AlreadyStreaming", true) -> StopKind.BUSY
                text.contains("Cloud Streaming Service", true) || errorCode(text) == SERVICE_NOT_READY_CODE -> StopKind.SERVICE_NOT_READY
                text.contains("Offline", true) || text.contains("NotFound", true) || text.contains("Unavailable", true) ||
                    text.contains("PowerOff", true) || text.contains("StreamingDisabled", true) -> StopKind.CONSOLE_UNAVAILABLE
                errorCode(text) != null -> StopKind.START_FAILED
                else -> StopKind.OTHER
            }
        }

        /**
         * "Timed out waiting for Cloud Streaming Service to be ready" hatasının kodu: Xbox'ın verdiği -2147019873, HRESULT
         * 0x8007139F (Win32 5023, ERROR_INVALID_STATE).
         */
        const val SERVICE_NOT_READY_CODE = "0x8007139F"

        /**
         * Bu neden yeniden denenmez: Xbox kendi hizmetini başlatamıyor, yeniden denemek yalnız Xbox'ta "uzaktan oynatma
         * başlatıldı / durduruldu" bildirimini tekrarlar; Xbox'ı kullanıcının yeniden başlatması gerekir.
         */
        fun isPermanent(reason: String?): Boolean = stopKind(XboxError.SERVICE, reason) == StopKind.SERVICE_NOT_READY

        private val AGENT_CODE = Regex("""Agent\s*:\s*(-?\d+)""")
        private val HEX_CODE = Regex("""\b0[xX]([0-9A-Fa-f]{8})\b""")
        private val CODE_FIELD = Regex(""""(?:code|errorCode|hresult)"\s*:\s*"?(-?[A-Za-z0-9_.]+)""")
        private val MESSAGE_FIELD = Regex(""""(?:message|errorMessage)"\s*:\s*"((?:[^"\\]|\\.)*)"""")
        private val JSON_ESCAPE = Regex("""\\(.)""")

        /**
         * Xbox hizmetinin hata nesnesindeki (errorDetails ya da HTTP gövdesi) kod. `Agent : -2147019873 : …` ve 0x… biçimi
         * HRESULT olarak (0x8007139F), yoksa `"code"` alanı olduğu gibi; bulunamazsa null.
         */
        fun errorCode(reason: String?): String? {
            if (reason.isNullOrEmpty()) return null
            AGENT_CODE.find(reason)?.let { return hresult(it.groupValues[1]) }
            HEX_CODE.find(reason)?.let { return "0x" + it.groupValues[1].uppercase() }
            CODE_FIELD.find(reason)?.groupValues?.get(1)?.takeIf { it != "null" }?.let { return hresult(it) }
            return null
        }

        /** Hata nesnesindeki `"message"` metni (JSON kaçışları açılmış); yoksa null. */
        fun errorMessage(reason: String?): String? {
            val raw = reason?.let { MESSAGE_FIELD.find(it) }?.groupValues?.get(1) ?: return null
            return JSON_ESCAPE.replace(raw, "$1").takeUnless { it.isBlank() }
        }

        /** Ekrandaki metne giren neden: START_FAILED'da yalnız kod, OTHER'da JSON'suz kısa metin; ham neden yalnız günlüğe yazılır. */
        fun displayReason(detail: String?, kind: StopKind, fallback: String): String = when (kind) {
            StopKind.START_FAILED -> errorCode(detail) ?: fallback
            StopKind.OTHER -> {
                val brace = detail?.indexOf('{') ?: -1
                when {
                    brace < 0 -> shortReason(detail, fallback)
                    else -> shortReason(errorMessage(detail) ?: detail!!.substring(0, brace).trim(' ', ':'), fallback)
                }
            }
            else -> shortReason(detail, fallback)
        }

        /** Ondalık HRESULT (-2147019873 ya da 2147947423) 0x8007139F biçimine çevrilir; başka değer olduğu gibi kalır. */
        internal fun hresult(value: String): String {
            val number = value.toLongOrNull() ?: return value
            return when {
                number < 0 && number >= Int.MIN_VALUE -> String.format(Locale.ROOT, "0x%08X", number.toInt().toUInt().toLong())
                number in 0x8000_0000L..0xFFFF_FFFFL -> String.format(Locale.ROOT, "0x%08X", number)
                else -> value
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
