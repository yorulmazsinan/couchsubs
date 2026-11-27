// SPDX-License-Identifier: AGPL-3.0-only
// Xbox ev yayını (Beta): Windows'taki XboxStreamSession + player.html'in telefondaki karşılığı. Görüntü yerel
// libwebrtc'yle alınır; kareler OCR hattına doğrudan parlaklık (Y) düzlemi olarak gider (bkz. docs/superpowers/specs/
// 2026-11-16-telefon-xbox-design.md). Oyun sesi ayar açıksa telefonda çalınır (bkz. playAudio); mikrofon açılmaz,
// kumanda girdisi gönderilmez. İlk kareden sonra görüntü kesilirse (ICE DISCONNECTED'da takılı kalsa da) uyarı
// gösterilir ve oturum yeniden kurulur (XboxPictureWatch.kt).
package com.couchsubs.mobile.xbox

import android.content.Context
import android.media.AudioAttributes
import android.os.SystemClock
import android.util.Log
import com.couchsubs.mobile.R
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.remoteplay.DisconnectKind
import com.couchsubs.mobile.remoteplay.FrameSource
import com.couchsubs.mobile.remoteplay.SessionState
import com.couchsubs.mobile.remoteplay.VideoFrame
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SoftwareVideoEncoderFactory
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class XboxStreamSession(
    context: Context,
    private val auth: XboxAuth,
    private val console: XboxConsole,
    private val onFrame: (VideoFrame) -> Unit,
    private val onState: (SessionState) -> Unit,
    /** Hatayı kullanıcının dilinde anlatır (Türkçe/İngilizce metinler hizmette). */
    private val describe: (XboxError) -> String,
    /**
     * Oyunun sesi bu telefonda çalınır (Ayarlar > "Xbox sesini bu cihazda çal", varsayılan açık). Xbox uzaktan oynatma
     * sürerken sesi istemciye verip TV'yi susturabilir; kapalıyken ses hiçbir yerden gelmeyebilir. Mikrofon her durumda
     * kapalıdır, yerel ses parçası eklenmez: Xbox'a ses gönderilmez.
     */
    playAudio: Boolean = true,
) : FrameSource {
    /** Çeviri sürerken [setPlayAudio] ile değişir. */
    @Volatile private var playAudio = playAudio
    /** Xbox'tan gelen ses parçası ve ses birimi; ayar değişince yalnız bunlar açılıp kapatılır. */
    @Volatile private var audioTrack: MediaStreamTrack? = null
    @Volatile private var audioModule: JavaAudioDeviceModule? = null

    /**
     * "Xbox sesini bu cihazda çal" çeviri sürerken değişti: yalnız yerel ses açılır ya da kısılır, Xbox'a yeni oturum
     * açılmaz. Eskiden (Mac ve Windows'ta) ayar değişince yayın kapatılıp hemen yeniden açılıyordu; Xbox eski oturumu
     * bırakmadan gelen yeni istekte uzaktan oynatma hizmetini başlatamıyor, bağlantı geri gelmiyordu (#871).
     */
    override fun setPlayAudio(enabled: Boolean) {
        if (playAudio == enabled) return
        playAudio = enabled
        audioModule?.setSpeakerMute(!enabled)
        val track = audioTrack ?: return
        runCatching { track.setEnabled(enabled) }
        log(if (enabled) "oyun sesi açıldı (ayar, oturum sürüyor)" else "oyun sesi kapatıldı (ayar, oturum sürüyor)")
    }

    private companion object {
        const val TAG = "CouchSubsXbox"
        const val ICE_GATHER_MS = 5000L
        const val KEEPALIVE_MS = 30_000L
        /** El sıkışmadan sonra bu sürede kare gelmezse bağlantı "görüntü gelmedi" nedeniyle kapatılır. */
        const val FIRST_FRAME_MS = XboxFirstFrameWatch.FIRST_FRAME_LIMIT_MS
        /** ICE değişiminden sonra görüntü kanalı bu sürede açılmazsa bağlantı zaman aşımıyla kapatılır. */
        const val CONNECT_MS = XboxConnectWatch.CONNECT_LIMIT_MS
        /** OCR saniyede beş kez okur; her kareyi I420'ye çevirmeye gerek yok. */
        const val FRAME_INTERVAL_MS = 66L
        /** Kare onayları oynatıcıdaki gibi 16 ms'de bir paketlenir (Input.ts `_inputInterval`). */
        const val ACK_INTERVAL_MS = 16L
        /** İlk kare beklenirken anahtar kare ve tanı saatinin adımı (Windows'taki gibi). */
        const val WATCH_TICK_MS = 500L
    }

    private val appContext = context.applicationContext
    private val home = XboxHome(auth)
    private val machine = XboxSessionMachine()
    private val frameCounter = XboxFrameCounter()
    private var frameSession: XboxFrameCounter.Session? = null
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs Xbox").apply { isDaemon = true } }
    private val timers = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs Xbox timers").apply { isDaemon = true } }
    /**
     * Canlı tutma isteği (HTTPS, jeton yenilemesiyle birkaç saniye ve en çok 45 sn sürebilir) kendi iş parçacığında. Eskiden
     * 16 ms'lik kare onayıyla aynı tek iş parçacığındaydı: istek yavaşlayınca onaylar o süre boyunca gitmiyor, Xbox onay
     * alamayınca görüntü kanalını kapatıp "uzaktan yürütme durduruldu" diyordu.
     */
    private val network = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs Xbox canlı tutma").apply { isDaemon = true } }
    /** Süreç genelinde kapanış sırası ve kapatılamayan oturumlar (bkz. XboxCloseGate.kt). */
    private val closeGate = XboxCloseGate.shared
    private val stopped = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    @Volatile private var sessionId: String? = null
    @Volatile private var peer: PeerConnection? = null
    @Volatile private var factory: PeerConnectionFactory? = null
    @Volatile private var ended: CountDownLatch? = null
    @Volatile private var endReason: String? = null
    /** Bağlantıyı bitiren olayın türü ([endReason] ile birlikte yazılır): kapanma nedenini ve ekrandaki metni seçer. */
    @Volatile private var endKind: XboxError? = null
    @Volatile private var lastKind: XboxError? = null
    @Volatile private var keepalive: ScheduledFuture<*>? = null
    @Volatile private var lastConverted = 0L
    @Volatile private var firstFrameAt = 0L
    /** Son karenin ve son kare onayı paketinin anı (kapanma satırı için: Xbox kapattığında akış ve onay sürüyor muydu). */
    @Volatile private var lastFrameAt = 0L
    @Volatile private var lastAckAt = 0L
    /** Alıcıdan okuma hattına kare aktarımı ve süreleri (#1308, bkz. XboxFramePipe.kt). */
    private val pipeStats = XboxFramePipeStats()
    private val frameWorker = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs Xbox kare").apply { isDaemon = true } }
    private val handoff = XboxFrameHandoff(frameWorker, pipeStats) { frame -> if (!stopped.get()) onFrame(frame) }
    @Volatile private var pipeTask: ScheduledFuture<*>? = null
    /** Bu bağlantının çözücü durumu ve Xbox'ın SDP yanıtında seçtiği görüntü kodeği (tanı satırı için, #1252). */
    @Volatile private var decoderNote = XboxDecoderNote()
    @Volatile private var negotiatedCodec: String? = null
    /** Kare onayları (bkz. XboxFrameAcks.kt): el sıkışmadan sonra gönderilir. */
    private val acks = XboxFrameAckQueue()
    @Volatile private var acking = false
    @Volatile private var ackSequence = 0
    @Volatile private var acksSent = 0L
    @Volatile private var ackTask: ScheduledFuture<*>? = null
    /** Onay paketlerindeki anların sıfırı (oynatıcıdaki performance.now() gibi). */
    @Volatile private var clockStart = 0L
    /** Oturumda bir kez Crashlytics'e kopma özeti gider (nedeni sahadan görmek için). */
    private val endReported = AtomicBoolean(false)
    private val decoded = DecodedFrameListener { rtpMs, arrivedAt, decodedAt ->
        if (!acking) return@DecodedFrameListener
        acks.offer(XboxFrameAck(XboxFrameAckQueue.serverDataKey(rtpMs), arrivedAt - clockStart, decodedAt - clockStart))
    }
    private val channels = HashMap<String, DataChannel>()
    /** İlk kare gelene kadar anahtar kare isteği ve tanı satırı (bkz. XboxFirstFrame.kt). */
    private val watchLock = Any()
    @Volatile private var watch: XboxFirstFrameWatch? = null
    @Volatile private var watchTask: ScheduledFuture<*>? = null
    @Volatile private var connectedAt = 0L
    @Volatile private var videoTrack: VideoTrack? = null

    override val framesReceived: Long get() = frameCounter.totalFrames

    /** Oturum yeniden denemeyi bıraktı: ana ekranda "Yeniden bağlan" hemen görünür (iPhone'daki hasGivenUp ile aynı). */
    @Volatile private var gaveUp = false
    override val hasGivenUp: Boolean get() = gaveUp

    /** Bu bağlantının görüntü bekçisi; canlı tutma "görüntü akıyor mu" diye buna bakar. */
    @Volatile private var pictureWatch: XboxPictureWatch? = null

    override fun start() {
        if (!started.compareAndSet(false, true)) return
        worker.execute(::run)
    }

    /**
     * Oturum durur: bağlantı kapatılır ve oturum Xbox hizmetinde kapatılır (DELETE). Kapanış [XboxCloseGate]'e kaydedilir;
     * hemen ardından açılan yeni oturum ("Yeniden bağlan") `play`dan önce bunun bitmesini bekler. Kapanış işi süren
     * döngüden sonra çalışır (tek iş parçacığı): döngünün o sırada açtığı oturum da kapanmış olur.
     */
    override fun dispose() {
        if (!stopped.compareAndSet(false, true)) return
        machine.stop()
        ended?.countDown()
        log("oturum durduruluyor: bağlantı ve Xbox oturumu kapatılıyor")
        val closing = closeGate.begin()
        try {
            worker.execute {
                try {
                    closePeer()
                    stopRemote()
                } finally {
                    closing.done()
                }
                onState(SessionState.Disconnected(DisconnectKind.STOPPED))
            }
        } catch (error: java.util.concurrent.RejectedExecutionException) {
            closing.done()
        }
        worker.shutdown()
        timers.shutdown()
        network.shutdown()
        handoff.close()
        frameWorker.shutdown()
    }

    private fun log(text: String) {
        Log.i(TAG, text)
        Backend.breadcrumb("xbox: $text")
    }

    private fun run() {
        log("konsol: ${console.name}")
        while (!stopped.get()) {
            var action: XboxSessionMachine.Action = machine.start()
            // Makine `/state` yanıtında kendisi karar verdiyse (Failed, errorDetails) aynı hata yeniden sayılmaz.
            var decided: XboxSessionMachine.Action? = null
            onState(SessionState.Connecting)
            try {
                // Önceki oturum (eski nesne, "Yeniden bağlan") kapanırken yenisi açılmaz: Xbox eskisini açık sayıyordu.
                closeGate.waitForPending()?.let { log(it.line) }
                for (stale in closeGate.takeStale()) {
                    log("önceki oturum Xbox'ta açık kalmış olabilir: yeni oturumdan önce kapatılıyor (${stale.take(8)}…)")
                    closeRemote(stale)
                }
                if (stopped.get()) break
                log("oturum açılıyor: ${console.name}")
                sessionId = home.play(console.id)
                log("play yanıtı: oturum ${sessionId?.take(8)}…")
                action = machine.played()
                loop@ while (!stopped.get()) {
                    when (val step = action) {
                        is XboxSessionMachine.Action.PollState -> {
                            if (step.delayMs > 0) Thread.sleep(step.delayMs)
                            val status = home.state(requireNotNull(sessionId))
                            action = machine.status(status.state, status.errorDetails)
                            if (status.state != "Provisioning") log("durum: ${status.state}")
                            if (status.errorDetails != null) log("errorDetails: ${status.errorDetails}")
                        }
                        XboxSessionMachine.Action.Connect -> {
                            home.connect(requireNotNull(sessionId))
                            log("connect: başarılı")
                            action = machine.connected()
                        }
                        XboxSessionMachine.Action.Negotiate -> {
                            negotiate(requireNotNull(sessionId))
                            break@loop
                        }
                        is XboxSessionMachine.Action.Retry -> {
                            decided = step
                            throw XboxException((machine.phase as? XboxSessionMachine.Phase.Failed)?.kind
                                ?: XboxError.SERVICE, (machine.phase as? XboxSessionMachine.Phase.Failed)?.message ?: "Xbox")
                        }
                        else -> break@loop
                    }
                }
                if (!stopped.get()) {
                    // Bağlantı kuruldu ama Xbox tek kare göndermeden kapattı: "görüntü gelmedi" sayılır (iki bağlantıda durulur).
                    val noFirstFrame = connectedAt > 0 && frameSession?.let { frameCounter.framesInSession(it) } == 0L
                    throw XboxException(if (noFirstFrame) XboxError.NO_FIRST_FRAME else endKind ?: XboxError.NETWORK, endReason ?: "Xbox görüntü bağlantısı kapandı")
                }
            } catch (error: InterruptedException) {
                if (stopped.get()) break
            } catch (error: XboxException) {
                action = decided ?: machine.fail(error.kind, error.message ?: "")
                report(error.kind, error.message, (action as? XboxSessionMachine.Action.Retry)?.delayMs)
            } catch (error: Exception) {
                action = machine.fail(XboxError.SERVICE, error.message ?: error.javaClass.simpleName)
                report(XboxError.SERVICE, error.message, (action as? XboxSessionMachine.Action.Retry)?.delayMs)
            } finally {
                summarize()
                closePeer()
                stopRemote()
            }
            if (stopped.get()) break
            val retry = (action as? XboxSessionMachine.Action.Retry)?.delayMs ?: break
            try {
                Thread.sleep(retry)
            } catch (error: InterruptedException) {
                break
            }
        }
    }

    /**
     * Bağlantı bitince: kaç kare geldi, kaç onay gitti, ilk kareden kaç saniye sonra ve neden bitti. "Görüntü hiç
     * gelmedi" (ilk kare sınırı) ile "görüntü geldi, Xbox kapattı" (onay) birbirinden bu satırla ayrılır.
     */
    private fun summarize() {
        val session = frameSession ?: return
        val frames = frameCounter.framesInSession(session)
        val now = SystemClock.elapsedRealtime()
        val lived = if (firstFrameAt > 0) "${(now - firstFrameAt) / 1000} sn" else "ilk kare yok"
        val reason = endReason ?: lastError ?: "durduruldu"
        val cause = lastKind?.let { " (${XboxEndCause.of(it).text})" } ?: ""
        val text = "bağlantı bitti$cause: $reason; kare $frames, onay $acksSent, ilk kareden sonra $lived"
        log(text)
        if (!stopped.get() && endReported.compareAndSet(false, true)) Backend.recordError(XboxSessionEnded(text))
    }

    @Volatile private var lastError: String? = null
    /** Son tanıda ses geliyordu, görüntü 0 bayttı ([XboxStreamStats.audioOnly], #1432); ilk kare sınırının nedenine girer. */
    @Volatile private var lastAudioOnly = false

    private fun report(kind: XboxError, detail: String?, retryDelayMs: Long?) {
        lastError = "$kind: $detail"
        lastKind = kind
        if (stopped.get()) return
        // Durum bildirilmeden önce: ana ekran "Yeniden bağlan"ı bu bildirimle hemen gösterir.
        if (retryDelayMs == null) gaveUp = true
        log("kopma ($kind): $detail")
        log(XboxEndCause.line(kind, detail))
        if (kind == XboxError.NO_FIRST_FRAME && XboxSessionMachine.isAudioOnly(detail)) {
            log(XboxSessionMachine.AUDIO_ONLY_LINE)
        } else if (kind == XboxError.NO_FIRST_FRAME) {
            log("Xbox görüntü göndermedi: bağlantı kuruldu ama tek kare gelmedi. Xbox'ta Ayarlar › Cihazlar ve bağlantılar › " +
                "Uzak özellikler açık mı, Xbox kablolu mu? Tanı satırlarında video bayt 0 ise Xbox hiç görüntü kodlamıyor")
        }
        val failed = machine.phase as? XboxSessionMachine.Phase.Failed
        when {
            failed == null || failed.willRetry -> {
                failed?.let { log(XboxEndCause.retryLine(it.attempt, machine.maxRetries, retryDelayMs ?: 0L)) }
                onState(SessionState.Disconnected(DisconnectKind.OTHER, describe(kind)))
            }
            // Giriş gerekiyor: kullanıcının yapacağı iş hizmetin metninde.
            kind in XboxSessionMachine.FATAL -> onState(SessionState.Disconnected(DisconnectKind.OTHER, describe(kind)))
            else -> {
                // Denemeler bitti ya da konsol yayını reddetti: yayın durur, yeniden denenmez.
                val limited = machine.dropLimitReached
                log(if (limited) XboxEndCause.LIMIT_LINE else "yeniden denenmiyor, yayın durdu")
                // Ham neden (Xbox'ın JSON hata nesnesi) yukarıda günlüğe yazıldı; ekranda yalnız anlaşılır metin ve kod (#871).
                // Sessiz yeniden bağlanma sınırı dolduysa: "Xbox bağlantısı koptu, Yeniden bağlan" (#1252).
                val stop = if (limited) XboxSessionMachine.StopKind.DROPPED else XboxSessionMachine.stopKind(kind, detail)
                val text = when (stop) {
                    XboxSessionMachine.StopKind.BUSY -> appContext.getString(R.string.xbox_stopped_busy)
                    XboxSessionMachine.StopKind.CONSOLE_UNAVAILABLE -> appContext.getString(R.string.xbox_stopped_console)
                    XboxSessionMachine.StopKind.NO_PICTURE -> appContext.getString(R.string.xbox_stopped_no_picture)
                    XboxSessionMachine.StopKind.STUCK_PICTURE -> appContext.getString(R.string.xbox_stopped_stuck_picture)
                    XboxSessionMachine.StopKind.SERVICE_NOT_READY -> appContext.getString(R.string.xbox_stopped_service)
                    XboxSessionMachine.StopKind.DROPPED -> appContext.getString(R.string.xbox_stopped_dropped)
                    XboxSessionMachine.StopKind.START_FAILED ->
                        appContext.getString(R.string.xbox_stopped_code, XboxSessionMachine.displayReason(detail, stop, kind.name))
                    XboxSessionMachine.StopKind.OTHER ->
                        appContext.getString(R.string.xbox_connection_lost, XboxSessionMachine.displayReason(detail, stop, kind.name))
                }
                onState(SessionState.Disconnected(DisconnectKind.OTHER, text))
            }
        }
    }

    private fun stopRemote() {
        val id = sessionId ?: return
        sessionId = null
        closeRemote(id)
    }

    /**
     * Oturumu Xbox hizmetinde kapatır (birkaç deneme). Kapanmazsa bir sonraki `play`dan önce yeniden denenir; sonuç
     * günlüğe yazılır (eskiden hata sessizce yutuluyordu).
     */
    private fun closeRemote(id: String) {
        val error = try {
            home.close(id)
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            "kesildi"
        }
        if (error == null) {
            log("oturum kapatıldı: ${id.take(8)}…")
            return
        }
        closeGate.addStale(id)
        log("oturum kapatılamadı (${XboxHome.CLOSE_DELAYS_MS.size} deneme): ${XboxSessionMachine.shortReason(error, "?")}; yeni oturumdan önce yeniden denenecek")
    }

    /** Bağlantıyı bitiren ilk olay kaydedilir (neden ve türü); sonrakiler ilkinin yerine geçmez. */
    @Synchronized
    private fun end(reason: String, kind: XboxError) {
        if (endReason != null) return
        endReason = reason
        endKind = kind
    }

    // --- WebRTC ---

    private fun createFactory(): PeerConnectionFactory {
        WebRtc.initialize(appContext)
        // Mikrofon hiç açılmaz. Oyun sesi ayar açıksa medya sesi olarak çalınır (telefonun medya ses düzeyiyle,
        // görüşme sesi gibi kulaklığa değil); kapalıysa eski davranış: ses susturulur.
        val audio = JavaAudioDeviceModule.builder(appContext)
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_GAME)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build())
            .setUseStereoOutput(true)
            .createAudioDeviceModule().apply {
                setSpeakerMute(!playAudio)
                setMicrophoneMute(true)
            }
        // Yerel nesne fabrikada yaşar (release yalnız bu başvuruyu bırakır); susturma çeviri sürerken buradan değişir.
        audioModule = audio
        return PeerConnectionFactory.builder()
            .setAudioDeviceModule(audio)
            // EGL bağlamı yok: donanım çözücüsü kareyi bellekte verir, Y düzlemi doğrudan okunur.
            // Kare onayı için çözülen karenin RTP zaman damgası gerekir; çözücü seçimi DefaultVideoDecoderFactory'ninki.
            .setVideoDecoderFactory(XboxDecoderFactory(decoded, XboxDecoderNote().also { decoderNote = it }))
            .setVideoEncoderFactory(SoftwareVideoEncoderFactory())
            .createPeerConnectionFactory()
            .also { audio.release() }
    }

    private fun negotiate(id: String) {
        val negotiatedFrames = frameCounter.beginSession()
        frameSession = negotiatedFrames
        // İlk kareden sonra görüntü kesilirse uyarı ve yeniden kurma (kareler ve ICE olayları buraya yazılır).
        val watchPicture = XboxPictureWatch().also { pictureWatch = it }
        // Alıcı libwebrtc'nin iş parçacığındadır ve hemen dönmelidir (#1308): kare yalnız önceden ayrılmış arabelleğe
        // kopyalanıp okuma hattının iş parçacığına verilir; okuma hattının işi orada yapılır (bkz. XboxFramePipe.kt).
        val sink = VideoSink { frame ->
            val started = System.nanoTime()
            try {
                if (stopped.get()) return@VideoSink
                val sessionFrames = frameCounter.recordFrame(negotiatedFrames) ?: return@VideoSink
                val now = SystemClock.elapsedRealtime()
                lastFrameAt = now
                watchPicture.frameArrived(now)
                if (sessionFrames == 1L) {
                    firstFrameAt = now
                    val waited = watch?.let { current ->
                        current.frameArrived()
                        ", bağlantıdan ${"%.1f".format(java.util.Locale.ROOT, (now - connectedAt) / 1000.0)} sn sonra, keyframe isteği ${current.keyframesRequested}"
                    } ?: ""
                    log("ilk kare ${frame.buffer.width}x${frame.buffer.height}$waited")
                    frameCounter.runIfCurrent(negotiatedFrames) {
                        if (!stopped.get() && machine.streaming()) onState(SessionState.Streaming)
                    }
                }
                if (now - lastConverted < FRAME_INTERVAL_MS) return@VideoSink
                lastConverted = now
                if (frameCounter.framesInSession(negotiatedFrames) <= 0) return@VideoSink
                val i420 = frame.buffer.toI420() ?: return@VideoSink
                try {
                    handoff.offer(i420.width, i420.height, i420.dataY, i420.strideY, i420.dataU, i420.strideU, i420.dataV, i420.strideV)
                } finally {
                    i420.release()
                }
            } finally {
                pipeStats.sink(System.nanoTime() - started)
            }
        }
        val done = CountDownLatch(1).also { ended = it }
        endReason = null
        endKind = null
        lastError = null
        lastKind = null
        firstFrameAt = 0L
        lastFrameAt = 0L
        lastAckAt = 0L
        negotiatedCodec = null
        startPipeLog()
        connectedAt = 0L
        acking = false
        acks.clear()
        ackSequence = 0
        acksSent = 0L
        clockStart = SystemClock.elapsedRealtime()
        val pcFactory = createFactory().also { factory = it }
        log(AvcHighProfile.note)
        val gathered = CountDownLatch(1)
        val local = ArrayList<XboxIceCandidate>()
        val config = PeerConnection.RTCConfiguration(listOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun1.l.google.com:19302").createIceServer(),
        )).apply { sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN }
        val connection = pcFactory.createPeerConnection(config, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
                log("ICE: $state")
                watchPicture.iceChanged(when (state) {
                    PeerConnection.IceConnectionState.CONNECTED, PeerConnection.IceConnectionState.COMPLETED -> XboxPictureWatch.Ice.CONNECTED
                    PeerConnection.IceConnectionState.DISCONNECTED -> XboxPictureWatch.Ice.DISCONNECTED
                    PeerConnection.IceConnectionState.FAILED -> XboxPictureWatch.Ice.FAILED
                    else -> XboxPictureWatch.Ice.OTHER
                }, SystemClock.elapsedRealtime())
            }
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
                if (state == PeerConnection.IceGatheringState.COMPLETE) gathered.countDown()
            }
            override fun onIceCandidate(candidate: IceCandidate) {
                synchronized(local) { local += XboxIceCandidate(candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex) }
            }
            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
            override fun onAddStream(stream: MediaStream?) {}
            override fun onRemoveStream(stream: MediaStream?) {}
            override fun onDataChannel(channel: DataChannel?) {}
            override fun onRenegotiationNeeded() {}
            override fun onConnectionChange(state: PeerConnection.PeerConnectionState?) {
                log("bağlantı: $state")
                if (!stopped.get() && (state == PeerConnection.PeerConnectionState.FAILED || state == PeerConnection.PeerConnectionState.CLOSED)) {
                    log("WebRTC bağlantısı kapandı ($state): ${closeContext()}")
                }
                if (state == PeerConnection.PeerConnectionState.FAILED) {
                    end("Xbox WebRTC bağlantısı kesildi (ICE failed)", XboxError.NETWORK)
                    done.countDown()
                } else if (state == PeerConnection.PeerConnectionState.CLOSED) {
                    end("Xbox WebRTC bağlantısını kapattı", XboxError.SERVER_CLOSED)
                    done.countDown()
                }
            }
        }) ?: throw XboxException(XboxError.SERVICE, "WebRTC bağlantısı kurulamadı")
        peer = connection

        // Oynatıcıdaki sıra: önce veri kanalları, sonra ses (gönder-al) ve görüntü (yalnız al).
        for ((name, protocol) in XboxChannels.CHANNELS) {
            val init = DataChannel.Init().apply {
                ordered = true
                this.protocol = protocol
            }
            val channel = connection.createDataChannel(name, init) ?: throw XboxException(XboxError.SERVICE, "Veri kanalı açılamadı: $name")
            synchronized(channels) { channels[name] = channel }
            channel.registerObserver(ChannelObserver(name, channel, done))
        }
        val audio = connection.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.SEND_RECV))
        val video = connection.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY))
        audioTrack = audio?.receiver?.track()
        audio?.receiver?.track()?.setEnabled(playAudio)
        audioModule?.setSpeakerMute(!playAudio)
        log(if (playAudio) "oyun sesi bu telefonda çalınır" else "oyun sesi kapalı (ayar)")
        val track = (video?.receiver?.track() as? VideoTrack)
            ?: throw XboxException(XboxError.SERVICE, "Görüntü alıcısı kurulamadı")
        track.addSink(sink)
        videoTrack = track

        val offer = await<SessionDescription>("SDP teklifi") { result -> connection.createOffer(result.creating(), MediaConstraints()) }
        val munged = SessionDescription(SessionDescription.Type.OFFER, XboxChannels.mungeOffer(offer.description))
        await<Unit>("yerel SDP") { result -> connection.setLocalDescription(result.setting(), munged) }
        log("SDP gönderiliyor")
        val answer = home.sdp(id, munged.description)
        negotiatedCodec = XboxSdp.negotiated(answer)
        log(XboxSdp.summary(munged.description, answer))
        await<Unit>("Xbox SDP") { result -> connection.setRemoteDescription(result.setting(), SessionDescription(SessionDescription.Type.ANSWER, answer)) }
        // Yerel adaylar toplanana kadar (en çok 5 sn) beklenir; yavaş ağ bağdaştırıcılarının adayları da gitsin.
        gathered.await(ICE_GATHER_MS, TimeUnit.MILLISECONDS)
        val candidates = synchronized(local) { local.toList() }
        log("ICE: ${candidates.size} yerel aday gönderiliyor")
        val remote = home.ice(id, candidates)
        var added = 0
        for (candidate in remote) {
            val line = candidate.sdpLine ?: continue
            if (connection.addIceCandidate(IceCandidate(candidate.sdpMid ?: "", candidate.sdpMLineIndex, line))) added++
        }
        log("ICE: Xbox'tan ${remote.size} aday, $added eklendi")

        val negotiatedAt = SystemClock.elapsedRealtime()
        while (!stopped.get()) {
            if (done.await(1, TimeUnit.SECONDS)) break
            val now = SystemClock.elapsedRealtime()
            val connected = connectedAt
            // Görüntü kanalı açılmadı (ICE Wi-Fi'da kurulamadı): ilk kare sınırı kanal açılınca başlar.
            if (connected == 0L && now - negotiatedAt > CONNECT_MS) {
                val reason = "Xbox ile görüntü bağlantısı ${CONNECT_MS / 1000} sn içinde kurulamadı (ICE)"
                end(reason, XboxError.TIMEOUT)
                throw XboxException(XboxError.TIMEOUT, reason)
            }
            if (frameCounter.framesInSession(negotiatedFrames) == 0L && connected > 0L && now - connected > FIRST_FRAME_MS) {
                val reason = XboxFirstFrameWatch.noPictureReason(lastAudioOnly)
                end(reason, XboxError.NO_FIRST_FRAME)
                throw XboxException(XboxError.NO_FIRST_FRAME, reason)
            }
            checkPicture(watchPicture)
        }
    }

    /**
     * Saniyede bir: ilk kareden sonra görüntü kesildiyse ana ekranda uyarı, uzun sürdüyse oturum kapatılır ve yeniden
     * denenir (bkz. XboxPictureWatch).
     */
    private fun checkPicture(watch: XboxPictureWatch) {
        when (val verdict = watch.tick(SystemClock.elapsedRealtime())) {
            XboxPictureVerdict.Fine -> {}
            XboxPictureVerdict.Warn -> {
                log("görüntü kesildi (${XboxPictureWatch.WARN_AFTER_MS / 1000} sn kare yok ya da ICE takıldı); toparlanması bekleniyor")
                onState(SessionState.Disconnected(DisconnectKind.OTHER, describe(XboxError.NO_PICTURE)))
            }
            XboxPictureVerdict.Recovered -> {
                log("görüntü yeniden geliyor")
                onState(SessionState.Streaming)
            }
            is XboxPictureVerdict.Stalled -> {
                log("${verdict.reason}; oturum yeniden kuruluyor")
                end(verdict.reason, XboxError.NO_PICTURE)
                throw XboxException(XboxError.NO_PICTURE, verdict.reason)
            }
        }
    }

    private inner class ChannelObserver(private val name: String, private val channel: DataChannel, private val done: CountDownLatch) : DataChannel.Observer {
        override fun onBufferedAmountChange(previous: Long) {}

        override fun onStateChange() {
            val state = channel.state()
            log("kanal $name: $state")
            when {
                state == DataChannel.State.OPEN && name == "message" -> sendText("message", XboxChannels.HANDSHAKE)
                state == DataChannel.State.OPEN && name == "input" -> {
                    startKeepalive()
                    startWatch()
                }
                state == DataChannel.State.CLOSED && name == "input" -> {
                    if (!stopped.get()) log("input kanalı kapandı (Xbox görüntü kanalını kapattı): ${closeContext()}")
                    end("Xbox görüntü kanalını kapattı", XboxError.SERVER_CLOSED)
                    done.countDown()
                }
            }
        }

        override fun onMessage(buffer: DataChannel.Buffer) {
            val bytes = ByteArray(buffer.data.remaining()).also { buffer.data.get(it) }
            if (buffer.binary) {
                // input kanalından gelenler: 16 = ServerMetadata (baytlarıyla, #1416), 128 = titreşim (her an gelir, yazılmaz).
                XboxChannels.describeInput(bytes)?.let { log("kanal $name: $it") }
                return
            }
            val text = String(bytes, Charsets.UTF_8)
            if (name != "message" || !XboxChannels.isHandshakeAck(text)) {
                // Xbox'ın kapatma bildirimi gibi iletiler (ör. TransactionStart) burada görünür.
                log("kanal $name: ${text.take(300)}")
                return
            }
            log("el sıkışma tamam")
            sendText("control", XboxChannels.AUTHORIZATION)
            sendText("control", XboxChannels.GAMEPAD_ADDED)
            send("input", XboxChannels.clientMetadataPacket(0, (SystemClock.elapsedRealtime() - clockStart).toDouble()), binary = true)
            XboxChannels.configurationMessages().forEach { sendText("message", it) }
            startAcks()
        }
    }

    private fun sendText(name: String, text: String) = send(name, text.toByteArray(Charsets.UTF_8), binary = false)

    private fun send(name: String, bytes: ByteArray, binary: Boolean) {
        val channel = synchronized(channels) { channels[name] } ?: return
        if (channel.state() != DataChannel.State.OPEN) return
        channel.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), binary))
    }

    /** El sıkışmadan sonra çözülen karelerin onayı 16 ms'de bir `input` kanalına gider (oynatıcıdaki döngü). */
    private fun startAcks() {
        ackTask?.cancel(false)
        acks.clear()
        acking = true
        var previous = System.nanoTime()
        ackTask = timers.scheduleWithFixedDelay({
            // Döngünün turları arası (kare hattı satırında "onay aralığı"): iş parçacığı takılırsa Xbox onay alamaz.
            val tick = System.nanoTime()
            pipeStats.ackTick(tick - previous)
            previous = tick
            try {
                val frames = acks.drain()
                if (frames.isEmpty()) return@scheduleWithFixedDelay
                val sequence = ++ackSequence
                send("input", XboxChannels.frameAckPacket(sequence, (SystemClock.elapsedRealtime() - clockStart).toDouble(), frames), binary = true)
                acksSent += frames.size
                lastAckAt = SystemClock.elapsedRealtime()
                if (sequence == 1) log("kare onayı başladı")
            } catch (error: Exception) {
                log("kare onayı: ${error.message}")
            }
        }, ACK_INTERVAL_MS, ACK_INTERVAL_MS, TimeUnit.MILLISECONDS)
    }

    /**
     * Bağlantıdan (input kanalı açıldı) sonra 500 ms'de bir: görüntü gelene kadar kontrol kanalından anahtar kare
     * istenir, 10 sn'den sonra 10 sn'de bir getStats tanısı yazılır. İlk kare gelince durur.
     */
    private fun startWatch() {
        synchronized(watchLock) {
            watchTask?.cancel(false)
            val current = XboxFirstFrameWatch()
            watch = current
            lastAudioOnly = false
            connectedAt = SystemClock.elapsedRealtime()
            watchTask = timers.scheduleWithFixedDelay({ watchTick(current) }, 0, WATCH_TICK_MS, TimeUnit.MILLISECONDS)
        }
    }

    private fun watchTick(current: XboxFirstFrameWatch) {
        try {
            synchronized(watchLock) {
                // closePeer bu kilitle kanalları ve bağlantıyı kapatır; kapandıysa hiçbir şeye dokunulmaz.
                if (watch !== current) return
                val since = SystemClock.elapsedRealtime() - connectedAt
                val control = synchronized(channels) { channels["control"] }
                val ready = videoTrack != null && control?.state() == DataChannel.State.OPEN
                val step = current.tick(since, ready)
                if (step.requestKeyframe) {
                    if (current.keyframesRequested == 1) log("ilk kare bekleniyor: Xbox'tan anahtar kare isteniyor")
                    sendText("control", XboxFirstFrameWatch.KEYFRAME_REQUEST)
                }
                if (step.logStats) logStats(current, since)
                if (current.frameSeen) {
                    watchTask?.cancel(false)
                    watchTask = null
                }
            }
        } catch (error: Exception) {
            log("ilk kare tanısı: ${error.message}")
        }
    }

    private fun logStats(current: XboxFirstFrameWatch, since: Long) {
        val connection = peer ?: return
        val trackState = runCatching { videoTrack?.state()?.name }.getOrNull() ?: "yok"
        val picture = XboxStreamStats.picture(trackState)
        connection.getStats { report ->
            try {
                val stats = report.statsMap.values.filter { it.type in XboxStreamStats.TYPES }
                    .map { XboxStat(it.type, it.id, it.members) }
                if (!current.frameSeen && watch === current) lastAudioOnly = XboxStreamStats.audioOnly(stats)
                log(XboxStreamStats.describe(since, current.frameSeen, current.keyframesRequested, stats, picture,
                    negotiatedCodec, decoderNote.describe()))
            } catch (error: Exception) {
                log("ilk kare tanısı: ${error.message}")
            }
        }
    }

    /**
     * Tek başarısız canlı tutma isteği yayını bitirmez (görüntü akarken ağ bir an takılabilir); ardışık
     * [XboxKeepalive.MAX_FAILURES] hata ya da oturumun Xbox hizmetinde artık olmaması (404/410) bitirir ve oturum baştan
     * denenir (iPhone, Mac ve Windows'la aynı; eskiden telefonda hata yalnız günlüğe yazılıyordu).
     */
    private fun startKeepalive() {
        keepalive?.cancel(false)
        val counter = XboxKeepalive()
        val latch = ended
        keepalive = network.scheduleWithFixedDelay({
            val id = sessionId ?: return@scheduleWithFixedDelay
            try {
                home.keepalive(id)
                if (counter.failures > 0) log("canlı tutma yeniden yanıt verdi")
                counter.succeeded()
            } catch (error: Exception) {
                val detail = error.message ?: error.javaClass.simpleName
                val finish = counter.failed()
                val gone = XboxKeepalive.sessionGone(detail)
                val flowing = pictureWatch?.isFlowing(SystemClock.elapsedRealtime()) == true
                log("canlı tutma başarısız (${counter.failures}/${XboxKeepalive.MAX_FAILURES}): ${XboxSessionMachine.shortReason(detail, "?")}")
                if (!XboxKeepalive.shouldEnd(gone, finish, flowing)) {
                    if (flowing && (gone || finish)) log("görüntü akıyor: canlı tutma hatası yayını kapatmıyor")
                    return@scheduleWithFixedDelay
                }
                if (gone) end("Xbox oturumu kapattı (canlı tutma: ${XboxSessionMachine.shortReason(detail, "?").take(60)})", XboxError.SERVER_CLOSED)
                else end("Xbox canlı tutma isteklerine yanıt vermiyor", XboxError.TIMEOUT)
                latch?.countDown()
                keepalive?.cancel(false)
            }
        }, KEEPALIVE_MS, KEEPALIVE_MS, TimeUnit.MILLISECONDS)
    }

    /**
     * Bağlantı sürerken 10 sn'de bir kare hattının satırı (#1308): alıcıda geçen süre, atlanan kare ve bellek. Bellek
     * büyüyorsa ya da alıcı yavaşsa sonraki günlükte görünür.
     */
    private fun startPipeLog() {
        pipeTask?.cancel(false)
        pipeStats.take(0, "")
        pipeTask = timers.scheduleWithFixedDelay({
            try {
                pipeStats.take(XboxFramePipeStats.WINDOW_MS, memory())?.let(::log)
            } catch (error: Exception) {
                log("kare hattı: ${error.message}")
            }
        }, XboxFramePipeStats.WINDOW_MS, XboxFramePipeStats.WINDOW_MS, TimeUnit.MILLISECONDS)
    }

    private fun memory(): String {
        val runtime = Runtime.getRuntime()
        val java = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
        val native = android.os.Debug.getNativeHeapAllocatedSize() / (1024 * 1024)
        return "bellek java $java MB, yerel $native MB"
    }

    /** Kapanma anında akış ve onay sürüyor muydu (input kanalı ya da WebRTC bağlantısı kapanınca yazılır). */
    private fun closeContext(): String =
        XboxCloseContext.describe(SystemClock.elapsedRealtime(), lastFrameAt, lastAckAt, acksSent)

    private fun closePeer() {
        synchronized(watchLock) {
            watchTask?.cancel(false)
            watchTask = null
            watch = null
            videoTrack = null
        }
        pictureWatch = null
        pipeTask?.cancel(false)
        pipeTask = null
        handoff.clear()
        frameSession?.let(frameCounter::endSession)
        frameSession = null
        keepalive?.cancel(false)
        keepalive = null
        acking = false
        ackTask?.cancel(false)
        ackTask = null
        acks.clear()
        synchronized(channels) {
            channels.values.forEach { runCatching { it.unregisterObserver(); it.dispose() } }
            channels.clear()
        }
        // Parça bağlantıyla birlikte kapanır; kapanmış parçaya dokunulmaz.
        audioTrack = null
        peer?.let { runCatching { it.dispose() } }
        peer = null
        factory?.let { runCatching { it.dispose() } }
        factory = null
        audioModule = null
        ended = null
    }

    /** WebRTC'nin geri çağırmalı işlemini bekler (en çok 10 sn). */
    private fun <T> await(what: String, start: (SdpResult<T>) -> Unit): T {
        val result = SdpResult<T>()
        start(result)
        if (!result.latch.await(10, TimeUnit.SECONDS)) throw XboxException(XboxError.TIMEOUT, "$what zaman aşımı")
        result.error?.let { throw XboxException(XboxError.SERVICE, "$what: $it") }
        @Suppress("UNCHECKED_CAST")
        return result.value as T
    }

    private class SdpResult<T> {
        val latch = CountDownLatch(1)
        @Volatile var value: Any? = null
        @Volatile var error: String? = null

        fun creating() = object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) { value = description; latch.countDown() }
            override fun onSetSuccess() {}
            override fun onCreateFailure(message: String?) { error = message ?: "?"; latch.countDown() }
            override fun onSetFailure(message: String?) {}
        }

        fun setting() = object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription?) {}
            override fun onSetSuccess() { value = Unit; latch.countDown() }
            override fun onCreateFailure(message: String?) {}
            override fun onSetFailure(message: String?) { error = message ?: "?"; latch.countDown() }
        }
    }
}

/** libwebrtc süreçte bir kez başlatılır. */
private object WebRtc {
    @Volatile private var ready = false

    @Synchronized
    fun initialize(context: Context) {
        if (ready) return
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
        ready = true
    }
}

/** Crashlytics'e giden tanı kaydı: Xbox bağlantısının neden ve ne kadar sürede bittiği (çökme değildir). */
private class XboxSessionEnded(message: String) : Exception(message)
