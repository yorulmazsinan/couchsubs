// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile

import android.app.Application
import android.content.Context
import android.util.Log
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.account.MeasurementPolicy
import com.couchsubs.mobile.account.Meta
import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.packs.HttpPackServer
import com.couchsubs.mobile.packs.PackStore
import com.couchsubs.mobile.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File

/** Uygulama açılınca: Firebase ve Meta (varsa) ve paket yenilemesi. Hesap ve reklam SDK'sı yok (yalnız kendi ürünlerimizin tanıtımı, bkz. promo); uygulama ve paketler ücretsiz. */
class CouchSubsApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Services.init(this)
    }
}

/** Uygulama genelindeki hizmetler. */
object Services {
    private const val TAG = "CouchSubsServices"
    lateinit var settings: AppSettings
        private set
    lateinit var packStore: PackStore
        private set
    /** Paket sunucusu: workers.dev, ulaşılamazsa yedek adres (couchsubs-packs.enmeraapps.com); çalışan adres hatırlanır. */
    private val packServer by lazy { HttpPackServer(listOf(BuildConfig.PACKS_URL, BuildConfig.PACKS_FALLBACK_URL)) }
    /** Ayarlar › Oyun paketleri'nden içe aktarılan topluluk paketleri (yalnız bu telefonda; sunucuya gitmez). */
    lateinit var importedPacksDirectory: File
        private set
    /** Çalışan çeviri hizmeti: paket içe aktarılınca ya da silinince kitaplığını yeniden okur. */
    @Volatile var onLocalPacksChanged: (() -> Unit)? = null
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** Paket listesi değişince (indirme) artar; ekranlar yeniden okur. */
    val packsVersion = MutableStateFlow(0)

    /** Paket güncellemesinin durumu (iPhone'daki AppModel.PackStatus): Oyun paketleri ekranı gösterir. */
    enum class PackStatus { IDLE, DOWNLOADING, READY, OFFLINE, FAILED }

    /** Son paket güncellemesinin durumu; hata sessizce yutulmaz, ekranda yazar ("Paketleri güncelle" işe yaramıyor sanılıyordu). */
    val packStatus = MutableStateFlow(PackStatus.IDLE)

    /** Ağ hatası mı (ulaşılamadı) yoksa sunucu/doğrulama hatası mı. */
    fun packStatus(error: Throwable): PackStatus =
        if (error is com.couchsubs.mobile.packs.PackDownloadException && error.status == null) PackStatus.OFFLINE else PackStatus.FAILED

    fun packStatus(result: PackStore.Refresh): PackStatus = when {
        result.failed.isEmpty() -> PackStatus.READY
        result.offline -> PackStatus.OFFLINE
        else -> PackStatus.FAILED
    }

    /** Xbox (Beta) Microsoft girişi ve jetonları: kullanıcı jetonu her yenilendiğinde Keystore'a yazılır. */
    val xboxAuth: com.couchsubs.mobile.xbox.XboxAuth by lazy {
        com.couchsubs.mobile.xbox.XboxAuth(userToken = com.couchsubs.mobile.xbox.XboxUserToken.parse(settings.xboxUserToken),
            onUserToken = { settings.xboxUserToken = it?.serialize() })
    }

    /** Bu ve önceki oturumlarda çevrilen son 200 altyazı (history.json; "Geçmiş" ekranı, iPhone ile aynı). */
    var history = com.couchsubs.mobile.core.SubtitleHistory()
        private set
    /** Geçmiş değişince artar; ekran yeniden okur. */
    val historyVersion = MutableStateFlow(0)
    private var historyFile: File? = null
    private val historyWriter = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it, "CouchSubs history").apply { isDaemon = true } }

    fun addToHistory(source: String, translation: String, origin: String) {
        history.add(source, translation, origin)
        historyChanged()
    }

    fun clearHistory() {
        history.clear()
        historyChanged()
    }

    private fun historyChanged() {
        historyVersion.value++
        val file = historyFile ?: return
        historyWriter.execute { runCatching { history.save(file) } }
    }

    fun init(app: Application) {
        historyFile = File(app.filesDir, "history.json").also { file ->
            historyWriter.execute {
                history = com.couchsubs.mobile.core.SubtitleHistory.load(file)
                historyVersion.value++
            }
        }
        settings = AppSettings(app)
        Backend.init(app)
        Meta.init(app)
        applyMeasurement()
        packStore = PackStore(File(app.filesDir, "packs-remote"), packServer, bundledHashes = { bundledPackHashes(app) })
        importedPacksDirectory = File(app.filesDir, "packs-imported")
        // Açılışta hemen, sonra uygulama açık kaldıkça günde bir yeni ve güncellenen paketlere bakılır (iPhone'daki gibi).
        refreshPacks(force = true)
        scope.launch {
            while (true) {
                kotlinx.coroutines.delay(PackStore.REFRESH_INTERVAL_MS)
                refreshPacks(force = false)
            }
        }
        reportPreviousExits(app)
    }

    /**
     * Önceki kapanış yerel çökme, bellek yetmemesi ya da ANR idiyse raporlanır (Crashlytics bunları kendisi görmez;
     * bkz. ExitReport). Süreç yeni açıldığı için çeviri hizmeti çalışmıyor: "translating" kaldıysa süreç çeviri
     * sürerken ölmüştür.
     */
    private fun reportPreviousExits(app: Application) {
        val duringTranslation = settings.translating
        val lastHealth = settings.lastHealth
        settings.translating = false
        scope.launch(Dispatchers.IO) {
            settings.lastExitReportAt = Backend.reportPreviousExits(app, settings.lastExitReportAt, duringTranslation, lastHealth)
        }
    }

    @Volatile private var bundledHashes: Map<String, String>? = null

    /** Uygulamayla gelen paketlerin SHA-256'sı (kimlik → özet); bir kez hesaplanır, sürüm içinde değişmez. */
    private fun bundledPackHashes(context: Context): Map<String, String> = bundledHashes ?: try {
        (context.assets.list("packs") ?: emptyArray()).filter { GamePackLibrary.isPackFile(it) }.associate { name ->
            GamePackLibrary.baseName(name) to PackStore.sha256(context.assets.open("packs/$name").use { it.readBytes() })
        }
    } catch (error: java.io.IOException) {
        Log.w(TAG, "uygulamayla gelen paketler okunamadı", error)
        emptyMap()
    }.also { bundledHashes = it }

    /** Profil › Kullanım verisi değişince ya da karşılama geçilince (iPhone'daki gibi). */
    fun applyMeasurement() {
        val flags = MeasurementPolicy.flags(settings.usageData, settings.welcomeSeen)
        Backend.apply(flags)
        Meta.apply(flags)
    }

    fun setUsageData(enabled: Boolean) {
        settings.usageData = enabled
        applyMeasurement()
    }

    /**
     * Paket sunucusuna bakar (son bakış [maxAgeMs]'den eskiyse; [force] ile hemen). Yeni ya da güncellenen paket inince
     * [onChanged] çağrılır (çalışan çeviri hizmeti kendi kitaplığını yeniden okur).
     */
    fun refreshPacks(force: Boolean, maxAgeMs: Long = PackStore.REFRESH_INTERVAL_MS, onChanged: (() -> Unit)? = null) {
        if (BuildConfig.PACKS_URL.isBlank()) return
        if (force) packStatus.value = PackStatus.DOWNLOADING
        scope.launch(Dispatchers.IO) {
            try {
                val result = packStore.refresh(force, maxAgeMs)
                if (result.downloaded.isNotEmpty() || result.removed.isNotEmpty()) onChanged?.invoke()
                if (!result.skipped) {
                    packStatus.value = packStatus(result)
                    if (result.failed.isNotEmpty()) Log.w(TAG, "paketler inemedi: ${result.failed}")
                    packsVersion.value++
                }
            } catch (error: Throwable) {
                // Exception değil Throwable: bellek yetmezse (OutOfMemoryError) durum "güncelleniyor"da kalıyor, düğme bir
                // daha basılamıyordu.
                Log.w(TAG, "paketler", error)
                packStatus.value = packStatus(error)
                // Ekran yeniden okusun: sunucudaki liste alınamadıysa yalnız bu telefondakiler görünür.
                packsVersion.value++
            }
        }
    }

    /** Paket ekranında gösterilen oyun; [installed] false ise sunucuda var ama henüz inmedi. */
    data class CatalogEntry(val id: String, val title: String, val entries: Int, val installed: Boolean)

    /** Bu telefondaki paketler ve sunucuda olup henüz inmemiş olanlar (bloklar). Sunucu listesi alınamazsa durum yazılır. */
    fun catalog(context: Context): List<CatalogEntry> {
        val local = packLibrary(context).infos
        val remote = if (BuildConfig.PACKS_URL.isBlank()) emptyList()
        else try {
            packServer.list()
        } catch (error: Exception) {
            Log.w(TAG, "paket listesi", error)
            if (packStatus.value != PackStatus.DOWNLOADING) packStatus.value = packStatus(error)
            emptyList()
        }
        return merge(local, remote)
    }

    /** Kurulu paketler, ardından sunucuda olup henüz inmemiş olanlar (aynı kimlik bir kez). */
    fun merge(local: List<GamePackLibrary.Info>, remote: List<com.couchsubs.mobile.packs.RemotePack>): List<CatalogEntry> =
        local.map { CatalogEntry(it.id, it.title, it.entries, true) } +
            remote.filter { pack -> local.none { it.id == pack.id } }.map { CatalogEntry(it.id, it.title, it.entries, false) }

    /**
     * Okuma hattının paket kitaplığı: uygulamayla gelen paketler, üstüne sunucudan inmiş yeni ya da güncel sürümler
     * (aynı kimlikte indirilen kazanır).
     */
    fun packLibrary(context: Context): GamePackLibrary {
        val bundled: () -> List<Pair<String, () -> ByteArray>> = {
            (context.assets.list("packs") ?: emptyArray()).map { name -> name to { context.assets.open("packs/$name").use { s -> s.readBytes() } } }
        }
        return GamePackLibrary(bundled, packStore.directory, importedPacksDirectory).also { it.setDisabled(settings.disabledPacks) }
    }

    /** İçe aktarılan bir paket (Ayarlar › Oyun paketleri'ndeki liste). */
    data class ImportedPack(val id: String, val title: String, val entries: Int, val file: File)

    /** İçe aktarılan paketler, ada göre (bloklar). */
    fun importedPacks(): List<ImportedPack> =
        importedPacksDirectory.listFiles()?.filter { it.isFile && it.name.endsWith(".json") && !it.name.startsWith(".") }?.mapNotNull { file ->
            try {
                val pack = com.couchsubs.mobile.core.GamePack.decode(file.readBytes(), GamePackLibrary.baseName(file.name))
                ImportedPack(pack.id, pack.title, pack.size, file)
            } catch (error: java.io.IOException) {
                null
            }
        }?.sortedBy { it.title.lowercase() }.orEmpty()

    /** Paket içe aktarıldı ya da silindi: ekranlar ve çalışan çeviri yeniden okur. */
    fun localPacksChanged() {
        packsVersion.value++
        onLocalPacksChanged?.invoke()
    }

    fun deleteImportedPack(pack: ImportedPack) {
        if (pack.file.parentFile == importedPacksDirectory) pack.file.delete()
        localPacksChanged()
    }
}
