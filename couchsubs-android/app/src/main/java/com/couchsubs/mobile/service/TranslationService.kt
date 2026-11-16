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
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.account.Telemetry
import com.couchsubs.mobile.core.CropRegion
import com.couchsubs.mobile.core.active
import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.core.GameSense
import com.couchsubs.mobile.core.LinePool
import com.couchsubs.mobile.packs.PackStore
import com.couchsubs.mobile.core.PackLookup
import com.couchsubs.mobile.core.ScreenTranslation
import com.couchsubs.mobile.core.SubtitleEvent
import com.couchsubs.mobile.core.SubtitlePipeline
import com.couchsubs.mobile.core.SubtitleServer
import com.couchsubs.mobile.core.TextTranslator
import com.couchsubs.mobile.ocr.RegionPixels
import com.couchsubs.mobile.ocr.SubtitleReader
import com.couchsubs.mobile.remoteplay.ConsoleDiscovery
import com.couchsubs.mobile.remoteplay.DisconnectKind
import com.couchsubs.mobile.remoteplay.FrameSource
import com.couchsubs.mobile.remoteplay.FrameSourceFactory
import com.couchsubs.mobile.remoteplay.RegisteredConsole
import com.couchsubs.mobile.remoteplay.FrameSources
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
import com.couchsubs.mobile.translation.Glossary
import com.couchsubs.mobile.translation.MlKitTranslator
import com.couchsubs.mobile.translation.TranslationCache
import com.couchsubs.mobile.ui.MainActivity
import com.couchsubs.mobile.xbox.XboxError
import com.couchsubs.mobile.xbox.XboxStreamSession
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
        /** PS5'e çalışan oyunun sorulma aralığı (ortak havuz). */
        private const val GAME_PROBE_MS = 2 * 60 * 1000L

        fun start(context: Context) {
            context.startForegroundService(Intent(context, TranslationService::class.java))
        }

        fun stop(context: Context) {
            context.startService(Intent(context, TranslationService::class.java).setAction(ACTION_STOP))
        }

        /** Çalışan hizmet ("ekranı çevir" düğmesi buraya gelir). */
        @Volatile private var current: TranslationService? = null

        /**
         * "Ekranı çevir": PS5'in şu anki karesinin tamamı bir kez okunur, yazı grupları tek istekte çevrilir; sonuçlar
         * telefonda ve TV'de yazının yerinde görünür. Çeviri sürerken ya da sonuçlar ekrandayken yeniden çağrılmak onları
         * kaldırır (Mac ⌥⌘T ve iPhone ile aynı). Çeviri çalışmıyorsa false.
         */
        fun translateScreen(): Boolean {
            val service = current ?: return false
            service.toggleScreen()
            return true
        }

        /** Çeviri sürerken açık altyazı sunucusu ("TV'de test et" için). */
        @Volatile private var liveServer: SubtitleServer? = null

        /**
         * Deneme altyazısı (iPhone'daki "Deneme altyazısı gönder"): TV'de ya da telefon ekranında yazının nasıl
         * göründüğü. Çeviri çalışmıyorsa (TV bağlı değil) false.
         */
        fun sendTestSubtitle(text: String): Boolean {
            val server = liveServer ?: return false
            server.sendSubtitle(text, 8000)
            return true
        }
    }

    private lateinit var settings: AppSettings
    @Volatile private var session: FrameSource? = null
    @Volatile private var server: SubtitleServer? = null
    @Volatile private var pipeline: SubtitlePipeline? = null
    @Volatile private var reader: SubtitleReader? = null
    @Volatile private var pool: LinePool? = null
    @Volatile private var freeTranslator: MlKitTranslator? = null
    @Volatile private var packs: GamePackLibrary? = null
    private val ocr = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs OCR").apply { isDaemon = true } }
    private val background = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs background").apply { isDaemon = true } }
    private val reading = AtomicBoolean(false)
    private var lastRead = 0L
    private var lastSignature = 0L
    private var lastReading = com.couchsubs.mobile.core.Reading.Empty
    private var lastOcrMs: Int? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    /** Altyazı bölgesi ve ek alanlar (Ayarlar › Altyazı alanı); çeviri sürerken değişirse hemen yenisi okunur. */
    @Volatile private var region = CropRegion()
    @Volatile private var extraAreas: List<com.couchsubs.mobile.core.ExtraArea> = emptyList()
    @Volatile private var areasListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null
    /** Ek alanları ana altyazıdan ayrı ve seyrek (saniyede bir) okuyan; kendi okuyucusu ve iş parçacığı var. */
    @Volatile private var regionWatcher: com.couchsubs.mobile.core.RegionWatcher? = null
    @Volatile private var regionReader: SubtitleReader? = null
    private val regionWork = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs extra areas").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } }
    private val lifecycle = Any()
    @Volatile private var destroyed = false
    @Volatile private var streaming = false
    private var begun = false
    @Volatile private var styleListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null
    @Volatile private var targetListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        settings = AppSettings(this)
        current = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startInForeground()
        if (!begun) {
            begun = true
            begin()
        }
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
        val xbox = settings.xbox
        val console = settings.console
        val accountId = settings.accountId
        // Xbox (Beta): Microsoft girişi ve seçili Xbox yeter; PSN ve PS5 eşlemesi gerekmez.
        if (xbox && (settings.xboxConsole == null || !Services.xboxAuth.signedIn)) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_xbox_not_ready)) }
            stopSelf()
            return
        }
        if (!xbox && (console == null || accountId == null)) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_not_paired)) }
            stopSelf()
            return
        }
        // Yerine geçen kaynak yalnız debug yapısında kurulur (Play görüntüleri için kayıtlı klip); PS5 kitaplığı gerekmez.
        val replacement = FrameSources.replacement
        if (replacement == null && !xbox && !NativeBridge.available) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_native)) }
            stopSelf()
            return
        }
        acquireLocks()
        settings.translating = true
        Backend.breadcrumb("çeviri: başlıyor (${settings.target.name}, ${settings.engine.name}, paketler ${settings.packsEnabled})")
        startedAt = System.currentTimeMillis()
        LiveState.update { LiveStatus(running = true, phase = getString(R.string.phase_preparing), startedAt = startedAt, engineLabel = engineLabel()) }
        Telemetry.event(Telemetry.SESSION_START, "target" to settings.target.name.lowercase(), "engine" to settings.engine.name.lowercase(),
            "packs" to settings.packsEnabled)
        // Paketlerin açılması, çeviri modeli ve sunucu kurulumu ana iş parçacığında yapılırsa zayıf telefonda
        // "CouchSubs yanıt vermiyor" uyarısı çıkar; kurulum kendi iş parçacığında yapılır.
        Thread({
            try {
                setup(console, accountId, replacement)
            } catch (error: Throwable) {
                // Exception değil Throwable: bu iş parçacığında yakalanmayan hata (ör. OutOfMemoryError) bütün uygulamayı
                // kapatır, PS5 bağlantısı da kopar. Kurulum sürerken durdurulduysa (zamanlayıcı kapanmış olur) yalnız
                // kurulanlar kapatılır.
                if (destroyed) releaseParts()
                else {
                    Log.e(TAG, "setup", error)
                    LiveState.update { it.copy(error = getString(R.string.error_native)) }
                    stopSelf()
                }
            }
        }, "CouchSubs start").start()
    }

    private fun setup(console: RegisteredConsole?, accountId: ByteArray?, replacement: FrameSourceFactory?) {
        val xboxConsole = if (settings.xbox) settings.xboxConsole else null
        // Paketler ücretsiz: uygulamayla gelenler ve sunucudan inmiş güncel sürümler. Ayardan kapatılırsa aranmaz.
        val library = Services.packLibrary(this)
        packs = library
        // Terim sözlüğü ve kalıcı önbellek (iPhone ile aynı biçim): önceki oturumlarda çevrilen cümleler hemen gelir.
        val glossary = Glossary.load(this)
        glossaryInUse = glossary
        val free = MlKitTranslator(cache(MlKitTranslator.ENGINE_ID), glossary).also { freeTranslator = it }
        val translator = onlineTranslator(free) ?: free
        val subtitleServer = SubtitleServer().also { server = it }
        subtitleServer.sendsToTv = settings.target == SubtitleTarget.TV
        subtitleServer.onClientsChanged = { count ->
            val before = LiveState.status.value.connectedTvs
            LiveState.update { it.copy(connectedTvs = count) }
            if (before == 0 && count > 0) Telemetry.event(Telemetry.TV_CONNECTED, "count" to count)
        }
        subtitleServer.onEvent = { event ->
            LiveState.update { it.phoneEvent(event) }
        }
        // Çeviri sürerken Ayarlar'da yazı boyu ya da rengi değişirse TV hemen yeni görünüme geçer (iPhone ile aynı).
        styleListener = settings.onStyleChanged { server?.sendStyle(settings.style) }
        // Çeviri sürerken hedef TV'ye (ya da telefona) çevrilirse altyazı hemen oraya gider (iPhone ile aynı).
        targetListener = settings.onTargetChanged { server?.sendsToTv = settings.target == SubtitleTarget.TV }
        region = settings.region
        extraAreas = settings.extraAreas.active()
        areasListener = settings.onAreasChanged {
            region = settings.region
            extraAreas = settings.extraAreas.active()
        }
        try {
            subtitleServer.start()
            subtitleServer.sendStyle(settings.style)
            liveServer = subtitleServer
        } catch (error: Exception) {
            Log.e(TAG, "SSE server", error)
            LiveState.update { it.copy(error = getString(R.string.error_port)) }
        }

        // Klipten okunan satırlar ortak havuza gönderilmez (oyun yazısı değildir).
        val linePool = LinePool(File(filesDir, "line-pool.json"), "CouchSubs Android ${BuildConfig.VERSION_NAME}",
            enabled = settings.sharePool && replacement == null)
        pool = linePool
        // Paketler burada açılır (ilk altyazı beklemesin); kapalıysa hiç açılmaz. Bellek yetmezse paketsiz sürülür:
        // çeviri motoru çalışır, uygulama kapanmaz ve PS5 bağlantısı kopmaz.
        var packTitles = if (!settings.packsEnabled) null else try {
            library.infos.associate { it.id to it.title }
        } catch (error: OutOfMemoryError) {
            Log.e(TAG, "packs", error)
            null
        }
        Backend.breadcrumb("çeviri: paketler ${packTitles?.size ?: "yok"}")
        // Ayarlardan paket içe aktarılınca ya da silinince bu oturumun paketleri hemen yeniden okunur.
        Services.onLocalPacksChanged = {
            try {
                library.reload()
                if (packTitles != null) packTitles = library.infos.associate { it.id to it.title }
            } catch (error: OutOfMemoryError) {
                Log.e(TAG, "packs reload", error)
            }
        }
        reader = SubtitleReader()
        pipeline =SubtitlePipeline(translator, subtitleServer).apply {
            // Yarım ya da bozuk okuma hemen çevrilmez; aynı satırın en iyi okuması çevrilir (Windows ve iPhone ile aynı).
            holdReadings = true
            packLookup = { text -> if (packTitles != null && settings.packsEnabled) PackLookup.match(library, text) else null }
            showSpeakerNames = { settings.showSpeakerNames }
            onPackMissed = { text -> linePool.offer(text) }
            onPairShown = { pair ->
                LiveState.shown(pair, pair.packId?.let { packTitles?.get(it) ?: it })
                if (replacement == null) PlayedGame.noteLine(pair.origin == "paket", library)
                Services.addToHistory(pair.source, pair.translation,
                    if (pair.origin == "paket") com.couchsubs.mobile.core.SubtitleHistory.PACK else com.couchsubs.mobile.core.SubtitleHistory.ENGINE)
                // Paket başına oturumda bir kez (her satırda olay göndermeyelim); toplam sayı oturum sonunda gider.
                pair.packId?.let { id -> if (packsUsed.add(id)) Telemetry.event(Telemetry.PACK_HIT, "pack" to id) }
            }
            onTranslationResult = { error ->
                LiveState.update { it.copy(error = error?.let { getString(R.string.error_translation) }) }
            }
        }
        // Ek alanlar aynı paketlerle ve aynı motorla (ayrı bir örnekle; altyazının bağlamına karışmasın) çevrilir; satırları
        // ortak havuza önerilmez (arayüz yazıları havuzu kirletmesin). Mac ve iPhone ile aynı.
        val areaReader = SubtitleReader().also { regionReader = it }
        regionWatcher = com.couchsubs.mobile.core.RegionWatcher({ crop -> areaReader.read(crop.pixels as RegionPixels) },
            onlineTranslator(free.separate()) ?: free.separate(), subtitleServer).apply {
            packLookup = { text -> if (packTitles != null && settings.packsEnabled) PackLookup.match(library, text) else null }
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

        val onFrame: (com.couchsubs.mobile.remoteplay.VideoFrame) -> Unit = { frame ->
            val now = System.currentTimeMillis()
            if (screenRequested.compareAndSet(true, false)) startScreen(frame)
            if (!reading.get() && now - lastRead >= 1000 / MAX_READS_PER_SECOND) {
                val area = region
                // Karenin geldiği an: gecikme buradan TV'ye gidene kadar ölçülür (hattın saatiyle).
                val capturedAt = com.couchsubs.mobile.core.monotonicClock()
                SubtitleReader.copyRegion(frame, area)?.let { pixels ->
                    lastRead = now
                    reading.set(true)
                    ocr.execute { read(pixels, area, capturedAt) }
                }
            }
            // Ek alanlar saniyede bir, kendi iş parçacığında okunur; altyazı okumasını beklemez, onu bekletmez.
            regionWatcher?.offer(extraAreas, { r ->
                SubtitleReader.copyRegion(frame, r)?.let {
                    com.couchsubs.mobile.core.RegionWatcher.Crop(it, com.couchsubs.mobile.core.RegionSignature.of(it.nv21, it.width, it.height))
                }
            }) { task -> runCatching { regionWork.execute(task) } }
            FramePreview.offer(frame, now)
        }
        val onState: (SessionState) -> Unit = { state ->
            streaming = state == SessionState.Streaming
            if (!streaming) {
                PlayedGame.consoleReported(null)
                regionWatcher?.reset()
            }
            LiveState.update { it.copy(phase = describe(state)) }
        }
        // Oynanan oyun (PS5'in bildirdiği, paketten tanınan ya da kullanıcının seçtiği; bkz. PlayedGame): havuza giden
        // satırlar bu oyunla gider. Klipte oyun aranmaz, sorulmaz.
        if (replacement == null) {
            PlayedGame.packTitles = { packTitles?.filterKeys { it != GameSense.GENERAL_PACK }?.values?.toList() ?: emptyList() }
            PlayedGame.onChange = { game ->
                linePool.setGame(game)
                // Yeni oyun: o oyunun (havuzdan otomatik) paketi sunucuda yeni çıkmış olabilir; inerse bu oturumun
                // paketleri hemen yeniden okunur (iPhone'daki gibi).
                if (game != null) Services.refreshPacks(force = false, maxAgeMs = PackStore.GAME_CHECK_MS) {
                    try {
                        library.reload()
                        if (packTitles != null) packTitles = library.infos.associate { it.id to it.title }
                    } catch (error: OutOfMemoryError) {
                        Log.e(TAG, "packs reload", error)
                    }
                }
            }
            PlayedGame.start(xboxConsole?.name?.ifEmpty { "Xbox" } ?: console!!.name.ifEmpty { console.host }, settings, startedAt)
            // Oyun iki dakikada tanınmazsa kart açılır (ayar ve ortak havuz açıksa, oturumda bir kez).
            background.scheduleWithFixedDelay({ PlayedGame.checkAsk(System.currentTimeMillis()) }, 15, 15, TimeUnit.SECONDS)
            // Bağlıyken iki dakikada bir PS5'e çalışan oyun sorulur (Xbox'ta bu soru yok; oyun paketten tanınır).
            if (xboxConsole == null) background.scheduleWithFixedDelay({
                try {
                    val host = settings.console?.host ?: console!!.host
                    if (streaming) PlayedGame.consoleReported(ConsoleDiscovery.runningGame(host))
                } catch (error: Exception) {
                    Log.w(TAG, "running game", error)
                }
            }, GAME_PROBE_MS / 4, GAME_PROBE_MS, TimeUnit.MILLISECONDS)
        }
        val source = replacement?.create(this, onFrame, onState)
            ?: xboxConsole?.let { XboxStreamSession(this, Services.xboxAuth, it, onFrame, onState, ::describeXbox) }
            ?: StreamSession(console!!, accountId!!, onFrame, onState, onConsoleMoved = { moved -> settings.console = moved },
                loginPasscode = settings.loginPasscode)
        synchronized(lifecycle) {
            // Kurulum sürerken durdurulduysa (onDestroy çalıştı) açılan bağlantı başlatılmaz.
            if (destroyed) {
                source.dispose()
                releaseParts()
                return
            }
            session = source
            Backend.breadcrumb(if (xboxConsole != null) "çeviri: Xbox oturumu açılıyor" else "çeviri: PS5 oturumu açılıyor")
            source.start()
        }
        background.scheduleWithFixedDelay({
            session?.let { s -> LiveState.update { it.copy(framesReceived = s.framesReceived) } }
        }, 2, 2, TimeUnit.SECONDS)
    }

    // --- Ekranı çevir ---

    /** Düğmeye basıldı: sıradaki PS5 karesi tam okunsun. */
    private val screenRequested = AtomicBoolean(false)
    private val screenWork = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs screen").apply { isDaemon = true } }
    private val screenExpiry = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs screen expiry").apply { isDaemon = true } }
    /** Her istek ve kaldırma bir üst numara alır; eski işin sonuçları yok sayılır. */
    private val screenGeneration = java.util.concurrent.atomic.AtomicInteger()
    @Volatile private var screenTask: java.util.concurrent.Future<*>? = null
    @Volatile private var screenReader: SubtitleReader? = null

    private fun toggleScreen() {
        val server = server ?: return
        val state = LiveState.status.value.screenState
        if (state != LiveStatus.ScreenState.IDLE) {
            hideScreen()
            return
        }
        if (!streaming) {
            server.sendSubtitle(getString(R.string.screen_no_picture), 4000)
            return
        }
        screenGeneration.incrementAndGet()
        LiveState.update { it.copy(screenState = LiveStatus.ScreenState.WORKING) }
        server.sendStyle(settings.style)
        server.sendSubtitle(getString(R.string.screen_translating), 2500)
        screenRequested.set(true)
    }

    /** Çeviriyi durdurur, sonuçları telefondan ve TV'den kaldırır. */
    private fun hideScreen() {
        screenGeneration.incrementAndGet()
        screenRequested.set(false)
        screenTask?.cancel(true)
        screenTask = null
        server?.clearScreen()
        server?.clear()
        LiveState.update { it.copy(screen = emptyList(), screenState = LiveStatus.ScreenState.IDLE) }
    }

    /** Sıradaki kare geldi: bütün kare kopyalanır, okuma ve çeviri kendi iş parçacığında sürer. */
    private fun startScreen(frame: com.couchsubs.mobile.remoteplay.VideoFrame) {
        val pixels = SubtitleReader.copyRegion(frame, CropRegion(0.0, 1.0, 0.0, 1.0))
        val generation = screenGeneration.get()
        if (pixels == null) {
            failScreen(generation, getString(R.string.screen_no_picture))
            return
        }
        val free = freeTranslator
        val server = server
        if (free == null || server == null) {
            failScreen(generation, getString(R.string.error_translation))
            return
        }
        screenTask = screenWork.submit(Runnable {
            try {
                val reader = screenReader ?: SubtitleReader().also { screenReader = it }
                val reading = reader.read(pixels)
                // Yapay zekâda ekranın bütün yazıları tek istekte gider (bkz. AiTranslator.translateAll).
                val translator = onlineTranslator(free.separate()) ?: free.separate()
                val items = ScreenTranslation.translate(reading, translator, { screenGeneration.get() != generation }) { shown ->
                    if (screenGeneration.get() != generation) return@translate
                    val milliseconds = ScreenTranslation.displayMilliseconds(shown)
                    server.sendScreen(shown, milliseconds)
                    screenExpiry.schedule({ if (screenGeneration.get() == generation) hideScreen() }, milliseconds.toLong(), TimeUnit.MILLISECONDS)
                }
                if (screenGeneration.get() != generation) return@Runnable
                server.clear()
                if (items.isEmpty()) {
                    LiveState.update { it.copy(screenState = LiveStatus.ScreenState.IDLE) }
                    server.sendSubtitle(getString(R.string.screen_none), 2500)
                }
            } catch (error: InterruptedException) {
                return@Runnable
            } catch (error: Exception) {
                Log.w(TAG, "screen", error)
                failScreen(generation, getString(R.string.screen_failed, getString(R.string.error_translation)))
            }
        })
    }

    private fun failScreen(generation: Int, message: String) {
        if (screenGeneration.get() != generation) return
        LiveState.update { it.copy(screenState = LiveStatus.ScreenState.IDLE) }
        server?.clear()
        server?.sendSubtitle(message, 6000)
    }

    private fun read(pixels: RegionPixels, area: CropRegion, capturedAt: Long) {
        try {
            // Bölge değişmediyse (aynı altyazı duruyor) yeniden okunmaz; son okuma hattı yine besler (kararlılık ve
            // silme saate bağlıdır, Windows'taki ReadScheduler gibi).
            val current = pipeline ?: return
            val reused = pixels.signature == lastSignature
            val started = com.couchsubs.mobile.core.monotonicClock()
            val result = if (reused) lastReading else reader?.read(pixels) ?: return
            val ocrMs = if (reused) lastOcrMs else (com.couchsubs.mobile.core.monotonicClock() - started).toInt()
            lastSignature = pixels.signature
            lastReading = result
            lastOcrMs = ocrMs
            current.process(result, area.box, com.couchsubs.mobile.core.RegionSignature.of(pixels.nv21, pixels.width, pixels.height),
                capturedAt, ocrMs)
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
            EngineChoice.DEEPL -> DeepLTranslator(key, free, cache = cache(DeepLTranslator.ENGINE_ID), glossary = glossaryInUse)
            else -> {
                val provider = when (engine) {
                    EngineChoice.GEMINI -> AiProvider.GEMINI
                    EngineChoice.OPENAI -> AiProvider.OPENAI
                    else -> AiProvider.CLAUDE
                }
                val models = aiModels()[provider.id].orEmpty()
                val model = models.firstOrNull { it.id == settings.aiModel } ?: models.firstOrNull() ?: return null
                AiTranslator(provider, key, model, free, cache = cache(AiTranslator.engineId(provider, model)),
                    playedGame = { packs?.scopeTitle })
            }
        }
    }

    private fun aiModels(): Map<String, List<AiModel>> = AiModel.load(this)

    /** Motorun kalıcı önbelleği: files/Translations/v1-<motor>-en-tr.jsonl (iPhone'daki Translations klasörüyle aynı biçim). */
    private fun cache(engine: String) = TranslationCache.shared(File(filesDir, "Translations"), engine)

    @Volatile private var glossaryInUse = Glossary.Empty

    /** Xbox hatasının ekrandaki anlatımı. */
    private fun describeXbox(kind: XboxError): String = getString(when (kind) {
        XboxError.SIGN_IN_REQUIRED, XboxError.CODE_EXPIRED, XboxError.SIGN_IN_DECLINED -> R.string.xbox_error_sign_in
        XboxError.NO_XBOX_ACCOUNT -> R.string.xbox_error_no_account
        XboxError.CONSOLE_UNAVAILABLE -> R.string.xbox_error_console
        XboxError.BUSY -> R.string.xbox_error_busy
        XboxError.TIMEOUT -> R.string.xbox_error_timeout
        XboxError.NETWORK -> R.string.xbox_error_network
        XboxError.SERVICE -> R.string.xbox_error_service
    })

    private fun describe(state: SessionState): String =
        // Xbox oturumu nedeni kullanıcının dilinde verir.
        if (state is SessionState.Disconnected && state.kind == DisconnectKind.OTHER && settings.xbox && state.detail != null) state.detail
        else describePs(state)

    private fun describePs(state: SessionState): String = when (state) {
        SessionState.Connecting -> getString(R.string.phase_connecting)
        SessionState.Streaming -> getString(R.string.phase_streaming)
        is SessionState.Disconnected -> when (state.kind) {
            DisconnectKind.IN_USE -> getString(R.string.phase_in_use)
            DisconnectKind.NOT_FOUND -> state.detail?.let { getString(R.string.phase_not_found_host, it) } ?: getString(R.string.phase_not_found)
            DisconnectKind.NETWORK -> getString(R.string.phase_network)
            DisconnectKind.REGISTRATION_INVALID -> getString(R.string.phase_registration_invalid)
            DisconnectKind.NO_PICTURE -> getString(R.string.phase_no_picture)
            DisconnectKind.CONSOLE_ASLEEP -> getString(R.string.phase_asleep)
            DisconnectKind.LOGIN_PASSCODE -> getString(R.string.phase_passcode)
            DisconnectKind.LOGIN_PASSCODE_INCORRECT -> getString(R.string.phase_passcode_incorrect)
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

    /** Kurulan parçaları kapatır; onDestroy'dan ve hizmet kurulum bitmeden durdurulduysa kurulum iş parçacığından çağrılır. */
    private fun releaseParts() = synchronized(lifecycle) {
        PlayedGame.stop()
        styleListener?.let(settings::removeListener)
        styleListener = null
        targetListener?.let(settings::removeListener)
        targetListener = null
        areasListener?.let(settings::removeListener)
        areasListener = null
        regionWatcher?.reset()
        regionWatcher = null
        regionReader?.close()
        regionReader = null
        session?.dispose()
        session = null
        pipeline?.reset()
        pipeline?.shutdown()
        pipeline = null
        liveServer = null
        server?.stop()
        server = null
        reader?.close()
        reader = null
        freeTranslator?.close()
        freeTranslator = null
        pool?.let { linePool -> Thread { linePool.flush() }.start() }
        pool = null
    }

    override fun onDestroy() {
        synchronized(lifecycle) { destroyed = true }
        Services.onLocalPacksChanged = null
        settings.translating = false
        if (startedAt > 0) settings.lastSessionMs = System.currentTimeMillis() - startedAt
        if (startedAt > 0) Telemetry.event(Telemetry.SESSION_STOP, "seconds" to (System.currentTimeMillis() - startedAt) / 1000,
            "pack_lines" to (pipeline?.packHits ?: 0), "lines" to LiveState.status.value.recent.size)
        releaseParts()
        background.shutdownNow()
        ocr.shutdownNow()
        regionWork.shutdownNow()
        screenGeneration.incrementAndGet()
        screenTask?.cancel(true)
        screenWork.shutdownNow()
        screenExpiry.shutdownNow()
        screenReader?.close()
        screenReader = null
        if (current === this) current = null
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLock?.takeIf { it.isHeld }?.release()
        LiveState.update { it.copy(running = false, phase = "", current = "", previous = "", regions = emptyList(), screen = emptyList(), screenState = LiveStatus.ScreenState.IDLE) }
        super.onDestroy()
    }
}
