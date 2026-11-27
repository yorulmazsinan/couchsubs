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
import com.couchsubs.mobile.account.SessionHealth
import com.couchsubs.mobile.account.Telemetry
import com.couchsubs.mobile.core.ConnectStep
import com.couchsubs.mobile.core.ConnectingHint
import com.couchsubs.mobile.core.CropRegion
import com.couchsubs.mobile.core.PhoneChatMemory
import com.couchsubs.mobile.core.ScreenPhoneFollow
import com.couchsubs.mobile.ocr.CopiedPhoneImage
import com.couchsubs.mobile.core.DemoTranslator
import com.couchsubs.mobile.core.watched
import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.core.GameSense
import com.couchsubs.mobile.core.LinePool
import com.couchsubs.mobile.packs.PackStore
import com.couchsubs.mobile.core.PackLookup
import com.couchsubs.mobile.core.ScreenTranslation
import com.couchsubs.mobile.core.SubtitleEvent
import com.couchsubs.mobile.core.SubtitlePairing
import com.couchsubs.mobile.core.SubtitlePipeline
import com.couchsubs.mobile.core.SubtitleServer
import com.couchsubs.mobile.core.TextTranslator
import com.couchsubs.mobile.ocr.RegionPixels
import com.couchsubs.mobile.ocr.SubtitleReader
import com.couchsubs.mobile.remoteplay.ConsoleDiscovery
import com.couchsubs.mobile.remoteplay.ConsoleFinder
import com.couchsubs.mobile.remoteplay.DisconnectKind
import com.couchsubs.mobile.remoteplay.FrameSource
import com.couchsubs.mobile.remoteplay.FrameSourceFactory
import com.couchsubs.mobile.remoteplay.RegisteredConsole
import com.couchsubs.mobile.remoteplay.FrameSources
import com.couchsubs.mobile.remoteplay.NativeBridge
import com.couchsubs.mobile.remoteplay.SampleFrameSource
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
import com.couchsubs.mobile.translation.ModelDownloadProblem
import com.couchsubs.mobile.translation.ModelDownloadRecovery
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
        private val WHOLE_FRAME = CropRegion(0.0, 1.0, 0.0, 1.0)
        /** Değişmeyen bölgenin son okuması kaç kare yeniden kullanılır (Mac/iPhone/Windows ReadScheduler ile aynı). */
        private const val DEFAULT_MAX_REUSE = 20
        private const val FAST_MAX_REUSE = 2
        private const val CHANNEL = "translation"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.couchsubs.mobile.STOP"
        /** Yazı tanıma en çok saniyede bu kadar kare okur (telefon ısınmasın; altyazı için yeterli). */
        private const val MAX_READS_PER_SECOND = 5
        /** PS5'e çalışan oyunun sorulma aralığı (ortak havuz). */
        private const val GAME_PROBE_MS = 2 * 60 * 1000L
        /** TV bağlantısı koptuktan sonra en çok bu kadar "yeniden bağlanılıyor" gösterilir (Mac/iPhone/Windows ile aynı). */
        const val TV_RECONNECT_MS = 60_000L

        fun start(context: Context) {
            context.startForegroundService(Intent(context, TranslationService::class.java))
        }

        /** Sıradaki başlatma deneme modunda mı (bkz. [startDemo]); hizmet başlarken okunup sıfırlanır. */
        @Volatile private var demoRequested = false

        /**
         * Deneme modu: konsol, hesap ve TV olmadan kodda çizilmiş örnek karelerle ([SampleFrameSource]) çeviri başlar;
         * hattın geri kalanı (yazı tanıma, çeviri, telefon/TV) gerçekteki gibi çalışır (iPhone ve Mac ile aynı).
         */
        fun startDemo(context: Context) {
            demoRequested = true
            start(context)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, TranslationService::class.java).setAction(ACTION_STOP))
        }

        /**
         * "Yeniden bağlan": konsol oturumu kapatılıp yenisi açılır, çeviri sürer. Eskiden oturum yeniden denemeyi
         * bırakınca (görüntü gelmiyor, PS5'te Uzaktan Oynatma çöktü) ya da uzun süre bağlanamayınca tek çare çeviriyi ya
         * da uygulamayı kapatıp açmaktı (Mac/iPhone ile aynı).
         */
        fun reconnect() {
            val service = current ?: return
            runCatching { service.background.execute { service.reconnectSession() } }
        }

        /** Çalışan hizmet ("ekranı çevir" düğmesi buraya gelir). */
        @Volatile private var current: TranslationService? = null

        /**
         * "Ekranı çevir": PS5'in şu anki karesinin tamamı bir kez okunur, yazı grupları tek istekte çevrilir; sonuçlar
         * telefonda ve TV'de yazının yerinde görünür. Çeviri sürerken ya da sonuçlar ekrandayken yeniden çağrılmak onları
         * kaldırır (Mac'in ekranı çevir kısayolu ve iPhone ile aynı). Çeviri çalışmıyorsa false.
         */
        fun resolvePairing(id: String, accept: Boolean) {
            val pairing = liveServer?.pairing
            val host = pairing?.pending?.takeIf { it.id == id }?.host.orEmpty()
            val resolved = pairing?.resolve(id, accept) == true
            if (resolved && accept) adoptPairedTv(host)
            Log.i(TAG, "TV eşleştirme isteği ${if (accept) "onaylandı" else "reddedildi"}${if (resolved) "" else " (istek artık geçerli değil)"}")
            // Onaylanan istek geçersizdiyse (süresi doldu, TV yeniden denedi) bekleyen yeni istek hemen gösterilir; yeni
            // istek yoksa "süresi doldu" yazılır (iPhone ve Mac ile aynı).
            val pending = pairing?.pending
            LiveState.update { it.copy(pairing = pending, error = if (accept && !resolved && pending == null) current?.getString(R.string.tv_pair_expired) else it.error) }
            if (pairing != null) syncPairing(pairing)
        }

        @Volatile private var pairingWatch: Thread? = null

        /**
         * TV'nin kendisi başlattığı eşleşme onaylandı: TV, listeden seçilmiş gibi kaydedilir (adres, marka, ad; TV izni/jetonu
         * TV açılırken alınır; bkz. [com.couchsubs.mobile.tv.PairedTv]) ve çeviri sürüyorsa TV bekçisi bu TV için kurulur.
         * Eskiden yalnız altyazı anahtarı TV'ye gidiyordu: TV kaydı olmadığı için bekçi (otomatik açma) hiç çalışmıyor, ana
         * ekranda TV kartı çıkmıyordu (Mac, iPhone, Windows ile aynı).
         */
        private fun adoptPairedTv(host: String) {
            val settings = Services.settings
            if (!com.couchsubs.mobile.tv.PairedTv.shouldAdopt(host, settings.installedTv)) return
            Thread({
                val found = runCatching { com.couchsubs.mobile.tv.PairedTv.identify(host) }.getOrNull()
                if (found == null) { Log.i(TAG, "Eşleşen TV'nin türü anlaşılamadı ($host); TV kaydedilmedi"); return@Thread }
                if (!com.couchsubs.mobile.tv.PairedTv.shouldAdopt(host, settings.installedTv)) return@Thread
                settings.installedTv = com.couchsubs.mobile.tv.TvChoice.select(null, found)
                settings.tvName = found.name
                // "Yalnız bu telefonda" seçiliyken TV eşlenirse altyazı TV'ye gider (TV seçilince olduğu gibi).
                if (!settings.target.showsOnTv) settings.target = com.couchsubs.mobile.settings.SubtitleTarget.TV
                Log.i(TAG, "Eşleşen TV kaydedildi: ${found.brand} ${found.host}")
                current?.let { service -> service.server?.accessKey?.let { key -> service.launchTv(key) } }
            }, "CouchSubs paired TV").apply { isDaemon = true }.start()
        }

        /**
         * Arayüzdeki isteği sunucudaki bekleyen istekle eşitler. İstek geldiğinde, bir ekran öne geldiğinde ve istek
         * beklerken saniyede bir çağrılır: gösterilemeyen istek kaybolmaz, süresi dolan ya da yerini yenisi alan istek
         * ekranda kalmaz (iPhone'daki `syncTVPairing` ile aynı). Çeviri durunca sunucu eşleştirmeyi kapatır, izleme biter.
         */
        fun syncPairing(pairing: SubtitlePairing? = liveServer?.pairing) {
            val pending = pairing?.pending
            LiveState.update { if (it.pairing != pending) it.copy(pairing = pending) else it }
            if (pairing == null || pending == null) return
            synchronized(this) {
                if (pairingWatch != null) return
                pairingWatch = Thread({
                    try {
                        while (true) {
                            Thread.sleep(1000)
                            val waiting = pairing.pending
                            LiveState.update { if (it.pairing != waiting) it.copy(pairing = waiting) else it }
                            if (waiting == null) break
                        }
                    } catch (_: InterruptedException) {
                    } finally { synchronized(this) { pairingWatch = null } }
                }, "CouchSubs TV pairing").apply { isDaemon = true; start() }
            }
        }
        fun viewerAddress(): String? {
            val host = localHost() ?: return null
            return "http://$host:${current?.subtitlePort ?: 8787}/obs?k=${Services.settings.subtitleAccessKey}"
        }
        /** "Başka bir cihazda göster" adresi (QR kodu da bundan): telefonun ev ağındaki adresi ve erişim anahtarı. */
        fun secondScreenAddress(): String? {
            val host = localHost() ?: return null
            return com.couchsubs.mobile.core.SecondScreen.address(host, current?.subtitlePort ?: 8787, Services.settings.subtitleAccessKey)
        }
        private fun localHost(): String? = runCatching {
            java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces())
                .filter { it.isUp && !it.isLoopback }.sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
                .flatMap { java.util.Collections.list(it.inetAddresses) }
                .firstOrNull { it is java.net.Inet4Address && com.couchsubs.mobile.core.SubtitleAccess.isLocalPeer(it) }?.hostAddress
        }.getOrNull()
        fun renewAccessKey() {
            val key = Services.settings.renewSubtitleAccessKey()
            liveServer?.rotateKey(key)
            current?.launchTv(key)
            LiveState.update { it.copy(pairing = null) }
        }
        /** Ayarlar'da "Konuşan adını renklendir" değişti: çeviri sürüyorsa sonraki satırlar hemen yeni ayarla gider. */
        fun setSpeakerColors(on: Boolean) {
            liveServer?.speakerColors = on
        }

        /** "Ekran yazılarını altyazıdan ayır" değişti: TV yeni çizimi hemen alır (style olayı). */
        fun setTextApart(on: Boolean) {
            val server = liveServer ?: return
            server.setApart = on
            server.sendStyle(Services.settings.style)
        }
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

        /** Altyazı sunucusuna bağlı TV sayısı (telefonun kendi altyazı ekranı sayılmaz); çeviri çalışmıyorsa 0. */
        fun connectedTvs(): Int = liveServer?.connectedClients ?: 0

        /**
         * Çeviri dışında açılan bekleme sunucusu ("TV'yi eşle" ve deneme altyazısı; iPhone `openTVPairing` ile aynı): TV
         * uygulaması telefonu bulup eşleşebilsin diye altyazı sunucusu iki dakika açık kalır. Çeviri başlayınca kapanır
         * (aynı kapıyı oturumun sunucusu açar). Eskiden Android'de eşleşme yalnız çeviri sürerken yapılabiliyordu.
         */
        @Volatile private var standby: SubtitleServer? = null
        private val standbyTimer = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs standby").apply { isDaemon = true } }
        private var standbyClose: java.util.concurrent.ScheduledFuture<*>? = null
        /** Bekleme sunucusuna TV bağlanınca gönderilecek deneme altyazısı. */
        @Volatile private var pendingTest: String? = null
        const val STANDBY_MS = 120_000L

        /** "TV'yi eşle": çeviri sürüyorsa onun sunucusunda, değilse bekleme sunucusunda 2 dakikalık eşleşme açılır. */
        fun openPairing(context: Context): Boolean {
            liveServer?.let { live ->
                live.pairing.open()
                return true
            }
            return openStandby(context)
        }

        /**
         * Deneme altyazısı her zaman gönderilebilir (iPhone ile aynı): çeviri sürmüyorsa bekleme sunucusu açılır, TV
         * uygulaması bağlanınca altyazı gider. Sunucu açılamazsa false.
         */
        fun testSubtitle(context: Context, text: String): Boolean {
            val server = liveServer
            if (server != null && (standby == null || server.connectedClients > 0)) {
                server.sendSubtitle(text, 8000)
                return true
            }
            pendingTest = text
            return openStandby(context)
        }

        @Synchronized private fun openStandby(context: Context): Boolean {
            standby?.let { open ->
                open.pairing.open()
                scheduleStandbyClose()
                return true
            }
            if (current != null) return false
            val settings = Services.settings
            val app = context.applicationContext
            val server = SubtitleServer(instanceId = installationId(app), key = settings.subtitleAccessKey,
                obsOverlay = runCatching { app.assets.open("obs-overlay.html").bufferedReader().use { it.readText() } }.getOrDefault(""),
                secondScreenPage = runCatching { app.assets.open("second-screen.html").bufferedReader().use { it.readText() } }.getOrDefault(""))
            server.onPairingRequest = { _ -> syncPairing(server.pairing) }
            server.sendsToTv = true
            server.onClientsChanged = { count ->
                LiveState.update { it.copy(connectedTvs = count) }
                if (count > 0) pendingTest?.let { text ->
                    pendingTest = null
                    // Bağlanan TV önce görünümü (style) alır, sonra deneme altyazısını.
                    Thread({ Thread.sleep(500); server.sendSubtitle(text, 8000) }, "CouchSubs test subtitle").apply { isDaemon = true }.start()
                }
            }
            try {
                server.start()
            } catch (error: Exception) {
                Log.w(TAG, "Bekleme sunucusu açılamadı", error)
                return false
            }
            server.sendStyle(settings.style)
            server.pairing.open()
            standby = server
            liveServer = server
            scheduleStandbyClose()
            Log.i(TAG, "Bekleme sunucusu açıldı (TV eşleşmesi / deneme altyazısı)")
            return true
        }

        private fun scheduleStandbyClose() {
            standbyClose?.cancel(false)
            standbyClose = standbyTimer.schedule({ stopStandby() }, STANDBY_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
        }

        /** Bekleme sunucusunu kapatır (süre doldu ya da çeviri başlıyor). */
        @Synchronized fun stopStandby() {
            val server = standby ?: return
            standby = null
            pendingTest = null
            standbyClose?.cancel(false)
            if (liveServer === server) liveServer = null
            runCatching { server.stop() }
            LiveState.update { it.copy(connectedTvs = 0, pairing = null) }
        }

        /** Bekleme sunucusu açık mı (Ayarlar'daki "eşleşme açık" notu). */
        val standbyOpen: Boolean get() = standby != null
    }

    @Volatile private var subtitlePort = 8787
    /** Her TV açma döngüsünün kuşağı: telefonun adresi değişince eski döngü biter, yenisi yeni adresle kurulur. */
    private val tvLaunchGeneration = java.util.concurrent.atomic.AtomicInteger()
    private var addressWatcher: com.couchsubs.mobile.tv.SenderAddressWatcher? = null

    /**
     * Telefonun ev ağı adresini izler (çeviri sürerken). Adres değişince (modem yeniden başladı, başka Wi-Fi) TV açma
     * döngüsü yeni adresle yeniden kurulur: LG ve Samsung'da açma komutu, Android TV'de adres komutu yeni sunucu adresini
     * TV'ye hemen götürür (Mac, iPhone ve Windows ile aynı). Eskiden TV eski adrese bağlanmaya çalışıp ağı taramaya düşüyordu.
     */
    private fun watchSenderAddress() {
        if (addressWatcher != null) return
        addressWatcher = com.couchsubs.mobile.tv.SenderAddressWatcher { old, new ->
            val key = server?.accessKey ?: return@SenderAddressWatcher
            if (destroyed) return@SenderAddressWatcher
            val line = com.couchsubs.mobile.tv.SenderAddressWatcher.line(old, new)
            Log.i(TAG, line)
            com.couchsubs.mobile.tv.TvRelocation.log(this).write(line)
            launchTv(key)
        }.also { it.start(this) }
    }

    private fun launchTv(key: String) {
        if (!settings.target.showsOnTv) return
        val generation = tvLaunchGeneration.incrementAndGet()
        val active = { !destroyed && server?.accessKey == key && tvLaunchGeneration.get() == generation }
        // Arka plan bekçileri TV'ye bağlanamayınca TV ağda yeniden aranır, kayıt güncellenir (bkz. TvRelocation).
        val relocate = { com.couchsubs.mobile.tv.TvRelocation.relocateForKeeper(this) }
        val connected = { (server?.connectedClients ?: 0) > 0 }
        com.couchsubs.mobile.tv.TvOpenRetry.clear()
        // Açma denemesinin sonucu ana ekrana gider (TV uygulaması bağlı değilken nedeni söylenir).
        val report: (com.couchsubs.mobile.tv.TvOpenProblem?) -> Unit = { problem ->
            val tv = settings.installedTv
            val shown = if (tv == null || connected() || !active()) null else com.couchsubs.mobile.tv.TvOpenProblem.shown(problem, tv.brand,
                hasKey = settings.secrets.get("tv.control.${tv.brand}.${tv.host}") != null)
            if (LiveState.status.value.tvOpenProblem != shown) LiveState.update { it.copy(tvOpenProblem = shown) }
        }
        // Samsung: önce geliştirici bağlantısı (sdb `was_execute`); sdb portu kapalıysa beklemeden uzaktan kumandaya geçilir.
        // "resumed" (uygulama çalışıyor ama bağlı değil) 8002'ye düşmez; bağlanmazsa sdb ile kapatılıp açılır (#1248).
        val openWithSdb: (Boolean) -> com.couchsubs.mobile.tv.samsung.SdbOpen = open@{ restart ->
            val tv = settings.installedTv
            if (tv == null || tv.brand != com.couchsubs.mobile.tv.TvBrand.SAMSUNG ||
                !com.couchsubs.mobile.tv.android.AndroidTvInstaller.isReachable(tv.host, com.couchsubs.mobile.tv.samsung.SdbConnection.PORT)) {
                return@open com.couchsubs.mobile.tv.samsung.SdbOpen.FAILED
            }
            com.couchsubs.mobile.tv.samsung.SamsungInstaller(
                    host = tv.host,
                    profilesDirectory = java.io.File(noBackupFilesDir, "samsung"),
                    adbKey = { com.couchsubs.mobile.tv.samsung.AdbKey.loadOrCreate(java.io.File(noBackupFilesDir, "sdb/adbkey")) },
                    certificates = com.couchsubs.mobile.tv.samsung.SamsungCertificates(),
                    signIn = null,
                    log = com.couchsubs.mobile.tv.samsung.InstallLog(java.io.File(filesDir, "tvinstall.log")),
                ).openApp(restart)
        }
        // Gönderilmeyen açma isteği (kurulu olduğu doğrulanmadı) tvinstall.log'a da yazılır (Windows/Mac/iPhone ile aynı).
        val tvInstallLog = com.couchsubs.mobile.tv.samsung.InstallLog(java.io.File(filesDir, "tvinstall.log"))
        Thread({ runCatching {
            com.couchsubs.mobile.tv.TvSessionLauncher.launch(settings, subtitlePort, key,
                adbKeyFile = java.io.File(noBackupFilesDir, "adb/adbkey"), connected = connected,
                log = { Log.i(TAG, it) }, onOpenResult = report, openWithSdb = openWithSdb, installLog = tvInstallLog::write, active = active)
            // LG: PS tuşu TV'yi PS5'in girişine geçirince uygulama geri getirilir (Windows/Mac/iPhone bekçisiyle aynı).
            // Açık ve bağlı uygulamaya açma komutu gitmez (#1055; Mac, iPhone ve Windows ile aynı).
            com.couchsubs.mobile.tv.TvSessionLauncher.keepLgOpen(settings, subtitlePort, key, consolePort = { server?.consolePort },
                log = { Log.i(TAG, it) }, onOpenResult = report, connected = connected, relocate = relocate) { active() && settings.target.showsOnTv }
            // Samsung: TV uygulaması bağlı değilken arada bir (ya da "Otomatik açmayı dene"de hemen) yeniden açılır.
            com.couchsubs.mobile.tv.TvSessionLauncher.keepSamsungOpen(settings, subtitlePort, key, connected = connected,
                log = { Log.i(TAG, it) }, onOpenResult = report, openWithSdb = openWithSdb,
                lastResult = { LiveState.status.value.tvOpenProblem }, installLog = tvInstallLog::write, relocate = relocate,
                active = { active() && settings.target.showsOnTv })
        } }, "CouchSubs TV launch").apply { isDaemon = true }.start()
    }
    private lateinit var settings: AppSettings
    @Volatile private var tvReconnectTimer: java.util.concurrent.ScheduledFuture<*>? = null

    /** "Yeniden bağlanılıyor": TV bağlanınca ya da [TV_RECONNECT_MS] dolunca kalkar (sonra "TV'de açın" kartı kalır). */
    private fun markTvReconnecting() {
        if (LiveState.status.value.connectedTvs > 0) return
        LiveState.update { it.copy(tvReconnecting = true) }
        tvReconnectTimer?.cancel(false)
        tvReconnectTimer = try {
            background.schedule({ LiveState.update { it.copy(tvReconnecting = false) } }, TV_RECONNECT_MS, TimeUnit.MILLISECONDS)
        } catch (_: java.util.concurrent.RejectedExecutionException) { null }
    }
    @Volatile private var session: FrameSource? = null
    /** Konsol oturumunu yeniden kuran üretici ("Yeniden bağlan"); her yeni oturum [sourceGeneration]'ı artırır. */
    @Volatile private var sourceFactory: (() -> FrameSource)? = null
    @Volatile private var sourceGeneration = 0
    /** "Yeniden bağlan" düğmesi için bağlantının ne zamandan beri gittiği (Mac/iPhone ile aynı; bkz. [ReconnectOffer]). */
    private val reconnectOffer = com.couchsubs.mobile.remoteplay.ReconnectOffer()
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
    /**
     * Altyazı hattının göndericisi: ekranda menü varken satırları bekletir, menü kapanınca konuşma satırını gönderir
     * (#1240); her karede yoklanır, geçişleri günlüğe yazar (Mac/iPhone ile aynı satırlar).
     */
    @Volatile private var menuSender: com.couchsubs.mobile.core.MenuHeldSender? = null
    private var lastSignature = 0L
    private var lastReading = com.couchsubs.mobile.core.Reading.Empty
    @Volatile private var lastOcrMs: Int? = null
    /** Süren altyazı okumasının başladığı an (hattın saatiyle); okuma yokken 0. */
    @Volatile private var readStartedAt = 0L
    private var reusedReads = 0
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLocks: List<WifiManager.WifiLock> = emptyList()
    /**
     * Oynanan oyunun hazır ek alanları ([com.couchsubs.mobile.core.GameAreaPresets]); kullanıcının kendi ek alanı yoksa
     * sürekli okunanlara eklenir. Ayarlara yazılmaz; oyun ya da ayar değişince yeniden hesaplanır.
     */
    @Volatile private var presetAreas: List<com.couchsubs.mobile.core.ExtraArea> = emptyList()
    /** Altyazı hattının altyazıdan ayırdığı görev satırının ek alanı ([com.couchsubs.mobile.core.MissionLine]); yoksa boş. */
    @Volatile private var missionAreas: List<com.couchsubs.mobile.core.ExtraArea> = emptyList()
    /** Altyazı hattının altyazıdan ayırdığı kenar bildirimlerinin ek alanları ([com.couchsubs.mobile.core.ScreenNotices]); yoksa boş. */
    @Volatile private var noticeAreas: List<com.couchsubs.mobile.core.ExtraArea> = emptyList()
    @Volatile private var playedGame: String? = null

    /**
     * "GTA 6'daki telefonu otomatik çevir": GTA 6 oynanırken oyun içi telefonun pozu izlenir; telefon açıkken ekranı
     * [regionWatcher]'da okunup "game-phone" alanı olarak gönderilir, hazır telefon mesajı alanı ve otomatik ekran yazısı
     * okunmaz (Mac ve Windows ile aynı).
     */
    private val phoneTracker = com.couchsubs.mobile.core.GamePhoneTracker()
    /** Altyazı okumasının gördüğü telefon (ekranındaki satırlar altyazı sayılmaz) ve en son ne zaman arandığı. */
    @Volatile private var subtitlePhone: com.couchsubs.mobile.core.ScreenPhoneCard.Handset? = null
    private var subtitlePhoneAt = Long.MIN_VALUE / 2
    /**
     * Açık telefonun art arda bulunamadığı arama sayısı: telefon [com.couchsubs.mobile.core.GamePhoneTracker.MISS_GRACE]
     * aramada bulunamazsa kalkar ([com.couchsubs.mobile.core.SubtitlePipeline.heldPhone]; Mac/iPhone ve Windows ile aynı).
     */
    private var subtitlePhoneMisses = 0
    /**
     * Doğrulanmamış telefon adayı ve ilk görüldüğü an: ekranındaki satırlar kısa süre altyazı sayılmaz
     * ([com.couchsubs.mobile.core.SubtitlePipeline.CANDIDATE_HOLD_MS]; #1251, Mac/iPhone ve Windows ile aynı).
     */
    private var subtitlePhoneCandidate: com.couchsubs.mobile.core.ScreenPhoneCard.Handset? = null
    private var subtitlePhoneCandidateSince = 0L
    @Volatile private var playsGta6 = false
    /** "Telefon çevirisi kapalı, açmak ister misiniz?" ipucu (oturumda bir kez; [com.couchsubs.mobile.core.GamePhoneHint]). */
    private val gamePhoneHint = com.couchsubs.mobile.core.GamePhoneHint()
    @Volatile private var phoneTracking = false
    @Volatile private var phoneOpen = false
    /**
     * Telefon ekranda görünüyor (telefon çevirisi kapalıyken de izlenir): açık telefonun ekranına otomatik ekran yazısı
     * kutusu ve kenar bildirimi çizilmez (Sinan Bey, beta.100 3420–3425). [phoneOpen] telefonun okunmasıdır (ayara bağlı).
     */
    @Volatile private var phoneSeen = false
    /** Görünen telefonun karedeki yeri ([phoneSeen] iken): ekran yazısı telefonun dışında aranır. */
    @Volatile private var phoneBounds: CropRegion? = null

    /**
     * Ekranda beliren yazı kutularını bulan ("Ekran yazılarını otomatik çevir"); bulduğu geçici alanlar ek alanlarla
     * birlikte [regionWatcher]'a verilir. Karo örneği kare iş parçacığında alınır, işlenmesi [detectorWork]'te.
     */
    private val detector = com.couchsubs.mobile.core.ScreenTextDetector().apply {
        // Harita düzeni bulundu/bitti (#1365 tanısı) altyazı günlüğüne.
        onLog = { Log.i(TAG, it) }
    }
    @Volatile private var autoAreas: List<com.couchsubs.mobile.core.ExtraArea> = emptyList()
    @Volatile private var fullScreenArea = false
    private val detectorWork = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs screen text").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } }
    /** Altyazı bölgesi ve ek alanlar (Ayarlar › Altyazı alanı); çeviri sürerken değişirse hemen yenisi okunur. */
    @Volatile private var region = CropRegion()
    @Volatile private var extraAreas: List<com.couchsubs.mobile.core.ExtraArea> = emptyList()
    @Volatile private var areasListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null
    /** Ek alanları ana altyazıdan ayrı ve seyrek (saniyede bir) okuyan; kendi okuyucusu ve iş parçacığı var. */
    @Volatile private var regionWatcher: com.couchsubs.mobile.core.RegionWatcher? = null
    @Volatile private var regionReader: SubtitleReader? = null
    /** Ek alan turunun bütün kare kopyası için yeniden kullanılan arabellek (tur sürerken boştur). */
    private val screenBuffer = java.util.concurrent.atomic.AtomicReference<RegionPixels?>(null)
    private val regionWork = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs extra areas").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } }
    /** Ek alan yazısı kararlı mı diye beklenirken çevirisinin önceden istendiği iş parçacığı (turu bekletmesin). */
    private val regionPrefetch = Executors.newSingleThreadExecutor { Thread(it, "CouchSubs extra area translations").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } }
    private val lifecycle = Any()
    @Volatile private var destroyed = false
    @Volatile private var streaming = false
    /** Bu oturum deneme modunda (örnek kareler; bkz. [startDemo]). */
    @Volatile private var demo = false
    private var begun = false
    @Volatile private var styleListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null
    @Volatile private var targetListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null
    @Volatile private var xboxAudioListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    /** Hazır alanlar: ayar açık, oyunun tabloda satırı var, kullanıcının etkin ek alanı ve etkin alan profili yok. */
    private fun refreshPresetAreas() {
        presetAreas = com.couchsubs.mobile.core.GameAreaPresets.active(
            settings.gameAreaPresets, playedGame, settings.areaPreset, settings.extraAreas, settings.activeAreaProfile != null,
            phoneOpen)
    }

    /**
     * Oyun telefonu: izleyici saniyede üç kez bakar; telefon açıkken o kare kopyalanıp telefon oturumuna verilir. Telefon
     * GTA 6'da her zaman izlenir (telefon çevirisi kapalıyken de): görünen telefonun ([phoneSeen]) ekranına otomatik ekran
     * yazısı kutusu ve kenar bildirimi çizilmez (Sinan Bey, beta.100 3420–3425). Telefonun okunması ayara bağlıdır
     * (telefonun kendi ayarı ya da otomatik ekran yazısında Telefon türü; Mac/iPhone ve Windows ile aynı).
     */
    private fun offerGamePhone(frame: com.couchsubs.mobile.remoteplay.VideoFrame) {
        val watcher = regionWatcher ?: return
        if (!playsGta6) {
            if (phoneTracking) resetGamePhone()
            return
        }
        phoneTracking = true
        val reads = settings.readsGamePhone
        var seen = false
        var seenBounds: CropRegion? = null
        val capture = try {
            val started = System.nanoTime()
            // 30 sn'de bir arama durumu satırı (telefon bulunamasa da): ıska ölçütü, parlaklık, kare biçimi (Xbox'ta libwebrtc
            // karesinin boyutu, düzlem adımları ve aralığı; #1385), ham Y aralığı ve otomatik ekran yazısının durumu.
            val sample = phoneTracker.sample(com.couchsubs.mobile.ocr.LivePhoneImage(frame), com.couchsubs.mobile.core.monotonicClock()) {
                com.couchsubs.mobile.ocr.PhoneFrames.describe(frame) + ", otomatik ekran yazısı " +
                    (if (settings.autoScreenText && !fullScreenArea) "açık (${autoAreas.size} alan)" else "kapalı")
            }
            if (sample.sampled) watcher.timing.add(com.couchsubs.mobile.core.RegionWatcher.STAGE_TRACK, System.nanoTime() - started)
            if (!sample.sampled) {
                // Ayar kapatıldıysa açık telefon oturumu sonraki örneği beklemeden kapanır.
                if (!reads && phoneOpen) {
                    watcher.closePhone()
                    setPhoneOpen(false)
                }
                return
            }
            seen = sample.pose != null
            seenBounds = sample.pose?.bounds
            if (reads) sample.pose?.let { com.couchsubs.mobile.ocr.PhoneFrames.copy(frame, it) } else null
        } catch (error: Exception) {
            null
        }
        if (seen != phoneSeen) {
            Log.i(TAG, if (seen) "telefon açık: ekran yazısı telefonun dışında aranıyor" else "telefon kapandı: ekran yazısı bütün ekranda aranıyor")
        }
        phoneSeen = seen
        phoneBounds = seenBounds
        if (capture != null) watcher.observePhone(capture) else watcher.closePhone()
        setPhoneOpen(capture != null)
    }

    private fun resetGamePhone() {
        phoneTracking = false
        phoneTracker.reset()
        regionWatcher?.closePhone()
        phoneSeen = false
        phoneBounds = null
        setPhoneOpen(false)
    }

    private fun setPhoneOpen(open: Boolean) {
        if (phoneOpen == open) return
        phoneOpen = open
        refreshPresetAreas()
    }

    /**
     * "Ekran yazılarını otomatik çevir": en çok 10 Hz karo örneği alınır (kare iş parçacığında yalnız 32×18×144 nokta
     * okunur), arkada işlenir. Ayar kapalıyken ya da altyazı alanı Tam ekranken bulunan alanlar bırakılır.
     */
    private fun offerScreenText(frame: com.couchsubs.mobile.remoteplay.VideoFrame) {
        if (regionWatcher == null) return
        // Oyun telefonu açıkken ekranı telefon oturumu okur; otomatik ekran yazısı aynı yazıyı ikinci kez çevirmesin. Telefon
        // çevirisi kapalıyken de görünen telefonun ekranına kutu çizilmez ([phoneSeen]): telefonun yeri dışlanır, dışındaki
        // tuş çubuğu ("SCROLL / SEND / EXIT") yine çevrilir ([com.couchsubs.mobile.core.ScreenTextDetector.outsidePhone]).
        if (fullScreenArea || !settings.autoScreenText) {
            if (autoAreas.isNotEmpty()) resetScreenText()
            return
        }
        if (!detector.begin()) return
        val sample = try {
            val buffer = frame.buffer
            val stride = frame.rowStride
            detector.sample(frame.width, frame.height) { x, y -> buffer.get(y * stride + x).toInt() and 0xff }
        } catch (error: Exception) {
            detector.finished()
            return
        }
        // Altyazı alanı ve kullanıcının ek alanları zaten okunuyor: oradaki yazı ikinci kez önerilmez. Oyunun hazır alanları
        // (GTA 6 yardım/mesaj köşesi) dışlanmaz: üstlerine taşan yazı (haritanın konum kartı) tek alan olarak bulunur, hazır
        // alan o sırada okunmaz ([com.couchsubs.mobile.core.RegionWatcher.yieldingPresets], #1391).
        val phone = if (phoneSeen) phoneBounds else null
        val excluded = extraAreas.map { it.region } +
            listOfNotNull(phone?.let { com.couchsubs.mobile.core.ScreenTextDetector.paddedPhone(it) })
        val subtitle = region
        try {
            detectorWork.execute {
                try {
                    autoAreas = detector.update(sample, excluded, subtitle = subtitle)
                } finally {
                    detector.finished()
                }
            }
        } catch (error: java.util.concurrent.RejectedExecutionException) {
            detector.finished()
        }
    }

    private fun resetScreenText() {
        detector.reset()
        autoAreas = emptyList()
    }

    override fun onCreate() {
        super.onCreate()
        settings = AppSettings(this)
        current = this
        // Kendi günlüğü olmayan bileşenlerin (ScreenPresence, translateAll) düşen satır notları logcat'e (Mac/iPhone
        // ve Windows'ta altyazı günlüğü); "Günlükleri paylaş" bunları da toplar.
        com.couchsubs.mobile.core.DropLog.sink = { Log.i(TAG, it) }
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
        // Çeviri dışında açılan bekleme sunucusu aynı kapıyı tutar; oturumun sunucusundan önce kapanır.
        stopStandby()
        demo = demoRequested
        demoRequested = false
        val xbox = settings.xbox && !demo
        val console = settings.console
        val accountId = settings.accountId
        // Xbox (Beta): Microsoft girişi ve seçili Xbox yeter; PSN ve PS5 eşlemesi gerekmez.
        if (demo) {
            // Deneme modunda eşleme gerekmez.
        } else if (xbox && (settings.xboxConsole == null || !Services.xboxAuth.signedIn)) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_xbox_not_ready)) }
            stopSelf()
            return
        }
        if (!demo && !xbox && (console == null || accountId == null)) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_not_paired)) }
            stopSelf()
            return
        }
        // Yerine geçen kaynak yalnız debug yapısında kurulur (Play görüntüleri için kayıtlı klip); PS5 kitaplığı gerekmez.
        val replacement = if (demo) FrameSourceFactory { _, onFrame, onState -> SampleFrameSource(onFrame, onState) }
            else FrameSources.replacement
        if (replacement == null && !xbox && !NativeBridge.available) {
            LiveState.update { it.copy(running = false, error = getString(R.string.error_native)) }
            stopSelf()
            return
        }
        acquireLocks()
        settings.lastHealth = null
        settings.translating = true
        Backend.breadcrumb("çeviri: başlıyor (${settings.target.name}, ${settings.engine.name}, paketler ${settings.packsEnabled})")
        // Oturum başı ayar özeti: telefon okuyucusunun açık mı kapalı mı olduğu günlükte görünsün (#1202).
        Log.i(TAG, "oturum başladı: " + com.couchsubs.mobile.settings.SessionLogSummary.of(settings.autoScreenText, settings.readsGamePhone))
        synchronized(gamePhoneHint) { gamePhoneHint.reset() }
        // Çevrimiçi motor satırı ücretsiz çeviriye bıraktığında nedeni günlüğe gider (Mac/Windows ile aynı).
        com.couchsubs.mobile.translation.SentenceTranslator.fallbackLog = Backend::breadcrumb
        startedAt = System.currentTimeMillis()
        LiveState.update { LiveStatus(running = true, demo = demo, phase = getString(R.string.phase_preparing), startedAt = startedAt, engineLabel = engineLabel()) }
        TvAwayAlert.reset(this)
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
        val xboxConsole = if (settings.xbox && !demo) settings.xboxConsole else null
        // Paketler ücretsiz: uygulamayla gelenler ve sunucudan inmiş güncel sürümler. Ayardan kapatılırsa aranmaz.
        // Önceki oturumun kitaplığı yenisi açılmadan bırakılır; ikisi birden bellekte kalırsa GTA 6 paketi açılamıyordu (#1282).
        PlayedGame.packs = null
        packs = null
        val library = Services.packLibrary(this)
        packs = library
        // Terim sözlüğü ve kalıcı önbellek (iPhone ile aynı biçim): önceki oturumlarda çevrilen cümleler hemen gelir.
        val glossary = Glossary.load(this)
        glossaryInUse = glossary
        // Oyunun dili İngilizce değilse ücretsiz çeviri o dilden çevirir; önbellek dile göre ayrıdır, terim sözlüğü yalnız İngilizcede.
        val english = settings.sourceLanguage == "en"
        val free = MlKitTranslator(if (english) cache(MlKitTranslator.ENGINE_ID)
            else TranslationCache.shared(File(filesDir, "Translations"), MlKitTranslator.ENGINE_ID, settings.sourceLanguage),
            if (english) glossary else Glossary.Empty, settings.sourceLanguage).also { freeTranslator = it }
        val translator = engineTranslator(free)
        val subtitleServer = SubtitleServer(instanceId = installationId(this), key = settings.subtitleAccessKey, obsOverlay = assets.open("obs-overlay.html").bufferedReader().use { it.readText() },
            secondScreenPage = assets.open("second-screen.html").bufferedReader().use { it.readText() }).also { server = it }
        subtitleServer.pairing.setSession(true)
        subtitleServer.onPairingRequest = { _ ->
            Log.i(TAG, "TV eşleştirme istedi; onay bekleniyor")
            syncPairing(subtitleServer.pairing)
        }
        subtitleServer.onLegacyClient = { LiveState.update { it.copy(legacyTv = true) }; Log.i(TAG, "TV uygulamasını güncelleyin; geçiş bağlantısı.") }
        // TV uygulaması sürümünü akışla bildirir; eskiyse ana ekran "TV uygulamasını güncelle" der (#884, #891).
        subtitleServer.onTvAppVersion = { version, host ->
            runCatching { com.couchsubs.mobile.tv.TvAppUpdate.reported(applicationContext, version, host) }
                .onFailure { Log.w(TAG, "TV uygulaması sürümü işlenemedi: ${it.message}") }
        }
        // Telefondaki TV paketinin sürümü `link` olayıyla TV'ye gider; TV daha eskiyse paneli "TV uygulaması eski" der
        // (GitHub #1199). TV seçilmemişse LG paketi (sürümler aynı). Windows, Mac ve iPhone ile aynı.
        subtitleServer.latestTvAppVersion = runCatching {
            val tvApps = com.couchsubs.mobile.tv.TvAppUpdate
            tvApps.bundledVersion(applicationContext, settings.installedTv?.brand ?: com.couchsubs.mobile.tv.TvBrand.LG)
                ?: tvApps.bundledVersion(applicationContext, com.couchsubs.mobile.tv.TvBrand.LG)
        }.getOrNull()
        subtitleServer.sendsToTv = settings.target.showsOnTv
        subtitleServer.speakerColors = settings.speakerColors
        subtitleServer.setApart = settings.setTextApart
        // Konuşan renkleri oturum boyunca sabittir; yeni oturum yeni defterle başlar.
        com.couchsubs.mobile.core.SpeakerColors.session.reset()
        // TV alındı göndermeyi bıraktı (uygulama arka planda askıda, bağlantı yarı açık): "yeniden bağlanılıyor" gösterilir ve
        // TV bekçisi beklemeden uygulamayı yeniden açar ("Otomatik açmayı dene" ile aynı yol; LG bekçisi uygulama öne gelince
        // geri çekilmeyi de bırakır, Android TV bekçisi açma sınırını sıfırlar).
        // #1055: TV'nin başka bağlantısı açıksa bekçiye dokunulmaz (sunucu da yalnız TV'den bağlantı kalmayınca çağırır).
        subtitleServer.onTvStale = stale@{
            if (subtitleServer.connectedClients > 0) return@stale
            Log.i(TAG, "TV alındı göndermedi: bağlantı kopmuş sayıldı, yeniden bağlanılıyor")
            com.couchsubs.mobile.tv.TvOpenRetry.request()
            markTvReconnecting()
            // #1303: uygulama arka plandaysa "CouchSubs'ı açık tutun" (iPhone ile aynı).
            TvAwayAlert.lost(this, "alındı gelmedi")
        }
        subtitleServer.onClientsChanged = { count ->
            val before = LiveState.status.value.connectedTvs
            LiveState.update { it.copy(connectedTvs = count, tvOpenProblem = if (count > 0) null else it.tvOpenProblem,
                tvReconnecting = if (count > 0) false else it.tvReconnecting) }
            if (count > 0) tvReconnectTimer?.cancel(false)
            else if (before > 0 && LiveState.status.value.running && settings.target.showsOnTv) {
                markTvReconnecting()
                TvAwayAlert.lost(this, "bağlantı kapandı")
            }
            if (count == 0) com.couchsubs.mobile.tv.TvAppUpdate.disconnected()
            if (before == 0 && count > 0) Telemetry.event(Telemetry.TV_CONNECTED, "count" to count)
            // TV uygulaması bağlandı: bu Samsung TV'de kurulu olduğu artık biliniyor (liste "yok" demiş olsa da).
            if (count > 0) settings.installedTv?.takeIf { it.brand == com.couchsubs.mobile.tv.TvBrand.SAMSUNG }
                ?.let {
                    if (settings.samsungAppSeenHost != it.host) settings.samsungAppSeenHost = it.host
                    com.couchsubs.mobile.tv.TvSessionLauncher.samsungAppConnected(it.host)
                }
        }
        subtitleServer.onEvent = { event ->
            LiveState.update { it.phoneEvent(event) }
        }
        // Çeviri sürerken Ayarlar'da yazı boyu ya da rengi değişirse TV hemen yeni görünüme geçer (iPhone ile aynı).
        styleListener = settings.onStyleChanged { server?.sendStyle(settings.style) }
        // Çeviri sürerken hedef TV'ye (ya da telefona) çevrilirse altyazı hemen oraya gider (iPhone ile aynı).
        targetListener = settings.onTargetChanged { server?.sendsToTv = settings.target.showsOnTv }
        // Xbox sesi çeviri sürerken hemen değişir; Xbox'a yeni oturum açılmaz (#871, iPhone/Mac/Windows ile aynı).
        xboxAudioListener = settings.onXboxAudioChanged { session?.setPlayAudio(settings.xboxAudioOnDevice) }
        region = settings.region
        extraAreas = settings.extraAreas.watched(settings.areaPreset)
        fullScreenArea = settings.areaPreset == com.couchsubs.mobile.core.AreaPreset.FULL
        refreshPresetAreas()
        areasListener = settings.onAreasChanged {
            region = settings.region
            extraAreas = settings.extraAreas.watched(settings.areaPreset)
            fullScreenArea = settings.areaPreset == com.couchsubs.mobile.core.AreaPreset.FULL
            refreshPresetAreas()
        }
        try {
            subtitlePort = subtitleServer.start()
            subtitleServer.sendStyle(settings.style)
            liveServer = subtitleServer
            launchTv(subtitleServer.accessKey)
            watchSenderAddress()
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
        // Deneme satırları paketlerde aranmaz.
        // Paketler İngilizce→Türkçedir: oyunun dili başkaysa aranmaz (Mac/iPhone ile aynı).
        var packTitles = if (!settings.packsEnabled || demo || settings.sourceLanguage != "en") null else try {
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
        reader = SubtitleReader(settings.sourceLanguage)
        // Ekranda menü varken altyazı bekletilir; menü kapanınca bekletilen konuşma satırı gönderilir (#1240).
        val held = com.couchsubs.mobile.core.MenuHeldSender(subtitleServer, { detector.menu }, { Log.i(TAG, it) })
        menuSender = held
        pipeline =SubtitlePipeline(translator, held).apply {
            // GTA 6'nın altyazısı beyazdır: telefon bulunamasa da sohbet balonları (açık zeminde koyu yazı) altyazı olmaz.
            lightInkGame = playsGta6
            // Altyazı alanında konuşan adıyla satır okundu: ekranda menü yok (#1240).
            onDialogue = { detector.noteDialogue() }
            // Altyazı alanında menünün geçmiş listesi okundu: menü sürer, listeden bekletilen satır gönderilmez.
            onList = {
                detector.noteList()
                held.forget()
            }
            echoPaused = { detector.menu }
            // Yarım ya da bozuk okuma hemen çevrilmez; aynı satırın en iyi okuması çevrilir (Windows ve iPhone ile aynı).
            holdReadings = true
            applyWaits(settings.misreadWaitMs, settings.partialWaitMs)
            echo = com.couchsubs.mobile.core.SubtitleEcho.shared
            packLookup = { text ->
                if (packTitles != null && settings.packsEnabled) {
                    library.setDisabled(settings.disabledPacks)
                    PackLookup.match(library, text)
                } else null
            }
            showSpeakerNames = { settings.showSpeakerNames }
            // Görev satırı altyazıya girmez; "auto-mission" ek alanı olarak kendi yerinde ve özgün stilinde gösterilir. Görev
            // satırı altyazı alanının içindedir: "Ekran yazılarını otomatik çevir" kapalıyken de çevrilir (yalnız açıkken
            // "Görev ve hedef yazısı" türüne bakılır). Kullanıcı bildirimi (X, beta.100–104): görev satırı altyazıdan ayrılıyor
            // ama ayar kapalı olduğu için hiç çevrilmiyordu (Windows ve Mac ile aynı).
            missionAreas = emptyList()
            onMissionChanged = { region ->
                missionAreas = if (region != null && settings.screenTextAllows(com.couchsubs.mobile.core.ScreenTextKind.MISSION))
                    listOf(com.couchsubs.mobile.core.ExtraArea(com.couchsubs.mobile.core.MissionLine.AREA_ID, "Mission", region, auto = true))
                else emptyList()
            }
            // "Tam ekran" alanda ekranın kenarındaki bildirim kartı (sağ altta mesaj önizlemesi, solda kayan bildirim) altyazıya
            // girmez; kendi yerinde ve özgün stilinde gösterilir, ekranın ortasına çizilmez (Windows ve Mac ile aynı).
            noticeAreas = emptyList()
            onNoticesChanged = { areas -> noticeAreas = areas }
            onPackMissed = { text -> linePool.offer(text) }
            // Telefon ayarı kapalıyken GTA 6 telefonunun listesi altyazı yolunda sahne yazısı sayılırsa oturumda bir kez ipucu.
            onSceneTextDropped = { reason ->
                if (synchronized(gamePhoneHint) { gamePhoneHint.observe(reason, settings.readsGamePhone, playedGame) }) {
                    Log.i(TAG, "telefon çevirisi kapalı: telefon listesi altyazı sayılmadı ($reason), ipucu gösterildi")
                    LiveState.update { it.copy(gamePhoneHint = true) }
                }
            }
            // Altyazı alanında okunup sahne yazısı sayılan bloklar nedeniyle günlüğe (GitHub #822).
            onLog = { Log.i(TAG, it) }
            // Altyazının gecikme dökümü 30 sn'de bir tek satır (kare aralığı, yazı tanıma, kararlılık, bekletme, sıra, çeviri).
            onTiming = { Log.i(TAG, it) }
            onPairShown = { pair ->
                LiveState.shown(pair, pair.packId?.let { packTitles?.get(it) ?: it })
                // Türkçe dublaj (iPhone ve masaüstüyle aynı): yeni altyazının cümleleri telefonun Türkçe sesiyle okunur.
                if (settings.dubbingEnabled) Services.dubber.apply {
                    server = this@TranslationService.server
                    onCastChanged = { json -> settings.dubbingCast = json }
                }.speak(com.couchsubs.mobile.core.SpokenLine.of(pair.source, pair.translation), settings.dubbingCast, settings.dubbingOutput)
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
        val areaReader = SubtitleReader(settings.sourceLanguage).also { regionReader = it }
        // Ön okuma, bulut kotasını tüketmemeli veya paketin son eşleşmesini (oyun tanıma) değiştirmemeli.
        val areaTranslator = engineTranslator(free.separate())
        val earlyTranslator = if (settings.engine == EngineChoice.FREE && packTitles == null) engineTranslator(free.separate()) else null
        regionWatcher = com.couchsubs.mobile.core.RegionWatcher({ crop -> areaReader.read(crop.pixels as RegionPixels) },
            areaTranslator, subtitleServer,
            prefetchWork = regionPrefetch,
            prefetchTranslator = earlyTranslator ?: areaTranslator,
            readPhone = { flat -> areaReader.read(RegionPixels(flat.nv21, flat.width, flat.height, 0L)) }).apply {
            prefetchesTranslations = earlyTranslator != null
            subtitleEcho = com.couchsubs.mobile.core.SubtitleEcho.shared
            // Aşama süreleri (okuma, çizim, telefon izleme, bütün kare kopyası) 30 sn'de bir (beta.103 yavaşlık bildirimi).
            onTiming = { Log.i(TAG, it) }
            // Ek alanda (telefon mesajı, görev, bildirim) okunup çevrilmeyen yazının nedeni altyazı günlüğüne.
            onLog = { Log.i(TAG, it) }
            // Ayarlar'daki ekran yazısı türleri (telefon, görev, yardım/eylemler, menüler, diğer).
            allows = { kind -> settings.screenTextAllows(kind) }
            menuCovers = { settings.screenTextMenuCover }
            // "GTA 6 Telefon Mesajları: Yanda Panel / Balonların Üstünde"; panelin yazısı altyazı boyutuyla (Mac ile aynı).
            phonePanel = {
                com.couchsubs.mobile.core.PhonePanelOptions(settings.phoneMessagesPanel,
                    com.couchsubs.mobile.core.ScreenPhoneCard.textScale(settings.style.fontSize))
            }
            // Altyazı okuması yavaşsa ya da uzun süredir bitmediyse ek alanlar seyrek okunur (Mac, iPhone ve Windows ile aynı).
            slowdown = {
                val since = readStartedAt
                com.couchsubs.mobile.core.ReadPressure.slowdown(lastOcrMs,
                    if (since == 0L) 0L else com.couchsubs.mobile.core.monotonicClock() - since)
            }
            // Okunup yazı bulunamayan ya da gürültü çıkan otomatik alan: bulucu o görüntüyü bir daha önermez.
            onAutoRejected = { id ->
                detector.rejected(id)
                autoAreas = detector.areas
            }
            // Menüde okunan tuş ipucu ya da görev/HUD yazısı menü bileşeni sayılmaz (#1240).
            onAutoHud = { id -> detector.markHud(id) }
            packLookup = { text ->
                if (packTitles != null && settings.packsEnabled) {
                    library.setDisabled(settings.disabledPacks)
                    PackLookup.match(library, text)
                } else null
            }
        }
        background.scheduleWithFixedDelay({ linePool.flush() }, LinePool.FLUSH_INTERVAL_MS, LinePool.FLUSH_INTERVAL_MS, TimeUnit.MILLISECONDS)
        // Ücretsiz modelin ilk indirilmesi (yaklaşık 30 MB); oyun paketleri beklemeden çalışır.
        background.execute {
            try {
                free.prepare()
            } catch (error: Exception) {
                Log.w(TAG, "ML Kit model", error)
                // Deneme modu model olmadan da hazır çeviriyle sürer; uyarı gösterilmez.
                if (!demo) {
                    val message = when (ModelDownloadRecovery.classify(error)) {
                        ModelDownloadProblem.NETWORK -> R.string.error_model_network
                        ModelDownloadProblem.STORAGE -> R.string.error_model_storage
                        ModelDownloadProblem.UNAVAILABLE -> R.string.error_model_unavailable
                        ModelDownloadProblem.TIMEOUT -> R.string.error_model_timeout
                        ModelDownloadProblem.UNKNOWN -> R.string.error_model
                    }
                    LiveState.update { it.copy(error = getString(message)) }
                }
            }
        }

        val onFrame: (com.couchsubs.mobile.remoteplay.VideoFrame) -> Unit = { frame ->
            val now = System.currentTimeMillis()
            if (screenRequested.compareAndSet(true, false)) startScreen(frame)
            else if (screenRefreshRequested.compareAndSet(true, false)) startScreen(frame, refresh = true)
            else followTick(frame, now)
            // Çevirisi gösterilen ekran yazıları hâlâ yerinde mi: özgün yazı kalkınca çevirisi de bu karede kalkar
            // (ScreenPresence; Mac/iPhone/Windows aynı). Parlaklık karenin Y düzleminden okunur.
            server?.let { live ->
                val buffer = frame.buffer
                val limit = buffer.capacity()
                live.observe { box ->
                    com.couchsubs.mobile.core.ScreenPresence.patch(box, frame.width, frame.height) { x, y ->
                        val index = y * frame.rowStride + x
                        if (index < limit) buffer.get(index).toInt() and 0xFF else 0
                    }
                }
            }
            // Menü açıkken (tekerlek, duraklatma menüsü) altyazı okunur ama gönderilmez, bekletilir: menünün alt ortadaki
            // etiketleri altyazı olarak gösterilmesin; menü kapanınca bekletilen konuşma satırı gönderilir (MenuHeldSender,
            // #1240). Eskiden menüde altyazı hiç okunmuyordu; menü sanılan anlarda konuşma satırları kayboluyordu.
            // Menüdeki kareler sessizlik özetinde sayılır (bkz. SubtitlePipeline.skipForMenu).
            if (menuSender?.poll() == true) pipeline?.skipForMenu()
            if (!reading.get() && now - lastRead >= 1000 / MAX_READS_PER_SECOND) {
                val area = region
                // Karenin geldiği an: gecikme buradan TV'ye gidene kadar ölçülür (hattın saatiyle).
                val capturedAt = com.couchsubs.mobile.core.monotonicClock()
                // Karede GTA 6 telefonu açıksa ekranındaki satırlar altyazı değildir; telefon seyrek aranır, bulunan yer
                // sonraki okumalara da geçerlidir (Mac, Windows: SubtitlePipeline.findsPhone). Yalnız GTA 6'da: başka oyunda
                // (ya da karanlık sahnede) yanlış bulunan telefon alt şeritteki altyazıyı silmesin. Telefon ayarı kapalıyken de
                // aranır (#1282; yalnız bulmak için, okunmaz, çevrilmez): telefonun mesaj listesi altyazı olarak çevrilip gidip
                // geliyordu; bulunan telefonun satırları altyazı sayılmaz, telefon art arda bulunursa oturumda bir kez ipucu.
                // Açık telefon tek ıskada bırakılmaz ve son yerinde gevşek doğrulanır (SubtitlePipeline.heldPhone).
                if (!playsGta6) {
                    subtitlePhone = null
                    subtitlePhoneMisses = 0
                    subtitlePhoneCandidate = null
                } else if (now - subtitlePhoneAt >= com.couchsubs.mobile.core.GamePhoneTracker.INTERVAL_MS || now < subtitlePhoneAt) {
                    subtitlePhoneAt = now
                    // Doğrulanmamış adayın yerinde de gevşek doğrulama denenir (#1251).
                    val near = subtitlePhone ?: subtitlePhoneCandidate
                    val started = System.nanoTime()
                    val looked = try {
                        com.couchsubs.mobile.core.ScreenPhoneCard.search(com.couchsubs.mobile.ocr.LivePhoneImage(frame), near)
                    } catch (error: Exception) {
                        null
                    }
                    regionWatcher?.timing?.add(com.couchsubs.mobile.core.RegionWatcher.STAGE_TRACK, System.nanoTime() - started)
                    val (next, misses) = com.couchsubs.mobile.core.SubtitlePipeline.heldPhone(looked?.phone, subtitlePhone, subtitlePhoneMisses)
                    subtitlePhone = next
                    subtitlePhoneMisses = misses
                    val (candidate, since) = com.couchsubs.mobile.core.SubtitlePipeline.candidate(
                        if (next == null) looked?.candidate else null, subtitlePhoneCandidate, subtitlePhoneCandidateSince, now)
                    subtitlePhoneCandidate = candidate
                    subtitlePhoneCandidateSince = since
                    val found = subtitlePhone != null
                    if (synchronized(gamePhoneHint) { gamePhoneHint.observePhone(found, settings.readsGamePhone, playedGame) }) {
                        Log.i(TAG, "telefon ipucu: telefon çevirisi kapalı, GTA 6 telefonu ekranda bulundu")
                        LiveState.update { it.copy(gamePhoneHint = true) }
                    }
                }
                // Telefon doğrulanmadıysa doğrulanmayı bekleyen adayın ekranındaki satırlar kısa süre bekletilir.
                val unconfirmed = subtitlePhone == null && playsGta6 && com.couchsubs.mobile.core.SubtitlePipeline.holdsCandidate(
                    subtitlePhoneCandidate, subtitlePhoneCandidateSince, now)
                val phone = subtitlePhone ?: if (unconfirmed) subtitlePhoneCandidate else null
                SubtitleReader.copyRegion(frame, area)?.let { pixels ->
                    lastRead = now
                    reading.set(true)
                    ocr.execute { read(pixels, area, capturedAt, phone, unconfirmed) }
                }
            }
            offerGamePhone(frame)
            offerScreenText(frame)
            // Ek alanlar saniyede bir, kendi iş parçacığında okunur; altyazı okumasını beklemez, onu bekletmez.
            // Oyun telefonu açıkken telefonun yazıları telefon okuyucusundadır; kenar bildirimi sayılmaz (telefon çevirisi
            // kapalıyken de: görünen telefon, [phoneSeen]).
            val notices = if (phoneOpen || phoneSeen) emptyList() else noticeAreas
            // Bütün kare, ekran yazısının çizim kipi ve yanına yazmanın boş alanı onda ölçülsün diye (#1339) yalnız turda
            // okunacak alan varsa ve turda bir kez kopyalanır; arabelleği turlar arasında yeniden kullanılır (beta.103'te her
            // turda yeni ~4 MB kopya alınıyordu).
            var screenTaken: RegionPixels? = null
            val screenText = com.couchsubs.mobile.core.ScreenTextDetector.outsidePhone(autoAreas, if (phoneSeen) phoneBounds else null)
            regionWatcher?.offer(extraAreas + presetAreas + missionAreas + notices + screenText, crop = { r ->
                SubtitleReader.copyRegion(frame, r)?.let {
                    com.couchsubs.mobile.core.RegionWatcher.Crop(it, com.couchsubs.mobile.core.RegionSignature.of(it.nv21, it.width, it.height), it.gray, it.color)
                }
            }, screen = {
                SubtitleReader.copyRegion(frame, WHOLE_FRAME, screenBuffer.getAndSet(null))?.let {
                    screenTaken = it
                    com.couchsubs.mobile.core.RegionWatcher.Screen(it.gray, it.color)
                }
            }, run = { task ->
                val used = screenTaken
                regionWork.execute {
                    try {
                        task.run()
                    } finally {
                        if (used != null) screenBuffer.set(used)
                    }
                }
            })
            FramePreview.offer(frame, now)
        }
        val onState: (SessionState) -> Unit = { state ->
            val wasStreaming = streaming
            streaming = state == SessionState.Streaming
            // "PS5 bağlantısı koptuğunda bildir" (iPhone ile aynı): uygulama ekranda değilken akış koparsa bildirim.
            if (streaming) ConnectionAlert.cancel(this)
            else if (ConnectionAlert.shouldPost(wasStreaming, (state as? SessionState.Disconnected)?.kind, demo,
                    settings.notifyDisconnect, ConnectionAlert.appVisible())) ConnectionAlert.post(this)
            if (!streaming) {
                PlayedGame.consoleReported(null)
                resetGamePhone()
                regionWatcher?.reset()
                resetScreenText()
            }
            // Bağlantı koptuysa (görüntü bekçisi dahil) TV'de eski altyazı kalmasın (iPhone, Mac ve Windows'taki gibi).
            if (state is SessionState.Disconnected) {
                pipeline?.reset()
                server?.clear()
            }
            val now = System.currentTimeMillis()
            val gaveUp = synchronized(reconnectOffer) {
                reconnectOffer.update(state == SessionState.Streaming, now)
                session?.hasGivenUp == true
            }
            connectingHandler.post { connectingChanged(state) }
            LiveState.update {
                it.withStreaming(state == SessionState.Streaming)
                    .copy(phase = describe(state), notLiveSince = reconnectOffer.notLiveSince, gaveUp = gaveUp)
            }
        }
        // Oynanan oyun (PS5'in bildirdiği, kullanıcının seçtiği ya da paketten tanınan; bkz. PlayedGame): havuza giden
        // satırlar bu oyunla gider. Klipte oyun aranmaz, sorulmaz.
        if (replacement == null) {
            PlayedGame.packTitles = { packTitles?.filterKeys { it != GameSense.GENERAL_PACK }?.values?.toList() ?: emptyList() }
            // Elle seçilen oyunda satırlar yalnız o oyunun paketinde aranır, paketi yoksa hiç aranmaz (#218).
            PlayedGame.packs = library
            PlayedGame.onChange = { game ->
                resetGamePhone()
                regionWatcher?.reset()
                playedGame = game?.name
                playsGta6 = game?.name?.let { com.couchsubs.mobile.core.GameName.key(it) == "gta 6" } == true
                pipeline?.lightInkGame = playsGta6
                refreshPresetAreas()
                resetScreenText()
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
            // Xbox çalışan oyunu bildirmez: Xbox için son seçilen oyun kendiliğinden kullanılır; yoksa Oyun satırı vurgulanır
            // ve günlükte tek satır (Windows, Mac, iPhone ile aynı).
            PlayedGame.log = { Log.i(TAG, it) }
            PlayedGame.start(xboxConsole?.name?.ifEmpty { "Xbox" } ?: console!!.name.ifEmpty { console.host }, settings, startedAt,
                xbox = xboxConsole != null)
            // Oyun iki dakikada tanınmazsa kart açılır (ayar ve ortak havuz açıksa, oturumda bir kez).
            background.scheduleWithFixedDelay({ PlayedGame.checkAsk(System.currentTimeMillis()) }, 15, 15, TimeUnit.SECONDS)
            // Bağlıyken iki dakikada bir PS5'e çalışan oyun sorulur (Xbox'ta bu soru yok; oyun paketten tanınır).
            if (xboxConsole == null) background.scheduleWithFixedDelay({
                try {
                    // Her yoklamada güncel kayıt kullanılır (oturum PS5'i yeni adreste bulmuş olabilir); yanıt yoksa PS5 ağda
                    // kimliğiyle aranır ve kayıt güncellenir.
                    if (streaming) {
                        val finder = ConsoleFinder(settings.console ?: console!!).also { it.onChange = { moved -> settings.console = moved } }
                        PlayedGame.consoleReported(ConsoleDiscovery.runningGame(finder))
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "running game", error)
                }
            }, GAME_PROBE_MS / 4, GAME_PROBE_MS, TimeUnit.MILLISECONDS)
        } else {
            // Klipte oyun seçimi geçmez: önceki oturumun seçimi paket aramasını sınırlamasın.
            PlayedGame.packs = null
            library.limitToGame(null)
        }
        val makeSource: () -> FrameSource = {
            // Yeniden bağlanırken kapatılan eski oturumun geç gelen durumu yeni oturumun durumunu ezmez.
            val generation = ++sourceGeneration
            val stateOf: (SessionState) -> Unit = { state -> if (generation == sourceGeneration) onState(state) }
            replacement?.create(this, onFrame, stateOf)
                ?: xboxConsole?.let { XboxStreamSession(this, Services.xboxAuth, it, onFrame, stateOf, ::describeXbox,
                    playAudio = settings.xboxAudioOnDevice) }
                ?: StreamSession(settings.console ?: console!!, accountId!!, onFrame, stateOf,
                    onConsoleMoved = { moved -> settings.console = moved }, loginPasscode = settings.loginPasscode)
        }
        sourceFactory = makeSource
        val source = makeSource()
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
        markReconnectStart()
        background.scheduleWithFixedDelay({
            // Kare sayacıyla "oyunun kendi altyazısını açın" ipucu da güncellenir (SubtitleOffTip; GitHub #503, #566).
            session?.let { s -> LiveState.update { it.withFrames(s.framesReceived, System.currentTimeMillis()) } }
        }, 2, 2, TimeUnit.SECONDS)
        background.scheduleWithFixedDelay({ writeHealth() }, SessionHealth.INTERVAL_MS, SessionHealth.INTERVAL_MS, TimeUnit.MILLISECONDS)
    }

    // --- Uzun oturum tanısı ---

    /** Bu oturumda sistemin gönderdiği bellek uyarıları (onTrimMemory/onLowMemory). */
    @Volatile private var memoryWarnings = 0

    /**
     * Telefon uygulaması uzun oyunda (40-45 dk) kendiliğinden kapanıyordu, iz kalmıyordu. On dakikada bir (ve bellek
     * uyarısında) bellek, ısı ve süre Crashlytics izine yazılır ve saklanır; süreç ölürse sonraki açılışta kapanış
     * nedeniyle birlikte raporlanır (iPhone ile aynı).
     */
    private fun writeHealth(note: String? = null) {
        if (startedAt <= 0 || destroyed) return
        try {
            val memory = android.app.ActivityManager.MemoryInfo()
            getSystemService(android.app.ActivityManager::class.java).getMemoryInfo(memory)
            val thermal = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                SessionHealth.thermalLevel(getSystemService(PowerManager::class.java).currentThermalStatus) else 0
            val runtime = Runtime.getRuntime()
            val line = SessionHealth.line((System.currentTimeMillis() - startedAt) / 60_000, android.os.Debug.getPss() / 1024,
                memory.availMem / 1_048_576, memoryWarnings, thermal) +
                "; java ${(runtime.totalMemory() - runtime.freeMemory()) / 1_048_576}/${runtime.maxMemory() / 1_048_576} MB" +
                "; yerel ${android.os.Debug.getNativeHeapAllocatedSize() / 1_048_576} MB"
            val text = note?.let { "$it; $line" } ?: line
            Backend.breadcrumb("sağlık: $text")
            settings.lastHealth = text
        } catch (error: RuntimeException) {
            Log.w(TAG, "health", error)
        }
    }

    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // Ön plan hizmeti için RUNNING_LOW ve üstü: sistemin belleği azalıyor (arka plan uygulamaları kapatılıyor).
        if (level >= TRIM_MEMORY_RUNNING_LOW && level < TRIM_MEMORY_UI_HIDDEN || level >= TRIM_MEMORY_COMPLETE) {
            memoryWarnings++
            // Hizmet kapanırken zamanlayıcı durmuş olabilir.
            runCatching { background.execute { writeHealth("Android bellek uyarısı ($level)") } }
        }
    }

    override fun onLowMemory() {
        super.onLowMemory()
        memoryWarnings++
        runCatching { background.execute { writeHealth("Android bellek az") } }
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

    /**
     * Çeviri sürerken ya da sonuçlar ekrandayken basmak ("Çevirileri kaldır") çeviriyi hemen kapatır: kare yeniden
     * okunmaz, önbellekten yeniden çizilmez (iPhone ile aynı). Önceden sonuçlar ekrandayken basınca kare yine okunuyor,
     * oyunda yazılar biraz değişince ekran baştan çevriliyordu: "kapat"a basınca kapanmıyor, yazılar üst üste
     * biniyordu (#1182). Telefonda başka sohbete geçince kart kendiliğinden yenilenir ([followTick]).
     */
    private fun toggleScreen() {
        val server = server ?: return
        if (LiveState.status.value.screenState != LiveStatus.ScreenState.IDLE) {
            hideScreen()
            return
        }
        if (!streaming) {
            server.sendSubtitle(getString(R.string.screen_no_picture), 4000)
            return
        }
        // Düğmeye basıldı: süren telefon izlemesi bırakılır; yeni çeviri telefonu yeniden izlemeye başlar.
        screenFollow = null
        screenRefreshRequested.set(false)
        // Yeni kuşak: önceki sonuçların süresi dolup yeni okumayı kesmez.
        screenGeneration.incrementAndGet()
        LiveState.update { it.copy(screenState = LiveStatus.ScreenState.WORKING) }
        server.sendStyle(settings.style)
        server.sendSubtitle(getString(R.string.screen_translating), 2500)
        screenRequested.set(true)
    }

    /** Ekrandaki son sonuçlar ve kalkacakları an (ms): telefon kartı izlenirken süre bunlarla uzatılır. */
    @Volatile private var screenShown: List<ScreenTranslation.Item> = emptyList()
    @Volatile private var screenShownUntil = 0L
    /** Telefon kartı ekrandayken sohbeti izleyen yoklama ([ScreenPhoneFollow]); kart yoksa null. */
    @Volatile private var screenFollow: ScreenPhoneFollow? = null
    @Volatile private var lastFollowCheck = 0L
    private val followBusy = AtomicBoolean(false)
    /** İzleme telefonun değişip durulduğunu gördü: sıradaki kare sessizce yeniden çevrilsin. */
    private val screenRefreshRequested = AtomicBoolean(false)
    /** "Ekranı çevir" çevirilerinin hafızası (telefon mesajları sohbet başlığıyla); dil ya da motor değişince yenilenir. */
    @Volatile private var screenMemory = PhoneChatMemory()
    @Volatile private var screenMemoryKey = ""

    /** Sonuçlar gönderildi: kalkacakları an ve süre dolunca (bu kuşakta uzatılmadıysa) kaldırılmaları. */
    private fun scheduleScreenExpiry(items: List<ScreenTranslation.Item>, milliseconds: Int, generation: Int) {
        screenShown = items
        screenShownUntil = System.currentTimeMillis() + milliseconds
        screenExpiry.schedule({
            if (screenGeneration.get() == generation && System.currentTimeMillis() >= screenShownUntil - 100) hideScreen()
        }, milliseconds.toLong(), TimeUnit.MILLISECONDS)
    }

    /**
     * Telefon kartı ekrandayken her [ScreenPhoneFollow.INTERVAL_MS]'de bir telefon yoklanır (Mac/iPhone ve Windows ile
     * aynı): sohbet değişip durulunca ekran sessizce yeniden çevrilir (hafızadaki mesajlar hemen gelir), telefon aynıyken kartın süresi
     * uzar, telefon kapanınca kart kalkar. Önceden kart tek karenin çevirisiydi: başka sohbete geçince eskisi kalıyor,
     * süresi dolunca kayboluyordu.
     */
    private fun followTick(frame: com.couchsubs.mobile.remoteplay.VideoFrame, now: Long) {
        val follow = screenFollow ?: return
        if (now - lastFollowCheck < ScreenPhoneFollow.INTERVAL_MS) return
        if (LiveState.status.value.screenState != LiveStatus.ScreenState.SHOWN || screenRequested.get()) return
        if (!followBusy.compareAndSet(false, true)) return
        lastFollowCheck = now
        val pixels = SubtitleReader.copyRegion(frame, CropRegion(0.0, 1.0, 0.0, 1.0))
        if (pixels == null) {
            followBusy.set(false)
            return
        }
        val generation = screenGeneration.get()
        try {
            screenWork.execute {
                try {
                    val look = ScreenPhoneFollow.look(CopiedPhoneImage(pixels.width, pixels.height, pixels))
                    if (screenFollow === follow && screenGeneration.get() == generation) {
                        when (follow.step(look?.first, look?.second)) {
                            ScreenPhoneFollow.Step.WAIT -> Unit
                            ScreenPhoneFollow.Step.KEEP -> keepScreen(generation)
                            ScreenPhoneFollow.Step.REFRESH -> screenRefreshRequested.set(true)
                            ScreenPhoneFollow.Step.STOP -> hideScreen()
                            ScreenPhoneFollow.Step.HIDE -> hidePhoneBubbles(generation)
                        }
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "screen follow", error)
                } finally {
                    followBusy.set(false)
                }
            }
        } catch (error: java.util.concurrent.RejectedExecutionException) {
            followBusy.set(false)
        }
    }

    /**
     * Telefonun ekranı değişti (sohbet kaydı/değişti): balonların üstündeki çeviriler hemen kalkar, telefon dışındaki
     * çeviriler kalır; ekran durulunca yeniden çevrilir (Mac ile aynı).
     */
    private fun hidePhoneBubbles(generation: Int) {
        val items = screenShown
        val kept = items.filter { !it.bubble }
        if (kept.size == items.size) return
        screenShown = kept
        if (kept.isEmpty()) {
            server?.clearScreen()
            return
        }
        val milliseconds = ScreenTranslation.displayMilliseconds(kept)
        server?.sendScreen(kept, milliseconds)
        scheduleScreenExpiry(kept, milliseconds, generation)
    }

    /** Telefon kartı izlenirken telefon aynı: sonuçlar süresi dolmak üzereyse yeniden gönderilip uzatılır. */
    private fun keepScreen(generation: Int) {
        val items = screenShown
        if (items.isEmpty() || screenShownUntil - System.currentTimeMillis() >= 5000) return
        val milliseconds = ScreenTranslation.displayMilliseconds(items)
        server?.sendScreen(items, milliseconds)
        scheduleScreenExpiry(items, milliseconds, generation)
    }

    /** Ekran bu kareyle çevrildi: karede telefon varsa kart ekrandayken telefon izlenir ([followTick]). */
    private fun followPhone(pixels: com.couchsubs.mobile.ocr.RegionPixels, generation: Int) {
        if (screenGeneration.get() != generation) return
        val look = ScreenPhoneFollow.look(CopiedPhoneImage(pixels.width, pixels.height, pixels))
        if (look == null) {
            screenFollow = null
            return
        }
        // Çeviriler balonların üstündeyken (kartsız) sohbet durulmadan değişmeyi sürdürürse kalkar (ScreenPhoneFollow.Step.HIDE).
        val follow = screenFollow ?: ScreenPhoneFollow(hidesOnChange = !settings.phoneMessagesPanel)
        follow.settled(look.first, look.second)
        screenFollow = follow
    }

    /** Çeviriyi durdurur, sonuçları telefondan ve TV'den kaldırır. */
    private fun hideScreen() {
        screenGeneration.incrementAndGet()
        screenRequested.set(false)
        screenRefreshRequested.set(false)
        screenFollow = null
        screenShown = emptyList()
        screenShownUntil = 0L
        screenTask?.cancel(true)
        screenTask = null
        server?.clearScreen()
        server?.clear()
        LiveState.update { it.copy(screen = emptyList(), screenState = LiveStatus.ScreenState.IDLE) }
    }

    /**
     * Sıradaki kare geldi: bütün kare kopyalanır, okuma ve çeviri kendi iş parçacığında sürer. [refresh]: telefon
     * izlemesinin yenilemesi (düğmeye basılmadı): "çevriliyor" yazısı çıkmaz, aynı sonuçlar yeniden gönderilmez, hata
     * olursa eski kart kalır.
     */
    private fun startScreen(frame: com.couchsubs.mobile.remoteplay.VideoFrame, refresh: Boolean = false) {
        val pixels = SubtitleReader.copyRegion(frame, CropRegion(0.0, 1.0, 0.0, 1.0))
        val generation = screenGeneration.get()
        if (pixels == null) {
            if (!refresh) failScreen(generation, getString(R.string.screen_no_picture))
            return
        }
        val free = freeTranslator
        val server = server
        if (free == null || server == null) {
            if (!refresh) failScreen(generation, getString(R.string.error_translation))
            return
        }
        val memoryKey = "${settings.target}|${settings.engine}|${settings.localAiServer?.engineId}"
        if (memoryKey != screenMemoryKey) {
            screenMemoryKey = memoryKey
            screenMemory = PhoneChatMemory()
        }
        val memory = screenMemory
        screenTask = screenWork.submit(Runnable {
            try {
                val reader = screenReader ?: SubtitleReader(settings.sourceLanguage).also { screenReader = it }
                val read = reader.read(pixels)
                // Altyazı zaten kendi yerinde çevriliyor: ekran çevirisinde ikinci kez çizilmez (bkz. SubtitleEcho).
                val echo = com.couchsubs.mobile.core.SubtitleEcho.shared
                val reading = echo.filter(read, geometry = echo.hasRecent)
                // Yapay zekâda ekranın bütün yazıları tek istekte gider (bkz. AiTranslator.translateAll).
                val translator = engineTranslator(free.separate())
                // Yazıların içindeki kumanda simgeleri okunan kareden kesilir (ButtonIcons). Çeviriler özgün yazının
                // stilinde kendi yerlerine çizilir; GTA 6 telefonunun yazıları yanında mesaj kartında (ScreenPhoneCard).
                val phone = com.couchsubs.mobile.core.ScreenPhoneCard.phone(
                    CopiedPhoneImage(pixels.width, pixels.height, pixels))
                val items = ScreenTranslation.translate(reading, translator, { screenGeneration.get() != generation }, pixels.gray,
                    pixels.color, phone, memory, settings.phoneMessagesPanel,
                    com.couchsubs.mobile.core.ScreenPhoneCard.textScale(settings.style.fontSize)) { shown ->
                    if (screenGeneration.get() != generation) return@translate
                    // İzlemenin yenilemesinde aynı çeviriler yeniden gönderilmez (TV'de kart yeniden çizilmesin).
                    if (refresh && shown == screenShown) return@translate
                    val milliseconds = ScreenTranslation.displayMilliseconds(shown)
                    server.sendScreen(shown, milliseconds)
                    scheduleScreenExpiry(shown, milliseconds, generation)
                }
                if (screenGeneration.get() != generation) return@Runnable
                if (!refresh) server.clear()
                if (items.isEmpty()) {
                    // Yeni karede yazı yok: önceki ekranın sonuçları da kalkar.
                    if (refresh) hideScreen()
                    LiveState.update { it.copy(screenState = LiveStatus.ScreenState.IDLE) }
                    if (!refresh) server.sendSubtitle(getString(R.string.screen_none), 2500)
                } else {
                    followPhone(pixels, generation)
                }
            } catch (error: InterruptedException) {
                return@Runnable
            } catch (error: Exception) {
                Log.w(TAG, "screen", error)
                // İzlemenin yenilemesi başarısızsa eski kart kalır; aynı görüntü yeniden denenmez.
                if (refresh) followPhone(pixels, generation)
                else failScreen(generation, getString(R.string.screen_failed, getString(R.string.error_translation)))
            }
        })
    }

    private fun failScreen(generation: Int, message: String) {
        if (screenGeneration.get() != generation) return
        LiveState.update { it.copy(screenState = LiveStatus.ScreenState.IDLE) }
        server?.clear()
        server?.sendSubtitle(message, 6000)
    }

    private fun read(pixels: RegionPixels, area: CropRegion, capturedAt: Long,
                     phone: com.couchsubs.mobile.core.ScreenPhoneCard.Handset? = null, unconfirmed: Boolean = false) {
        try {
            // Bölge değişmediyse (aynı altyazı duruyor) yeniden okunmaz; son okuma hattı yine besler (kararlılık ve
            // silme saate bağlıdır, Windows'taki ReadScheduler gibi). Aynı okuma en çok 20 kare (hızlı okumada 2) kullanılır.
            val current = pipeline ?: return
            // Bekleme ayarları çeviri sürerken de değişebilir (Ayarlar'daki kaydırıcılar); her karede güncel değer uygulanır.
            current.applyWaits(settings.misreadWaitMs, settings.partialWaitMs)
            val maxReuse = if (settings.fastSubtitleDetection) FAST_MAX_REUSE else DEFAULT_MAX_REUSE
            val reused = pixels.signature == lastSignature && reusedReads < maxReuse
            reusedReads = if (reused) reusedReads + 1 else 0
            val started = com.couchsubs.mobile.core.monotonicClock()
            if (!reused) readStartedAt = started
            val result = if (reused) lastReading else reader?.read(pixels) ?: return
            val ocrMs = if (reused) lastOcrMs else (com.couchsubs.mobile.core.monotonicClock() - started).toInt()
            lastSignature = pixels.signature
            lastReading = result
            lastOcrMs = ocrMs
            current.process(result, area.box,
                com.couchsubs.mobile.core.RegionSignature.of(pixels.nv21, pixels.width, pixels.height),
                capturedAt, ocrMs, phone, reused = reused,
                darkInk = com.couchsubs.mobile.core.InkTone.sampler(pixels.gray),
                packageLook = com.couchsubs.mobile.core.PackageText.sampler(pixels.gray, pixels.color), unconfirmed = unconfirmed)
        } catch (error: java.util.concurrent.TimeoutException) {
            pipeline?.noteReadFailure(error)
            // Okuma süresinde bitmedi: takılan tanıyıcı bırakılır, sonraki kare yenisiyle okunur (yoksa yeni okuma da
            // aynı tanıyıcının arkasında beklerdi; #679).
            Log.w(TAG, "OCR: okuma süresinde bitmedi; okuyucu yeniden kuruldu", error)
            val stuck = reader
            if (stuck != null && pipeline != null) {
                reader = SubtitleReader(settings.sourceLanguage)
                runCatching { stuck.close() }
            }
        } catch (error: Exception) {
            Log.w(TAG, "OCR", error)
            pipeline?.noteReadFailure(error)
        } finally {
            readStartedAt = 0L
            reading.set(false)
        }
    }

    /** Çevrimiçi motor seçilip anahtarı girildiyse o, hatada yerel motor; yoksa null. */
    /** Seçili motor; deneme modunda motor çeviremezse örnek satırların hazır çevirisi ([DemoTranslator]). */
    private fun engineTranslator(free: TextTranslator): TextTranslator =
        (onlineTranslator(free) ?: free).let { if (demo) DemoTranslator(it) else it }

    private fun onlineTranslator(free: TextTranslator): TextTranslator? =
        onlineEngine(free)?.also { online ->
            // Motor çeviremeyince nedeni ana ekranda söylenir, düzelince kalkar (GitHub #1322; Mac/iPhone/Windows ile aynı).
            online.onFailureChanged = { state ->
                if (state != null) Log.i(TAG, "çevrimiçi motor çeviremedi: ${settings.engine} $state; yedek: ücretsiz çeviri")
                LiveState.update { it.copy(onlineIssue = state) }
            }
        }

    private fun onlineEngine(free: TextTranslator): com.couchsubs.mobile.translation.SentenceTranslator<*>? {
        // Çevrimiçi motorlar yalnız İngilizce oyunları çevirir; diğer oyun dilleri ücretsiz çeviriyle (Mac/iPhone ile aynı).
        if (settings.sourceLanguage != "en") return null
        val engine = settings.engine
        if (engine == EngineChoice.LOCAL) {
            // Yerel model: anahtar isteğe bağlıdır; adres ya da model geçersizse ücretsiz çeviri kullanılır.
            val server = settings.localAiServer ?: return null
            val model = AiModel(server.model, server.model)
            return AiTranslator(AiProvider.LOCAL, settings.apiKey(engine).orEmpty(), model, free, cache = cache(server.engineId),
                playedGame = { PlayedGame.sense.current?.name }, instruction = { settings.aiInstruction }, server = server)
        }
        val key = settings.apiKey(engine)?.takeIf { it.isNotBlank() } ?: return null
        return when (engine) {
            EngineChoice.FREE -> null
            EngineChoice.DEEPL -> DeepLTranslator(key, free, cache = cache(DeepLTranslator.ENGINE_ID), glossary = glossaryInUse,
                playedGame = { packs?.scopeTitle })
            else -> {
                val provider = when (engine) {
                    EngineChoice.GEMINI -> AiProvider.GEMINI
                    EngineChoice.OPENAI -> AiProvider.OPENAI
                    else -> AiProvider.CLAUDE
                }
                // Seçilen model (Ayarlar); dakikalık hakkı da modelin kendi sınırıdır (RequestBudget.shared).
                val model = AiModel.selected(aiModels()[provider.id].orEmpty(), settings.aiModel(provider)) ?: return null
                AiTranslator(provider, key, model, free, cache = cache(AiTranslator.engineId(provider, model)),
                    // Kararlı oyun (GameSense.current), son eşleşen paket değil: tek satır adı başka oyuna geçirmez (#27).
                    playedGame = { PlayedGame.sense.current?.name }, instruction = { settings.aiInstruction },
                    paidTier = provider == AiProvider.GEMINI && settings.geminiPaidTier)
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
        XboxError.NO_PICTURE -> R.string.xbox_error_no_picture
        XboxError.NO_FIRST_FRAME -> R.string.xbox_error_no_first_frame
        XboxError.SERVER_CLOSED -> R.string.xbox_error_server_closed
    })

    private fun describe(state: SessionState): String =
        // Xbox oturumu nedeni kullanıcının dilinde verir.
        if (state is SessionState.Disconnected && state.kind == DisconnectKind.OTHER && settings.xbox && state.detail != null) state.detail
        else describePs(state)

    /**
     * "Bağlanıyor…"un başladığı an (ms; bağlanmıyorsa 0). 30 sn geçince durum satırında nedeni söylenir
     * ([ConnectingHint]; Mac, iPhone ve Windows ile aynı); metin saniyede bir [connectingTick] ile yenilenir.
     */
    @Volatile private var connectingSince = 0L
    private val connectingHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val connectingTick = object : Runnable {
        override fun run() {
            if (connectingSince == 0L) return
            val phase = describe(SessionState.Connecting)
            LiveState.update { if (it.streaming || it.phase == phase) it else it.copy(phase = phase) }
            connectingHandler.postDelayed(this, 1000)
        }
    }

    private fun connectingChanged(state: SessionState) {
        val connecting = state == SessionState.Connecting && !settings.xbox && !demo
        if (!connecting) {
            connectingSince = 0L
            connectingHandler.removeCallbacks(connectingTick)
        } else if (connectingSince == 0L) {
            connectingSince = System.currentTimeMillis()
            connectingHandler.postDelayed(connectingTick, 1000)
        }
    }

    private fun connectingText(): String {
        val base = getString(R.string.phase_connecting)
        val since = connectingSince
        if (since == 0L) return base
        val reason = ConnectingHint.reason(System.currentTimeMillis() - since, session?.connectStep) ?: return base
        return base + "\n" + getString(when (reason) {
            ConnectStep.WAKING -> R.string.connecting_hint_waking
            ConnectStep.OPENING -> R.string.connecting_hint_opening
            ConnectStep.NO_ANSWER -> R.string.connecting_hint_no_answer
        })
    }

    private fun describePs(state: SessionState): String = when (state) {
        SessionState.Connecting -> connectingText()
        SessionState.Streaming -> getString(R.string.phase_streaming)
        is SessionState.Disconnected -> when (state.kind) {
            DisconnectKind.IN_USE -> getString(R.string.phase_in_use)
            DisconnectKind.NOT_FOUND -> state.detail?.let { getString(R.string.phase_not_found_host, it) } ?: getString(R.string.phase_not_found)
            DisconnectKind.NETWORK -> getString(R.string.phase_network)
            DisconnectKind.REGISTRATION_INVALID -> getString(R.string.phase_registration_invalid)
            // Eskiden "Bağlantı koptu, yeniden bağlanılıyor…" görünüyordu, neden anlaşılmıyordu (GitHub #33, #202).
            // 0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9); genel "başka Remote Play açık olabilir" metni yanıltıyordu.
            DisconnectKind.REJECTED -> when (state.detail) {
                DisconnectKind.REMOTE_PLAY_DISABLED -> getString(R.string.phase_remote_play_disabled, state.detail)
                null -> getString(R.string.phase_rejected)
                else -> getString(R.string.phase_rejected_code, state.detail)
            }
            DisconnectKind.NO_PICTURE -> getString(R.string.phase_no_picture)
            // Eskiden İngilizce "Remote Play on Console has crashed" ile sonsuza kadar yeniden bağlanılıyordu (GitHub #519).
            DisconnectKind.CONSOLE_RP_CRASHED -> getString(R.string.phase_console_rp_crashed)
            // PS5 akışı kendisi kapattı (ör. oyun sırasında PS5'te kullanıcı değişti): eskiden "kabloyla bağla" deniyordu.
            DisconnectKind.CONSOLE_CLOSED -> getString(R.string.phase_console_closed)
            // PS5 yeniden bağlanmadan sonra da kapattı: durulur (eskiden sınırsız deneniyor, oyun bölünüyordu; GitHub #353).
            DisconnectKind.CONSOLE_CLOSED_REPEATEDLY -> getString(R.string.phase_console_closed_repeatedly)
            DisconnectKind.RECONNECT_GAVE_UP -> getString(R.string.phase_reconnect_gave_up)
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
        wifiLocks = wifiLockModes(Build.VERSION.SDK_INT).mapNotNull { mode ->
            try {
                (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createWifiLock(mode, "CouchSubs:$mode").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (error: RuntimeException) {
                Log.w(TAG, "Wi-Fi kilidi alınamadı ($mode)", error)
                null
            }
        }
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
        EngineChoice.LOCAL -> getString(R.string.engine_local)
    }

    /** Kurulan parçaları kapatır; onDestroy'dan ve hizmet kurulum bitmeden durdurulduysa kurulum iş parçacığından çağrılır. */
    /** Yeni oturum açıldı: "Yeniden bağlan" düğmesinin süresi baştan sayılır. */
    private fun markReconnectStart() {
        val now = System.currentTimeMillis()
        synchronized(reconnectOffer) { reconnectOffer.reset(now) }
        LiveState.update { it.copy(notLiveSince = now, gaveUp = false) }
    }

    /** [reconnect]: arka plan iş parçacığında. */
    private fun reconnectSession() {
        val factory = sourceFactory ?: return
        synchronized(lifecycle) {
            if (destroyed || session == null) return
            val text = "çeviri: kullanıcı yeniden bağlandı (son durum: ${LiveState.status.value.phase})"
            Log.i(TAG, text)
            Backend.breadcrumb(text)
            session?.dispose()
            val source = factory()
            session = source
            source.start()
        }
        markReconnectStart()
        pipeline?.reset()
        server?.clear()
    }

    private fun releaseParts() = synchronized(lifecycle) {
        PlayedGame.stop()
        packs = null
        styleListener?.let(settings::removeListener)
        styleListener = null
        targetListener?.let(settings::removeListener)
        targetListener = null
        xboxAudioListener?.let(settings::removeListener)
        xboxAudioListener = null
        areasListener?.let(settings::removeListener)
        areasListener = null
        resetGamePhone()
        regionWatcher?.reset()
        regionWatcher = null
        resetScreenText()
        regionReader?.close()
        regionReader = null
        session?.dispose()
        session = null
        connectingHandler.post { connectingChanged(SessionState.Disconnected(DisconnectKind.STOPPED)) }
        sourceFactory = null
        pipeline?.reset()
        pipeline?.shutdown()
        pipeline = null
        liveServer = null
        server?.stop()
        LiveState.update { it.copy(pairing = null) }
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
        addressWatcher?.stop()
        addressWatcher = null
        Services.onLocalPacksChanged = null
        Services.dubberIfCreated?.stop()
        Services.dubberIfCreated?.server = null
        settings.translating = false
        if (startedAt > 0) settings.lastSessionMs = System.currentTimeMillis() - startedAt
        if (startedAt > 0) Telemetry.event(Telemetry.SESSION_STOP, "seconds" to (System.currentTimeMillis() - startedAt) / 1000,
            "pack_lines" to (pipeline?.packHits ?: 0), "lines" to LiveState.status.value.recent.size)
        releaseParts()
        background.shutdownNow()
        ocr.shutdownNow()
        regionWork.shutdownNow()
        detectorWork.shutdownNow()
        regionPrefetch.shutdownNow()
        screenGeneration.incrementAndGet()
        screenTask?.cancel(true)
        screenWork.shutdownNow()
        screenExpiry.shutdownNow()
        screenReader?.close()
        screenReader = null
        if (current === this) current = null
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLocks.forEach { lock -> runCatching { if (lock.isHeld) lock.release() } }
        wifiLocks = emptyList()
        tvReconnectTimer?.cancel(false)
        LiveState.update { it.copy(running = false, phase = "", streaming = false, framesSince = null, subtitleOffTip = false, tvOpenProblem = null, tvReconnecting = false, tvLostWhileAway = false, current = "", previous = "", regions = emptyList(), screen = emptyList(), screenState = LiveStatus.ScreenState.IDLE) }
        TvAwayAlert.reset(this)
        super.onDestroy()
    }
}

/**
 * Çeviri sürerken tutulan Wi-Fi kilitleri. Android 10+'da yalnız WIFI_MODE_FULL_LOW_LATENCY tutuluyordu; bu kilit yalnız
 * ekran açık ve uygulama ön plandayken etkilidir: telefon kilitlenince hiçbir kilit kalmıyor, Wi-Fi güç tasarrufuna
 * geçiyor, PS5 görüntüsü takılıp bağlantı kopabiliyordu. WifiManager belgesindeki gibi ikisi birlikte tutulur: ekran
 * açıkken düşük gecikme, kapalıyken ya da arka plandayken HIGH_PERF etkilidir. (Android 14 ve sonrası HIGH_PERF'i de düşük
 * gecikme kısıtlarıyla uygulayabilir; orada ekran kapalıyken Wi-Fi'ın uykuya geçmesini uygulama önleyemez, bkz.
 * settings_screen_on_note.)
 */
@Suppress("DEPRECATION")
internal fun wifiLockModes(sdk: Int): List<Int> =
    if (sdk >= Build.VERSION_CODES.Q) listOf(WifiManager.WIFI_MODE_FULL_HIGH_PERF, WifiManager.WIFI_MODE_FULL_LOW_LATENCY)
    else listOf(WifiManager.WIFI_MODE_FULL_HIGH_PERF)

/**
 * Bu kurulumun kalıcı kimliği (`/hello` yanıtında; Mac ve Windows'taki gibi): ilk istekte rastgele üretilir ve saklanır.
 * TV uygulaması aynı ağdaki iki CouchSubs'tan kendisininkini bununla seçer (GitHub #425).
 */
private fun installationId(context: Context): String {
    val prefs = context.getSharedPreferences("server", Context.MODE_PRIVATE)
    prefs.getString("id", null)?.takeIf { it.isNotEmpty() }?.let { return it }
    val made = java.util.UUID.randomUUID().toString()
    prefs.edit().putString("id", made).apply()
    return made
}
