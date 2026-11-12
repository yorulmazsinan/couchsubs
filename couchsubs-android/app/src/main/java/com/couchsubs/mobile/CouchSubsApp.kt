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

/** Uygulama açılınca: Firebase ve Meta (varsa) ve paket yenilemesi. Hesap ve reklam yok; uygulama ve paketler ücretsiz. */
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
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** Paket listesi değişince (indirme) artar; ekranlar yeniden okur. */
    val packsVersion = MutableStateFlow(0)

    fun init(app: Application) {
        settings = AppSettings(app)
        Backend.init(app)
        Meta.init(app)
        applyMeasurement()
        packStore = PackStore(File(app.filesDir, "packs-remote"), HttpPackServer(BuildConfig.PACKS_URL.trimEnd('/')))
        // Açılışta (haftada bir) yeni ve güncellenen paketlere bakılır.
        refreshPacks(force = false)
    }

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

    fun refreshPacks(force: Boolean) {
        if (BuildConfig.PACKS_URL.isBlank()) return
        scope.launch(Dispatchers.IO) {
            try {
                val result = packStore.refresh(force)
                if (!result.skipped) packsVersion.value++
            } catch (error: Exception) {
                Log.w(TAG, "paketler", error)
            }
        }
    }

    /** Paket ekranında gösterilen oyun; [installed] false ise sunucuda var ama henüz inmedi. */
    data class CatalogEntry(val id: String, val title: String, val entries: Int, val installed: Boolean)

    /** Bu telefondaki paketler ve sunucuda olup henüz inmemiş olanlar (bloklar). */
    fun catalog(context: Context): List<CatalogEntry> {
        val local = packLibrary(context).infos
        val remote = if (BuildConfig.PACKS_URL.isBlank()) emptyList()
        else runCatching { HttpPackServer(BuildConfig.PACKS_URL.trimEnd('/')).list() }.getOrDefault(emptyList())
        return local.map { CatalogEntry(it.id, it.title, it.entries, true) } +
            remote.filter { pack -> local.none { it.id == pack.id } }.map { CatalogEntry(it.id, it.title, it.entries, false) }
    }

    /**
     * Okuma hattının paket kitaplığı: uygulamayla gelen paketler, üstüne sunucudan inmiş yeni ya da güncel sürümler
     * (aynı kimlikte indirilen kazanır).
     */
    fun packLibrary(context: Context): GamePackLibrary {
        val bundled: () -> List<Pair<String, ByteArray>> = {
            (context.assets.list("packs") ?: emptyArray()).map { it to context.assets.open("packs/$it").use { s -> s.readBytes() } }
        }
        return GamePackLibrary(bundled, packStore.files().firstOrNull()?.parentFile).also { it.setDisabled(settings.disabledPacks) }
    }
}
