// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile

import android.app.Application
import android.content.Context
import android.util.Log
import com.couchsubs.mobile.account.Account
import com.couchsubs.mobile.account.Ads
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.account.ConsentChoice
import com.couchsubs.mobile.account.ConsentPolicy
import com.couchsubs.mobile.account.PackGate
import com.couchsubs.mobile.account.RemoteFlags
import com.couchsubs.mobile.account.Subscriptions
import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.packs.HttpPackServer
import com.couchsubs.mobile.packs.PackDownloadException
import com.couchsubs.mobile.packs.PackStore
import com.couchsubs.mobile.settings.AppSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.io.File

/** Uygulama açılınca: Firebase (varsa), RevenueCat (anahtar varsa), izinler ve paket yenilemesi. */
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
    private lateinit var appContext: Context
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** Paket listesi değişince (indirme, abonelik) artar; ekranlar yeniden okur. */
    val packsVersion = MutableStateFlow(0)
    private val consentState = MutableStateFlow(ConsentChoice())

    fun init(app: Application) {
        appContext = app
        settings = AppSettings(app)
        consentState.value = settings.consent
        Backend.init(app)
        Subscriptions.init(app)
        Ads.init(app)
        packStore = PackStore(File(app.filesDir, "packs-remote"), HttpPackServer(BuildConfig.PACKS_URL.trimEnd('/')),
            idToken = { runBlocking { Account.idToken() } })
        scope.launch {
            combine(consentState, RemoteFlags.adsEnabled) { choice, ads -> choice to ads }.collect { (choice, ads) ->
                val flags = ConsentPolicy.flags(choice, ads, umpCanRequestAds = !ads || Ads.umpCanRequestAds(app))
                Backend.applyConsent(flags)
                Ads.apply(flags)
            }
        }
        // Abone olunca ya da uygulama açılınca paketler (haftada bir) yenilenir.
        scope.launch { Subscriptions.access.collect { access -> if (access.active) refreshPacks(force = false) } }
    }

    fun setConsent(choice: ConsentChoice) {
        settings.consent = choice
        consentState.value = choice
    }

    /** Okuma hattının paket araması açık mı (abonelik + ayar). */
    fun packsAllowed(): Boolean = PackGate.allowed(Subscriptions.access.value, settings.packsEnabled, settings.debugFreePacks)

    fun refreshPacks(force: Boolean) {
        if (BuildConfig.PACKS_URL.isBlank()) return
        scope.launch(Dispatchers.IO) {
            try {
                val result = packStore.refresh(force)
                if (!result.skipped) packsVersion.value++
            } catch (error: PackDownloadException) {
                Log.w(TAG, "paketler: ${error.status} ${error.message}")
                if (error.status == 403) packsVersion.value++
            } catch (error: Exception) {
                Log.w(TAG, "paketler", error)
            }
        }
    }

    /**
     * Okuma hattının paket kitaplığı: sunucudan inmiş paketler; hata ayıklama derlemesinde ayrıca APK'daki paketler
     * (sunucusuz deneme için). Mağaza derlemesinde APK'da paket yoktur.
     */
    fun packLibrary(context: Context): GamePackLibrary {
        val bundled: (() -> List<Pair<String, ByteArray>>)? = if (BuildConfig.BUNDLED_PACKS) {
            { (context.assets.list("packs") ?: emptyArray()).map { it to context.assets.open("packs/$it").use { s -> s.readBytes() } } }
        } else null
        return GamePackLibrary(bundled, packStore.files().firstOrNull()?.parentFile).also { it.setDisabled(settings.disabledPacks) }
    }

    /** Paket ekranında gösterilen oyun. */
    data class CatalogEntry(val id: String, val title: String, val entries: Int, val installed: Boolean)

    /**
     * Paket kataloğu: sunucudaki liste (abone olmayan da görür) ve bu telefondaki paketler; sunucu yoksa yalnız eldekiler
     * (hata ayıklama derlemesinde APK'daki paketler). Bloklar.
     */
    fun catalog(context: Context): List<CatalogEntry> {
        val local = packLibrary(context).infos
        val remote = if (BuildConfig.PACKS_URL.isBlank()) emptyList()
        else runCatching { HttpPackServer(BuildConfig.PACKS_URL.trimEnd('/')).list() }.getOrDefault(emptyList())
        val fromServer = remote.map { pack -> CatalogEntry(pack.id, pack.title, pack.entries, local.any { it.id == pack.id }) }
        val onlyLocal = local.filter { info -> remote.none { it.id == info.id } }.map { CatalogEntry(it.id, it.title, it.entries, true) }
        return fromServer + onlyLocal
    }

    /**
     * Hesabı siler: Firebase kullanıcısı, RevenueCat bağlantısı ve bu cihazdaki bütün veriler (ayarlar, şifreli
     * anahtarlar, PS5 kaydı, paketler, havuz kuyruğu, önbellek). Abonelik Google Play'de ayrıca iptal edilmelidir.
     */
    suspend fun deleteAccount(password: String?) {
        Account.deleteUser(password)
        Account.signOut()
        wipeLocalData()
    }

    fun wipeLocalData() {
        packStore.clear()
        settings.clearAll()
        consentState.value = ConsentChoice()
        appContext.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        appContext.cacheDir.listFiles()?.forEach { it.deleteRecursively() }
        packsVersion.value++
    }
}
