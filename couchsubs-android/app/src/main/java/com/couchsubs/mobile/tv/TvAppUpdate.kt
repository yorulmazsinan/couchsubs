// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki refreshTVApp'in (mac/CouchSubs/AppModel.swift) telefon karşılığı: TV'deki CouchSubs sürümüne bakar.
// Fark: telefon güncellemeyi kendiliğinden kurmaz, ana ekranda "TV uygulamasını güncelle" önerir.
package com.couchsubs.mobile.tv

import android.content.Context
import android.util.Log
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.tv.android.AndroidTvInstaller
import com.couchsubs.mobile.tv.lg.JschShell
import com.couchsubs.mobile.tv.lg.LgInstaller
import com.couchsubs.mobile.tv.lg.LgKeys
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
data class InstalledTv(val brand: TvBrand, val host: String, val port: Int = 0, val version: String? = null)

sealed interface TvAppStatus {
    /** Henüz bakılmadı ya da TV'ye ulaşılamadı (geliştirici modu kapalı, TV kapalı). */
    data object Unknown : TvAppStatus
    data class UpToDate(val version: String) : TvAppStatus
    /** TV'deki sürüm telefondakinden eski: ana ekran güncellemeyi önerir. */
    data class Outdated(val tv: InstalledTv, val installed: String, val bundled: String) : TvAppStatus
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
        // Kurulumun 3. adımından TV uygulaması kurulunca altyazı TV'ye gider ve kurulum biter; yoksa uygulama her
        // açılışta yine 3. adımdan (altyazının yeri) başlıyordu, "Devam"a basılmadıysa ana ekrana hiç gelinmiyordu (#113).
        // "İkisi de" seçiliyse korunur; yalnız "Bu telefonda" TV'ye döner.
        if (!settings.target.showsOnTv) settings.target = SubtitleTarget.TV
        settings.onboarded = true
        state.value = tv.version?.takeIf { it.isNotEmpty() }?.let { TvAppStatus.UpToDate(it) } ?: TvAppStatus.Unknown
    }

    /** 0.9.69'den eski TV uygulamaları sürüm bildirmez; ekranda böyle görünür. */
    const val UNREPORTED = "< 0.9.69"

    /**
     * TV uygulaması altyazı akışına bağlanıp sürümünü bildirdi (boş: 0.9.69'den eski, sürüm bildirmeyen uygulama). LG'de
     * geliştirici modu kapalıyken ya da anahtar bu telefonda değilken [check] TV'deki sürümü okuyamıyor, TV uygulaması
     * eski kalıyor ve hiç öneri çıkmıyordu (GitHub #884, #891). Eskiyse ana ekran "TV uygulamasını güncelle" önerir.
     */
    fun reported(context: Context, version: String) {
        val tv = Services.settings.installedTv ?: return
        val bundled = bundledVersion(context, tv.brand) ?: return
        state.value = decide(tv, version, bundled) ?: return
        if (version.isNotEmpty() && tv.version != version) Services.settings.installedTv = tv.copy(version = version)
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
            val onTv = try {
                readVersion(context, tv)
            } catch (error: Exception) {
                Log.i(TAG, "TV'deki sürüm okunamadı (${tv.brand} ${tv.host}): ${error.message}")
                null
            } ?: return
            Services.settings.installedTv = tv.copy(version = onTv)
            state.value = if (SamsungDiagnostics.isNewer(bundled, onTv)) TvAppStatus.Outdated(tv, onTv, bundled) else TvAppStatus.UpToDate(onTv)
        } finally {
            running.set(false)
        }
    }

    private fun readVersion(context: Context, tv: InstalledTv): String? {
        val log = InstallLog(File(context.filesDir, "tvinstall.log"))
        return when (tv.brand) {
            TvBrand.SAMSUNG -> {
                if (!AndroidTvInstaller.isReachable(tv.host, SdbConnection.PORT)) return null
                SamsungInstaller(
                    host = tv.host,
                    profilesDirectory = File(context.noBackupFilesDir, "samsung"),
                    adbKey = { AdbKey.loadOrCreate(File(context.noBackupFilesDir, "sdb/adbkey")) },
                    certificates = SamsungCertificates(log = log::write),
                    signIn = null,
                    log = log,
                ).installedVersion()
            }
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
