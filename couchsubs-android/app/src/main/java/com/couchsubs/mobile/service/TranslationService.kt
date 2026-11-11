// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Telemetry
import com.couchsubs.mobile.core.CropRegion
import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.core.LinePool
import com.couchsubs.mobile.core.PackLookup
import com.couchsubs.mobile.core.SubtitleEvent
import com.couchsubs.mobile.core.SubtitlePipeline
import com.couchsubs.mobile.core.SubtitleServer
import com.couchsubs.mobile.core.TextTranslator
import com.couchsubs.mobile.ocr.RegionPixels
import com.couchsubs.mobile.ocr.SubtitleReader
import com.couchsubs.mobile.remoteplay.DisconnectKind
import com.couchsubs.mobile.remoteplay.NativeBridge
import com.couchsubs.mobile.remoteplay.SessionState
import com.couchsubs.mobile.remoteplay.StreamSession
import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.settings.EngineChoice
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.translation.AiModel
import com.couchsubs.mobile.translation.AiProvider
import com.couchsubs.mobile.translation.AiTranslator
import com.couchsubs.mobile.translation.DeepLTranslator
import com.couchsubs.mobile.translation.MlKitTranslator
import com.couchsubs.mobile.ui.MainActivity
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Çeviri sürerken çalışan ön plan hizmeti (kalıcı bildirimle): PS5 oturumu → kare → yazı tanıma → paket/çeviri →
 * SSE sunucusu (TV) ve telefon ekranı. Ekran kapansa ya da uygulama arka plana geçse de okuma sürer.
 */
class TranslationService : Service() {
    companion object {
        private const val TAG = "CouchSubsService"
        private const val CHANNEL = "translation"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.couchsubs.mobile.STOP"
        /** Yazı tanıma en çok saniyede bu kadar kare okur (telefon ısınmasın; altyazı için yeterli). */
        private const val MAX_READS_PER_SECOND = 5

        fun start(context: Context) {
            context.startForegroundService(Intent(context, TranslationService::class.java))
        }

        fun stop(context: Context) {
            context.startService(Intent(context, TranslationService::class.java).setAction(ACTION_STOP))
        }
    }

    private lateinit var settings: AppSettings
    private var session: StreamSession? = null
    private var server: SubtitleServer? = null
    private var pipeline: SubtitlePipeline? = null
    private var reader: SubtitleReader? = null
    private var pool: LinePool? = null
    private var freeTranslator: MlKitTranslator? = null
    private var packs: GamePackLibrary? = null
    private val ocr = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs OCR").apply { isDaemon = true } }
    private val background = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs background").apply { isDaemon = true } }
    private val reading = AtomicBoolean(false)
    private var lastRead = 0L
    private var lastSignature = 0L
    private var lastReading = com.couchsubs.mobile.core.Reading.Empty
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val region = CropRegion()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        settings = AppSettings(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startInForeground()
        if (session == null) begin()
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.channel_translation), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, TranslationService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(getString(R.string.notification_text))
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, getString(R.string.stop), stop).build())
            .build()
        // Android 14+: ağdaki cihazlarla (PS5, TV) sürekli konuşan hizmet "connectedDevice" türündedir.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(NOTIFICATION_ID, notification)
    }

    private fun begin() {
        val console = settings.console
        val accountId = settings.accountId
        if (console == null || accountId == null) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_not_paired)) }
            stopSelf()
            return
        }
        if (!NativeBridge.available) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_native)) }
            stopSelf()
            return
        }
        acquireLocks()
        startedAt = System.currentTimeMillis()
        LiveState.update { LiveStatus(running = true, phase = getString(R.string.phase_preparing), startedAt = startedAt, engineLabel = engineLabel()) }
        Telemetry.event(Telemetry.SESSION_START, "target" to settings.target.name.lowercase(), "engine" to settings.engine.name.lowercase(),
            "packs" to Services.packsAllowed())

        // Paketler aboneliğe bağlı: kitaplık sunucudan inmiş paketlerden (hata ayıklamada APK'dakilerden de) kurulur,
        // her satırda hak yeniden denetlenir (abonelik oturum sırasında biterse paket araması durur).
        val library = Services.packLibrary(this)
        packs = library
        val free = MlKitTranslator().also { freeTranslator = it }
        val translator = onlineTranslator(free) ?: free
        val subtitleServer = SubtitleServer().also { server = it }
        subtitleServer.sendsToTv = settings.target == SubtitleTarget.TV
        subtitleServer.onClientsChanged = { count ->
            val before = LiveState.status.value.connectedTvs
            LiveState.update { it.copy(connectedTvs = count) }
            if (before == 0 && count > 0) Telemetry.event(Telemetry.TV_CONNECTED, "count" to count)
        }
        subtitleServer.onEvent = { event ->
            LiveState.update { it.copy(current = if (event is SubtitleEvent.Subtitle) event.text else "") }
        }
        try {
            subtitleServer.start()
            subtitleServer.sendStyle(settings.style)
        } catch (error: Exception) {
            Log.e(TAG, "SSE server", error)
            LiveState.update { it.copy(error = getString(R.string.error_port)) }
        }

        val linePool = LinePool(File(filesDir, "line-pool.json"), "CouchSubs Android ${BuildConfig.VERSION_NAME}", enabled = settings.sharePool)
        pool = linePool
        val packTitles = library.infos.associate { it.id to it.title }
        reader = SubtitleReader()
        pipeline = SubtitlePipeline(translator, subtitleServer).apply {
            packLookup = { text -> if (Services.packsAllowed()) PackLookup.match(library, text) else null }
            onPackMissed = { text -> linePool.offer(text) }
            onPairShown = { pair ->
                LiveState.shown(pair, pair.packId?.let { packTitles[it] ?: it })
                // Paket başına oturumda bir kez (her satırda olay göndermeyelim); toplam sayı oturum sonunda gider.
                pair.packId?.let { id -> if (packsUsed.add(id)) Telemetry.event(Telemetry.PACK_HIT, "pack" to id) }
            }
            onTranslationResult = { error ->
                LiveState.update { it.copy(error = error?.let { getString(R.string.error_translation) }) }
            }
        }
        background.scheduleWithFixedDelay({ linePool.flush() }, LinePool.FLUSH_INTERVAL_MS, LinePool.FLUSH_INTERVAL_MS, TimeUnit.MILLISECONDS)
        // Ücretsiz modelin ilk indirilmesi (yaklaşık 30 MB); oyun paketleri beklemeden çalışır.
        background.execute {
            try {
                free.prepare()
            } catch (error: Exception) {
                Log.w(TAG, "ML Kit model", error)
                LiveState.update { it.copy(error = getString(R.string.error_model)) }
            }
        }

        session = StreamSession(console, accountId,
            onFrame = { image ->
                val now = System.currentTimeMillis()
                if (!reading.get() && now - lastRead >= 1000 / MAX_READS_PER_SECOND) {
                    SubtitleReader.copyRegion(image, region)?.let { pixels ->
                        lastRead = now
                        reading.set(true)
                        ocr.execute { read(pixels) }
                    }
                }
            },
            onState = { state -> LiveState.update { it.copy(phase = describe(state)) } },
            onConsoleMoved = { moved -> settings.console = moved },
        ).also { it.start() }
        background.scheduleWithFixedDelay({
            session?.let { s -> LiveState.update { it.copy(framesReceived = s.framesReceived) } }
        }, 2, 2, TimeUnit.SECONDS)
    }

    private fun read(pixels: RegionPixels) {
        try {
            // Bölge değişmediyse (aynı altyazı duruyor) yeniden okunmaz; son okuma hattı yine besler (kararlılık ve
            // silme saate bağlıdır, Windows'taki ReadScheduler gibi).
            val current = pipeline ?: return
            val result = if (pixels.signature == lastSignature) lastReading else reader?.read(pixels) ?: return
            lastSignature = pixels.signature
            lastReading = result
            current.process(result, region.box)
        } catch (error: Exception) {
            Log.w(TAG, "OCR", error)
        } finally {
            reading.set(false)
        }
    }

    /** Çevrimiçi motor seçilip anahtarı girildiyse o, hatada yerel motor; yoksa null. */
    private fun onlineTranslator(free: TextTranslator): TextTranslator? {
        val engine = settings.engine
        val key = settings.apiKey(engine)?.takeIf { it.isNotBlank() } ?: return null
        return when (engine) {
            EngineChoice.FREE -> null
            EngineChoice.DEEPL -> DeepLTranslator(key, free)
            else -> {
                val provider = when (engine) {
                    EngineChoice.GEMINI -> AiProvider.GEMINI
                    EngineChoice.OPENAI -> AiProvider.OPENAI
                    else -> AiProvider.CLAUDE
                }
                val models = aiModels()[provider.id].orEmpty()
                val model = models.firstOrNull { it.id == settings.aiModel } ?: models.firstOrNull() ?: return null
                AiTranslator(provider, key, model, free)
            }
        }
    }

    private fun aiModels(): Map<String, List<AiModel>> = try {
        AiModel.parse(assets.open("ai-models.json").use { String(it.readBytes(), Charsets.UTF_8) })
    } catch (error: Exception) {
        emptyMap()
    }

    private fun describe(state: SessionState): String = when (state) {
        SessionState.Connecting -> getString(R.string.phase_connecting)
        SessionState.Streaming -> getString(R.string.phase_streaming)
        is SessionState.Disconnected -> when (state.kind) {
            DisconnectKind.IN_USE -> getString(R.string.phase_in_use)
            DisconnectKind.NOT_FOUND -> getString(R.string.phase_not_found)
            DisconnectKind.CONSOLE_ASLEEP -> getString(R.string.phase_asleep)
            DisconnectKind.LOGIN_PASSCODE -> getString(R.string.phase_passcode)
            DisconnectKind.REFUSED -> getString(R.string.phase_refused)
            else -> getString(R.string.phase_reconnecting)
        }
    }

    private fun acquireLocks() {
        // Ekran kapalıyken de Wi-Fi uyumasın ve işlemci kareleri işlemeye devam etsin.
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CouchSubs:translate").apply { acquire() }
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createWifiLock(mode, "CouchSubs").apply { acquire() }
    }

    private val packsUsed = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private var startedAt = 0L

    /** Ana ekrandaki "Çeviri · DeepL" karosu ve satırlardaki motor hapı için. */
    private fun engineLabel(): String = when (settings.engine) {
        EngineChoice.FREE -> getString(R.string.engine_free_short)
        EngineChoice.DEEPL -> "DeepL"
        EngineChoice.GEMINI -> "Gemini"
        EngineChoice.OPENAI -> "OpenAI"
        EngineChoice.CLAUDE -> "Claude"
    }

    override fun onDestroy() {
        if (startedAt > 0) settings.lastSessionMs = System.currentTimeMillis() - startedAt
        if (startedAt > 0) Telemetry.event(Telemetry.SESSION_STOP, "seconds" to (System.currentTimeMillis() - startedAt) / 1000,
            "pack_lines" to (pipeline?.packHits ?: 0), "lines" to LiveState.status.value.recent.size)
        session?.dispose()
        session = null
        pipeline?.reset()
        pipeline?.shutdown()
        server?.stop()
        reader?.close()
        freeTranslator?.close()
        pool?.let { linePool -> Thread { linePool.flush() }.start() }
        background.shutdownNow()
        ocr.shutdownNow()
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLock?.takeIf { it.isHeld }?.release()
        LiveState.update { it.copy(running = false, phase = "", current = "") }
        super.onDestroy()
    }
}
