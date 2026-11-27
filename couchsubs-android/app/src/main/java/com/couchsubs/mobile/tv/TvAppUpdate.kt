// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki refreshTVApp'in (mac/CouchSubs/AppModel.swift) telefon karşılığı: TV'deki CouchSubs sürümüne bakar.
// Fark: telefon güncellemeyi kendiliğinden kurmaz, ana ekranda "TV uygulamasını güncelle" önerir.
package com.couchsubs.mobile.tv

import android.content.Context
import android.util.Log
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.tv.android.AndroidTvInstaller
import com.couchsubs.mobile.tv.lg.JschShell
import com.couchsubs.mobile.tv.lg.LgInstaller
import com.couchsubs.mobile.tv.lg.LgKeys
import com.couchsubs.mobile.tv.lg.TvAppRunningCheck
import com.couchsubs.mobile.tv.samsung.AdbKey
import com.couchsubs.mobile.tv.samsung.InstallLog
import com.couchsubs.mobile.tv.samsung.SamsungCertificates
import com.couchsubs.mobile.tv.samsung.SamsungDiagnostics
import com.couchsubs.mobile.tv.samsung.SamsungInstaller
import com.couchsubs.mobile.tv.samsung.SdbConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Bu telefonun TV uygulamasını kurduğu TV. [port] yalnız Android TV'de (0: 5555). */
/** [uuid]/[mac]: TV'nin kalıcı kimliği ([FoundTv]); eski kayıtlarda yoktur, TV ilk kez ağda bulununca öğrenilir. */
data class InstalledTv(val brand: TvBrand, val host: String, val port: Int = 0, val version: String? = null,
                       val uuid: String? = null, val mac: String? = null)

sealed interface TvAppStatus {
    /** Henüz bakılmadı ya da TV'ye ulaşılamadı (geliştirici modu kapalı, TV kapalı). */
    data object Unknown : TvAppStatus
    data class UpToDate(val version: String) : TvAppStatus
    /** TV'deki sürüm telefondakinden eski: ana ekran güncellemeyi önerir. */
    data class Outdated(val tv: InstalledTv, val installed: String, val bundled: String) : TvAppStatus
    /** LG: paket güncel ama açık uygulama kapatıp açtıktan sonra da eski sürümde (beta.89): "TV'de kapatıp yeniden açın". */
    data class RunningStale(val tv: InstalledTv, val running: String, val installed: String) : TvAppStatus
}

object TvAppUpdate {
    private const val TAG = "CouchSubsTvUpdate"

    private val state = MutableStateFlow<TvAppStatus>(TvAppStatus.Unknown)
    val status: StateFlow<TvAppStatus> = state
    private val running = AtomicBoolean(false)

    /**
     * Ana ekrandaki "TV uygulamasını güncelle" düğmesi: kurulum ekranı bu TV'yi seçip kurulumu kendiliğinden başlatır.
     * Ekran okuyunca bırakılır.
     */
    @Volatile var pending: InstalledTv? = null

    fun takePending(): InstalledTv? = pending.also { pending = null }

    /** Telefondaki TV paketinin sürümü; paket yoksa null. */
    fun bundledVersion(context: Context, brand: TvBrand): String? = when (brand) {
        TvBrand.SAMSUNG -> BuildConfig.TV_SAMSUNG_VERSION
        TvBrand.LG -> TvPackages.index(context)[TvPackages.LG_IPK]?.let(LgInstaller::versionOfPackage)
        TvBrand.ANDROID_TV -> TvPackages.androidTv(context)?.second
    }

    /** Kurulum ekranı kurulumu ya da sürüm denetimini bitirdi: TV kaydedilir, öneri kalkar. */
    fun installed(tv: InstalledTv) {
        val settings = Services.settings
        settings.installedTv = tv
        // Samsung: uygulama yeni kuruldu/doğrulandı; listesiz açma hakkı yenilenir (Mac/iPhone ve Windows'ta mark ile aynı).
        if (tv.brand == TvBrand.SAMSUNG) TvSessionLauncher.samsungAppConnected(tv.host)
        // Kurulumun 3. adımından TV uygulaması kurulunca altyazı TV'ye gider ve kurulum biter; yoksa uygulama her
        // açılışta yine 3. adımdan (altyazının yeri) başlıyordu, "Devam"a basılmadıysa ana ekrana hiç gelinmiyordu (#113).
        // "İkisi de" seçiliyse korunur; yalnız "Bu telefonda" TV'ye döner.
        if (!settings.target.showsOnTv) settings.target = SubtitleTarget.TV
        settings.onboarded = true
        // LG: kurulum (ya da kapat-aç) açık uygulamayı kapatıp açtı; açılan uygulamanın bildirdiği sürüm denetlenir.
        if (tv.brand == TvBrand.LG) expectRunning(tv.version.orEmpty())
        state.value = tv.version?.takeIf { it.isNotEmpty() }?.let { TvAppStatus.UpToDate(it) } ?: TvAppStatus.Unknown
    }

    /** Eşli TV kaldırıldı: sürüm önerisi de kalkar. */
    fun forget() {
        pending = null
        state.value = TvAppStatus.Unknown
    }

    /** 0.9.69'den eski TV uygulamaları sürüm bildirmez; ekranda böyle görünür. */
    const val UNREPORTED = "< 0.9.69"

    /**
     * TV uygulaması altyazı akışına bağlanıp sürümünü bildirdi (boş: 0.9.69'den eski, sürüm bildirmeyen uygulama). LG'de
     * geliştirici modu kapalıyken ya da anahtar bu telefonda değilken [check] TV'deki sürümü okuyamıyor, TV uygulaması
     * eski kalıyor ve hiç öneri çıkmıyordu (GitHub #884, #891). Eskiyse ana ekran "TV uygulamasını güncelle" önerir.
     *
     * [host]: sürümü bildiren TV'nin adresi (bilinmiyorsa boş). Aynı ağda iki TV varken (LG ve Android TV) öbür TV'nin
     * uygulaması bağlanınca bildirdiği sürüm kayıtlı TV'ninki sanılıyor, kayıtlı TV için güncelleme öneriliyor ve kayıttaki
     * sürüm değişiyordu (X, beta.105). Öneri yalnız kayıtlı TV'yi ilgilendirir. Mac, iPhone ve Windows ile aynı.
     */
    fun reported(context: Context, version: String, host: String = "") {
        runningVersion = version
        val tv = Services.settings.installedTv ?: return
        if (!concernsInstalled(tv, host, version) { line -> InstallLog(File(context.filesDir, "tvinstall.log")).write(line) }) return
        if (tv.brand == TvBrand.LG && lgRunningReported(context, tv, version)) return
        val bundled = bundledVersion(context, tv.brand) ?: return
        state.value = decide(tv, version, bundled) ?: return
        if (version.isNotEmpty() && tv.version != version) Services.settings.installedTv = tv.copy(version = version)
    }

    /** Sürümünü bildiren son kayıtsız TV'nin adresi (aynı satır her bağlantıda yeniden yazılmasın). */
    @Volatile private var lastOtherReport: String? = null

    /** Bildirim kayıtlı TV'den mi; değilse (aynı adres için bir kez) günlüğe yazılır. */
    internal fun concernsInstalled(tv: InstalledTv, host: String, version: String, log: (String) -> Unit): Boolean {
        if (com.couchsubs.mobile.core.SubtitleServer.isFromSavedTv(host, tv.host)) return true
        if (lastOtherReport != host) log(com.couchsubs.mobile.core.SubtitleServer.otherTvReportLine(host, tv.host, version))
        lastOtherReport = host
        return false
    }

    /** Bağlı TV uygulamasının son bildirdiği sürüm (boş: eski uygulama); LG kurulum ekranı kuruluma verir. */
    @Volatile var runningVersion: String? = null

    /** TV bağlantısı kalmadı: son bildirilen sürüm unutulur. */
    fun disconnected() { runningVersion = null }

    /** LG: kurulumdan ya da kapat-aç'tan sonra çalışan uygulamanın sürümü bekleniyor (masaüstündeki runningCheck). */
    @Volatile private var lgRunningCheck: TvAppRunningCheck? = null

    /** Kurulum ya da kapat-aç bitti: açılan uygulamanın bildirdiği sürüm denetlenir. */
    fun expectRunning(version: String) {
        lgRunningCheck = version.takeIf { it.isNotEmpty() }?.let { TvAppRunningCheck(it) }
    }

    /**
     * LG, kurulumdan ya da kapat-aç'tan sonraki ilk sürüm bildirimi: çalışan uygulama kurulan sürümdeyse denetim biter;
     * eskiyse bir kez daha kapatılıp açılır, yine eskiyse ana ekran "TV'de CouchSubs'ı kapatıp yeniden açın" der (fiş
     * çekmek gerekmez). true: bildirim burada ele alındı. Mac, iPhone ve Windows ile aynı.
     */
    internal fun lgRunningReported(
        context: Context?, tv: InstalledTv, version: String,
        // Kapat-aç SSH'le birkaç saniye sürer: sunucunun iş parçacığı beklemesin. done(true): yeniden açıldı.
        restart: (String, (Boolean) -> Unit) -> Unit = { host, done ->
            Thread({ done(context != null && restartLg(context, host)) }, "CouchSubsLgRestart").start()
        },
        log: (String) -> Unit = { line -> context?.let { InstallLog(File(it.filesDir, "tvinstall.log")).write(line) } },
    ): Boolean {
        val check = lgRunningCheck ?: return false
        val shown = version.ifEmpty { UNREPORTED }
        return when (check.report(version)) {
            TvAppRunningCheck.Verdict.RUNNING -> {
                lgRunningCheck = null
                log("TV'de çalışan CouchSubs: $shown (kurulan ${check.expected}).")
                false
            }
            TvAppRunningCheck.Verdict.RESTART_AGAIN -> {
                log("TV'de çalışan CouchSubs hâlâ $shown, kurulu ${check.expected}; uygulama bir kez daha kapatılıp açılıyor.")
                // Anahtar yok ya da geliştirici modu kapalı: kapatılamadı, kullanıcıya söylenir.
                restart(tv.host) { restarted -> if (!restarted) staleRunning(tv, shown, check.expected, log) }
                true
            }
            TvAppRunningCheck.Verdict.STALE -> {
                staleRunning(tv, shown, check.expected, log)
                true
            }
        }
    }

    private fun staleRunning(tv: InstalledTv, running: String, installed: String, log: (String) -> Unit) {
        lgRunningCheck = null
        log("TV'de çalışan CouchSubs kapatıp açtıktan sonra da $running, kurulu $installed; kullanıcıdan TV'de kapatıp açması isteniyor.")
        state.value = TvAppStatus.RunningStale(tv, running, installed)
    }

    /** TV'deki CouchSubs'ı kapatıp açar (kayıtlı anahtar ve açık geliştirici modu gerekir); bloklayan. */
    private fun restartLg(context: Context, host: String): Boolean {
        val key = LgKeys(File(context.noBackupFilesDir, "lg")).load(host) ?: return false
        if (!LgInstaller.isDevModeOn(host)) return false
        return try {
            LgInstaller(JschShell(host, key), log = InstallLog(File(context.filesDir, "tvinstall.log"))).restart()
            true
        } catch (error: Exception) {
            Log.i(TAG, "LG uygulaması yeniden açılamadı: ${error.message}")
            false
        }
    }

    /** Akışla bildirilen sürüme göre öneri; boş paket sürümünde null (karar verilmez). */
    fun decide(tv: InstalledTv, reported: String, bundled: String): TvAppStatus? = when {
        bundled.isEmpty() -> null
        com.couchsubs.mobile.core.SubtitleServer.isTvAppOutdated(reported, bundled) ->
            TvAppStatus.Outdated(tv, reported.ifEmpty { UNREPORTED }, bundled)
        else -> TvAppStatus.UpToDate(reported)
    }

    /**
     * Kayıtlı TV'deki sürüme sessizce bakar (uygulama açılınca ve TV her bağlandığında). TV'ye ulaşılamazsa öneri
     * değişmez; kullanıcıdan hiçbir şey istenmez (Samsung girişi, Android TV onayı, LG parolası yok).
     */
    suspend fun check(context: Context) {
        withContext(Dispatchers.IO) { checkBlocking(context) }
    }

    private fun checkBlocking(context: Context) {
        val tv = Services.settings.installedTv ?: return
        if (!running.compareAndSet(false, true)) return
        try {
            val bundled = bundledVersion(context, tv.brand) ?: return
            val presence = try {
                readPresence(context, tv)
            } catch (error: Exception) {
                Log.i(TAG, "TV'deki sürüm okunamadı (${tv.brand} ${tv.host}): ${error.message}")
                SamsungInstaller.InstalledPresence.Unknown
            }
            val onTv = when (presence) {
                is SamsungInstaller.InstalledPresence.Version -> presence.version
                SamsungInstaller.InstalledPresence.Unknown -> return
                SamsungInstaller.InstalledPresence.Missing -> {
                    // TV'ye bağlanıldı ve listede CouchSubs yok: uygulama silinmiş (#1158); "kurulu" kaydı silinir.
                    samsungAppMissing(tv.host, InstallLog(File(context.filesDir, "tvinstall.log"))::write)
                    return
                }
            }
            Services.settings.installedTv = tv.copy(version = onTv)
            state.value = if (SamsungDiagnostics.isNewer(bundled, onTv)) TvAppStatus.Outdated(tv, onTv, bundled) else TvAppStatus.UpToDate(onTv)
        } finally {
            running.set(false)
        }
    }

    /**
     * Samsung TV'de CouchSubs yok (sessiz sürüm denetiminde `vd_applist` ya da bekçide TV'nin kurulu uygulama listesi):
     * uygulama güncelleme sırasında ya da elle silinmiş (#1158). Önceden "kurulu" kaydı kalıyordu: Ayarlar sürümü
     * gösteriyor, bekçi listesiz açmayı deniyor, ana ekran kurulumu önermiyordu. Eşli TV korunur, yalnız sürümü ve
     * "uygulama bağlandı" kaydı silinir. Mac, iPhone ve Windows ile aynı.
     */
    fun samsungAppMissing(host: String, log: (String) -> Unit = {}, settings: AppSettings = Services.settings) {
        val (tv, seen) = TvSessionLauncher.samsungForgetMissing(settings.installedTv, settings.samsungAppSeenHost, host)
        if (tv != settings.installedTv) {
            log("Samsung $host: TV'de CouchSubs yok; telefondaki \"kurulu\" kaydı (${settings.installedTv?.version}) silindi.")
            settings.installedTv = tv
        }
        if (seen != settings.samsungAppSeenHost) settings.samsungAppSeenHost = seen
        TvSessionLauncher.samsungForget(host)
        if ((state.value as? TvAppStatus.Outdated)?.tv?.brand == TvBrand.SAMSUNG) state.value = TvAppStatus.Unknown
    }

    private fun readPresence(context: Context, tv: InstalledTv): SamsungInstaller.InstalledPresence {
        if (tv.brand != TvBrand.SAMSUNG) {
            return readVersion(context, tv)?.let { SamsungInstaller.InstalledPresence.Version(it) } ?: SamsungInstaller.InstalledPresence.Unknown
        }
        val log = InstallLog(File(context.filesDir, "tvinstall.log"))
        if (!AndroidTvInstaller.isReachable(tv.host, SdbConnection.PORT)) return SamsungInstaller.InstalledPresence.Unknown
        return SamsungInstaller(
            host = tv.host,
            profilesDirectory = File(context.noBackupFilesDir, "samsung"),
            adbKey = { AdbKey.loadOrCreate(File(context.noBackupFilesDir, "sdb/adbkey")) },
            certificates = SamsungCertificates(log = log::write),
            signIn = null,
            log = log,
        ).installedPresence()
    }

    private fun readVersion(context: Context, tv: InstalledTv): String? {
        val log = InstallLog(File(context.filesDir, "tvinstall.log"))
        return when (tv.brand) {
            TvBrand.SAMSUNG -> (readPresence(context, tv) as? SamsungInstaller.InstalledPresence.Version)?.version
            TvBrand.LG -> {
                val key = LgKeys(File(context.noBackupFilesDir, "lg")).load(tv.host) ?: return null
                if (!LgInstaller.isDevModeOn(tv.host)) return null
                val installer = LgInstaller(JschShell(tv.host, key), log = log)
                val version = installer.installedVersion()
                renewLgSessionIfDue(tv.host, installer)
                version
            }
            TvBrand.ANDROID_TV -> {
                val port = tv.port.takeIf { it > 0 } ?: com.couchsubs.mobile.tv.android.AdbConnection.DEFAULT_PORT
                if (!AndroidTvInstaller.isReachable(tv.host, port)) return null
                AndroidTvInstaller(tv.host, port, adbKey = { AdbKey.loadOrCreate(File(context.noBackupFilesDir, "adb/adbkey")) }, log = log)
                    .installedVersion()
            }
        }
    }

    /** LG geliştirici modunun 1000 saatlik süresini günde en çok bir kez baştan başlatır (masaüstündeki gibi). */
    fun renewLgSessionIfDue(host: String, installer: LgInstaller) {
        val settings = Services.settings
        val hours = LgSessionRenewalPolicy.renewIfDue(
            now = System.currentTimeMillis(),
            lastRenewedAt = settings.lgSessionRenewedAt(host),
            saveRenewedAt = { settings.setLgSessionRenewedAt(host, it) },
            renew = { runCatching { installer.renewSession() }.getOrNull() },
        ) ?: return
        Log.i(TAG, "LG geliştirici modu uzatıldı: $hours saat kaldı")
    }
}
