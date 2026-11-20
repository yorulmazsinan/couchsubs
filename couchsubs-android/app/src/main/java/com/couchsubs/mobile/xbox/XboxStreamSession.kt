// SPDX-License-Identifier: AGPL-3.0-only
// Xbox ev yayını (Beta): Windows'taki XboxStreamSession + player.html'in telefondaki karşılığı. Görüntü yerel
// libwebrtc'yle alınır; kareler OCR hattına doğrudan parlaklık (Y) düzlemi olarak gider (bkz. docs/superpowers/specs/
// 2026-11-16-telefon-xbox-design.md). Oyun sesi ayar açıksa telefonda çalınır (bkz. playAudio); mikrofon açılmaz,
// kumanda girdisi gönderilmez.
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
    private val playAudio: Boolean = true,
) : FrameSource {
    private companion object {
        const val TAG = "CouchSubsXbox"
        const val ICE_GATHER_MS = 5000L
        const val KEEPALIVE_MS = 30_000L
        /** El sıkışmadan sonra bu sürede kare gelmezse oturum yeniden açılır. */
        const val FIRST_FRAME_MS = 20_000L
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
    private val stopped = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    @Volatile private var sessionId: String? = null
    @Volatile private var peer: PeerConnection? = null
    @Volatile private var factory: PeerConnectionFactory? = null
    @Volatile private var ended: CountDownLatch? = null
    @Volatile private var endReason: String? = null
    @Volatile private var keepalive: ScheduledFuture<*>? = null
    @Volatile private var lastConverted = 0L
    @Volatile private var firstFrameAt = 0L
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

    override fun start() {
        if (!started.compareAndSet(false, true)) return
        worker.execute(::run)
    }

    override fun dispose() {
        if (!stopped.compareAndSet(false, true)) return
        machine.stop()
        ended?.countDown()
        worker.execute {
            closePeer()
            stopRemote()
            onState(SessionState.Disconnected(DisconnectKind.STOPPED))
        }
        worker.shutdown()
        timers.shutdown()
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
                if (!stopped.get()) throw XboxException(XboxError.NETWORK, endReason ?: "Xbox görüntü bağlantısı kapandı")
            } catch (error: InterruptedException) {
                if (stopped.get()) break
            } catch (error: XboxException) {
                action = decided ?: machine.fail(error.kind, error.message ?: "")
                report(error.kind, error.message)
            } catch (error: Exception) {
                action = machine.fail(XboxError.SERVICE, error.message ?: error.javaClass.simpleName)
                report(XboxError.SERVICE, error.message)
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
        val text = "bağlantı bitti: $reason; kare $frames, onay $acksSent, ilk kareden sonra $lived"
        log(text)
        if (!stopped.get() && endReported.compareAndSet(false, true)) Backend.recordError(XboxSessionEnded(text))
    }

    @Volatile private var lastError: String? = null

    private fun report(kind: XboxError, detail: String?) {
        lastError = "$kind: $detail"
        if (stopped.get()) return
        log("kopma ($kind): $detail")
        val failed = machine.phase as? XboxSessionMachine.Phase.Failed
        when {
            failed == null || failed.willRetry -> {
                failed?.let { log("yeniden deneme ${it.attempt}/${machine.retryDelaysMs.size}: ${machine.retryDelaysMs[it.attempt - 1] / 1000} sn sonra") }
                onState(SessionState.Disconnected(DisconnectKind.OTHER, describe(kind)))
            }
            // Giriş gerekiyor: kullanıcının yapacağı iş hizmetin metninde.
            kind in XboxSessionMachine.FATAL -> onState(SessionState.Disconnected(DisconnectKind.OTHER, describe(kind)))
            else -> {
                // Denemeler bitti ya da konsol yayını reddetti: yayın durur, yeniden denenmez.
                log("yeniden denenmiyor, yayın durdu")
                val text = when (XboxSessionMachine.stopKind(kind, detail)) {
                    XboxSessionMachine.StopKind.BUSY -> appContext.getString(R.string.xbox_stopped_busy)
                    XboxSessionMachine.StopKind.CONSOLE_UNAVAILABLE -> appContext.getString(R.string.xbox_stopped_console)
                    XboxSessionMachine.StopKind.OTHER ->
                        appContext.getString(R.string.xbox_connection_lost, XboxSessionMachine.shortReason(detail, kind.name))
                }
                onState(SessionState.Disconnected(DisconnectKind.OTHER, text))
            }
        }
    }

    private fun stopRemote() {
        val id = sessionId ?: return
        sessionId = null
        try {
            home.stop(id)
        } catch (error: Exception) {
            // Kopan bağlantının kapatılacak oturumu yoktur.
        }
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
        return PeerConnectionFactory.builder()
            .setAudioDeviceModule(audio)
            // EGL bağlamı yok: donanım çözücüsü kareyi bellekte verir, Y düzlemi doğrudan okunur.
            // Kare onayı için çözülen karenin RTP zaman damgası gerekir; çözücü seçimi DefaultVideoDecoderFactory'ninki.
            .setVideoDecoderFactory(XboxDecoderFactory(decoded))
            .setVideoEncoderFactory(SoftwareVideoEncoderFactory())
            .createPeerConnectionFactory()
            .also { audio.release() }
    }

    private fun negotiate(id: String) {
        val negotiatedFrames = frameCounter.beginSession()
        frameSession = negotiatedFrames
        val sink = VideoSink { frame ->
            if (stopped.get()) return@VideoSink
            val sessionFrames = frameCounter.recordFrame(negotiatedFrames) ?: return@VideoSink
            val now = SystemClock.elapsedRealtime()
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
            val i420 = frame.buffer.toI420() ?: return@VideoSink
            try {
                if (frameCounter.framesInSession(negotiatedFrames) > 0) {
                    onFrame(VideoFrame(i420.dataY, i420.width, i420.height, i420.strideY))
                }
            } finally {
                i420.release()
            }
        }
        val done = CountDownLatch(1).also { ended = it }
        endReason = null
        lastError = null
        firstFrameAt = 0L
        acking = false
        acks.clear()
        ackSequence = 0
        acksSent = 0L
        clockStart = SystemClock.elapsedRealtime()
        val pcFactory = createFactory().also { factory = it }
        val gathered = CountDownLatch(1)
        val local = ArrayList<XboxIceCandidate>()
        val config = PeerConnection.RTCConfiguration(listOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun1.l.google.com:19302").createIceServer(),
        )).apply { sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN }
        val connection = pcFactory.createPeerConnection(config, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) { log("ICE: $state") }
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
                if (state == PeerConnection.PeerConnectionState.FAILED || state == PeerConnection.PeerConnectionState.CLOSED) {
                    endReason = "Xbox WebRTC bağlantısı kesildi ($state)"
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
        audio?.receiver?.track()?.setEnabled(playAudio)
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
            if (frameCounter.framesInSession(negotiatedFrames) == 0L && SystemClock.elapsedRealtime() - negotiatedAt > FIRST_FRAME_MS) {
                endReason = "Xbox'tan ${FIRST_FRAME_MS / 1000} sn içinde görüntü gelmedi"
                throw XboxException(XboxError.CONSOLE_UNAVAILABLE, endReason!!)
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
                    endReason = "Xbox görüntü bağlantısı kapandı"
                    done.countDown()
                }
            }
        }

        override fun onMessage(buffer: DataChannel.Buffer) {
            val bytes = ByteArray(buffer.data.remaining()).also { buffer.data.get(it) }
            if (buffer.binary) {
                // input kanalından gelenler: 16 = ServerMetadata, 128 = titreşim (her an gelir, yazılmaz).
                val type = if (bytes.isEmpty()) -1 else bytes[0].toInt() and 0xff
                if (type != 128) log("kanal $name: ikili ileti, tür $type, ${bytes.size} bayt")
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
        ackTask = timers.scheduleWithFixedDelay({
            try {
                val frames = acks.drain()
                if (frames.isEmpty()) return@scheduleWithFixedDelay
                val sequence = ++ackSequence
                send("input", XboxChannels.frameAckPacket(sequence, (SystemClock.elapsedRealtime() - clockStart).toDouble(), frames), binary = true)
                acksSent += frames.size
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
                log(XboxStreamStats.describe(since, current.frameSeen, current.keyframesRequested, stats, picture))
            } catch (error: Exception) {
                log("ilk kare tanısı: ${error.message}")
            }
        }
    }

    private fun startKeepalive() {
        keepalive?.cancel(false)
        keepalive = timers.scheduleWithFixedDelay({
            val id = sessionId ?: return@scheduleWithFixedDelay
            try {
                home.keepalive(id)
            } catch (error: Exception) {
                log("canlı tutma: ${error.message}")
            }
        }, KEEPALIVE_MS, KEEPALIVE_MS, TimeUnit.MILLISECONDS)
    }

    private fun closePeer() {
        synchronized(watchLock) {
            watchTask?.cancel(false)
            watchTask = null
            watch = null
            videoTrack = null
        }
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
        peer?.let { runCatching { it.dispose() } }
        peer = null
        factory?.let { runCatching { it.dispose() } }
        factory = null
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
