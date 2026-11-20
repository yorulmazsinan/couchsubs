// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki windows/src/CouchSubs.TvInstall/Samsung/SamsungTvInstaller.cs'in telefon karşılığı: mantık aynıdır,
// sdb ve imza TizenSdb.Core yerine bu klasördeki Kotlin kodudur.
package com.couchsubs.mobile.tv.samsung

import java.io.File
import java.io.IOException
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Kurulumun TV ile konuşan kısmı; testlerde gerçek TV yerine sahtesi kullanılır. */
interface SamsungTvShell {
    /** Hazır (imzalı) paketi gönderip `vd_appinstall` ile kurar; TV'nin bütün çıktısını döner. */
    fun install(): String
    fun shell(command: String): String
}

/** Her adım ve TV'nin bütün yanıtları buraya yazılır (masaüstündeki tvinstall.log). */
class InstallLog(val file: File?) {
    private val format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT)

    @Synchronized
    fun write(line: String) {
        val target = file ?: return
        runCatching {
            target.parentFile?.mkdirs()
            // Günlük büyümesin: 512 KB'ı geçince baştan başlar.
            if (target.length() > 512 * 1024) target.delete()
            target.appendText("${format.format(Date())} $line\n")
        }
    }
}

/** Kurulumun ilerleyişi; arayüz her adımı Türkçe gösterir. PAIRING ve APPROVE_ON_TV Android TV'nin, KEY LG'nindir. */
enum class InstallStep { CONNECTING, READING, SIGN_IN, CERTIFICATE, SIGNING, INSTALLING, UNINSTALLING, LAUNCHING, PAIRING, APPROVE_ON_TV, KEY, OPEN_PLAY }

/**
 * CouchSubs'ın Samsung TV uygulamasını geliştirici modu açık TV'ye bu telefondan kurar: TV'nin DUID'ini okur, gerekirse
 * Samsung hesabıyla TV'ye özel sertifika alır, paketi imzalar, kurar ve açar. Çağrılar bloklar; IO iş parçacığında çalışır.
 *
 * @param signIn Sertifika yoksa çağrılır; Samsung girişi bitene kadar bloklar (arayüz giriş sayfasını gösterir).
 */
class SamsungInstaller(
    private val host: String,
    private val profilesDirectory: File,
    private val adbKey: () -> AdbKey,
    private val certificates: SamsungCertificates,
    private val signIn: (() -> SamsungAccount)?,
    private val progress: (InstallStep) -> Unit = {},
    private val log: InstallLog = InstallLog(null),
) {
    companion object {
        const val APP_ID = "CouchSubsT.CouchSubs"
        const val PACKAGE_ID = "CouchSubsT"

        /** Desteklenen en eski Tizen: 2.4 (2016, deneysel; #71 e göre elle kurulumu çalışıyor). 2.3 ve eskisi reddedilir. */
        const val MINIMUM_TIZEN = "2.4"

        /** Bu sürüme kadar (dahil) TV, kurulumdan önce dağıtıcının cihaz profilini (device-profile.xml) ister. */
        const val DEVICE_PROFILE_UP_TO = "4.0"

        fun isTooOld(platform: String) = platform.isNotEmpty() && SamsungDiagnostics.isNewer(MINIMUM_TIZEN, platform)

        fun needsDeviceProfile(platform: String) =
            platform.isNotEmpty() && !isTooOld(platform) && !SamsungDiagnostics.isNewer(platform, DEVICE_PROFILE_UP_TO)

        private val duidPattern = Regex("""^[A-Za-z0-9_\-+=/]{8,}$""")
        fun isDuid(text: String) = duidPattern.matches(text)

        internal fun safeName(duid: String) = duid.replace(Regex("""[^A-Za-z0-9_\-]"""), "_")

        /**
         * Kurar; TV başka sertifikayla kurulmuş eski kopya ya da paket kimliği yüzünden reddederse eski kopyayı kaldırıp
         * bir kez daha dener. Sonuç yine başarısızsa TV'nin söylediği sebeple [SamsungInstallException] atar.
         */
        fun installWithRecovery(tv: SamsungTvShell, progress: (InstallStep) -> Unit, log: InstallLog) {
            val output = tv.install()
            log.write("vd_appinstall çıktısı:\n${output.trim()}")
            val problem = SamsungDiagnostics.classify(output)
            if (problem == InstallProblem.NONE) return
            log.write("Kurulum başarısız: $problem")
            if (!SamsungDiagnostics.removingOldCopyMayHelp(problem))
                throw SamsungInstallException(SamsungDiagnostics.toError(problem), SamsungDiagnostics.summary(output))
            progress(InstallStep.UNINSTALLING)
            val removal = StringBuilder()
            for (id in listOf(PACKAGE_ID, APP_ID)) {
                try {
                    removal.append("$id: ${tv.shell("0 vd_appuninstall $id").trim()}\n")
                } catch (error: IOException) {
                    removal.append("$id: ${error.message}\n")
                }
            }
            log.write("Eski kopya kaldırıldı mı:\n${removal.toString().trim()}")
            val retry = tv.install()
            log.write("İkinci deneme vd_appinstall çıktısı:\n${retry.trim()}")
            val retryProblem = SamsungDiagnostics.classify(retry)
            if (retryProblem == InstallProblem.NONE) return
            throw SamsungInstallException(SamsungDiagnostics.toError(retryProblem), SamsungDiagnostics.summary(retry))
        }
    }

    data class Result(val version: String, val installed: Boolean)

    /** Bu TV için kayıtlı geçerli sertifika var mı (giriş gerekmeden kurulabilir mi)? */
    fun profileFor(duid: String) = SigningProfile(File(profilesDirectory, safeName(duid)))

    /**
     * TV'deki CouchSubs sürümüne bakar; yoksa ya da [version]'dan eskiyse imzalayıp kurar, sonra uygulamayı açar.
     * @param wgt İmzasız paket (uygulamayla gelir).
     */
    fun ensureInstalled(wgt: () -> ByteArray, version: String?): Result {
        log.write("--- Samsung kurulumu (telefon) başlıyor: TV $host, paket $version")
        try {
            val result = installCore(wgt, version)
            log.write(if (result.installed) "Kurulum tamam." else "TV'de ${result.version} sürümü var; kurulum gerekmedi.")
            return result
        } catch (error: SamsungInstallException) {
            log.write("HATA ${error.error}: ${error.detail}")
            throw error
        } catch (error: IOException) {
            // Adımların arasında TV bağlantıyı kapattı ya da yanıt vermedi: genel "kurulamadı"ya düşmesin.
            log.write("Bağlantı koptu: $error")
            throw SamsungInstallException(SamsungInstallError.CONNECTION_LOST, error.message ?: error.javaClass.simpleName)
        } catch (error: Exception) {
            log.write("Beklenmeyen hata: $error")
            throw error
        }
    }

    /** Yalnız TV'deki CouchSubs sürümünü okur (kurmaz, açmaz); uygulama yoksa null. Güncelleme denetimi için. */
    fun installedVersion(): String? = connect().use { readInstalledVersion(it) }

    private fun installCore(wgt: () -> ByteArray, version: String?): Result {
        progress(InstallStep.CONNECTING)
        connect().use { device ->
            progress(InstallStep.READING)
            val capabilities = device.capability()
            val platform = capabilities["platform_version"]?.trim() ?: ""
            val toolPath = capabilities["sdk_toolpath"]?.trim()?.takeIf { it.isNotEmpty() } ?: "/opt/usr/apps/tmp"
            log.write("TV: Tizen ${platform.ifEmpty { "?" }}, sdk_toolpath $toolPath")
            if (isTooOld(platform)) throw SamsungInstallException(SamsungInstallError.TOO_OLD, "Tizen $platform")
            if (platform.isNotEmpty() && SamsungDiagnostics.isNewer("5.0", platform)) log.write("Tizen $platform: 2016–2018 TV si, destek deneysel.")

            val onTv = readInstalledVersion(device)
            if (version != null && onTv != null && !SamsungDiagnostics.isNewer(version, onTv)) {
                launch(device)
                return Result(onTv, false)
            }
            log.write(if (onTv == null) "TV'de CouchSubs görünmüyor; kuruluyor." else "TV'de $onTv var, ${version ?: "yeni sürüm"} kuruluyor.")

            val duid = readDuid(device)
            log.write("DUID: $duid")
            var profile = profileFor(duid)
            log.write("Kayıtlı sertifika: ${profile.describe(Date(), duid)}")
            if (!profile.isValid() || !profile.isFor(duid)) {
                val login = signIn ?: throw SamsungInstallException(SamsungInstallError.LOGIN_FAILED, "giriş gerekiyor")
                progress(InstallStep.SIGN_IN)
                log.write("Samsung hesabıyla giriş bekleniyor.")
                val account = login()
                log.write("Samsung girişi tamam; sertifika isteniyor.")
                progress(InstallStep.CERTIFICATE)
                profile = certificates.create(duid, account, profile)
                log.write("Yeni sertifika: ${profile.describe(Date(), duid)}")
            }

            if (needsDeviceProfile(platform)) pushDeviceProfile(device, profile, toolPath)

            progress(InstallStep.SIGNING)
            val key = profile.privateKey()
            val unsigned = if (LegacyTizenPackage.applies(platform)) {
                LegacyTizenPackage.adapt(wgt()).also {
                    log.write("Tizen $platform: paketten network.public izni ve ultra geniş ekran ayarı çıkarıldı (#621).")
                }
            } else wgt()
            val signed = WgtSigner.sign(unsigned,
                WgtSigner.Signer(key, SamsungCertificates.chain(profile.author())),
                WgtSigner.Signer(key, SamsungCertificates.chain(profile.distributor())))
            log.write("Paket imzalandı (${signed.size} bayt).")
            progress(InstallStep.INSTALLING)
            try {
                installWithRecovery(SdbShell(device, signed, toolPath), progress, log)
            } catch (error: SamsungInstallException) {
                if (error.error == SamsungInstallError.CERTIFICATE_REJECTED) {
                    // TV bu sertifikayı kabul etmiyor; bir sonraki denemede Samsung'dan yenisi istensin.
                    profile.discard()
                    log.write("Kayıtlı sertifika bırakıldı; bir sonraki denemede yenisi alınacak.")
                }
                throw error
            }
            val after = readInstalledVersion(device)
            if (version != null && after != null && SamsungDiagnostics.isNewer(version, after))
                throw SamsungInstallException(SamsungInstallError.INSTALL_FAILED,
                    "TV kurulumu bitirdi ama TV'de hâlâ $after sürümü var ($version kurulmalıydı)")
            launch(device)
            return Result(after ?: version ?: "", true)
        }
    }

    private fun readInstalledVersion(device: SdbConnection): String? = try {
        val listing = device.shell("0 vd_applist")
        SamsungDiagnostics.installedVersion(listing).also {
            log.write("vd_applist: ${if (it == null) "CouchSubs yok" else "CouchSubs $it"} (${listing.length} karakter)")
        }
    } catch (error: IOException) {
        log.write("vd_applist okunamadı: ${error.message}")
        null
    }

    /** Uygulamayı açar; açılmasa da kurulum başarılıdır. */
    private fun launch(device: SdbConnection) {
        progress(InstallStep.LAUNCHING)
        try {
            log.write("Uygulama açılıyor: ${device.shell("0 was_execute $APP_ID").trim()}")
        } catch (error: IOException) {
            log.write("Uygulama açılamadı (kurulum yine tamam): ${error.message}")
        }
    }

    /** Tizen 3.0–4.0: sertifika alınırken saklanan cihaz profili TV'nin `sdk_toolpath` klasörüne gönderilir. */
    private fun pushDeviceProfile(device: SdbConnection, profile: SigningProfile, toolPath: String) {
        if (!profile.deviceProfileFile.exists()) {
            log.write("Cihaz profili (device-profile.xml) yok; gönderilmeden kuruluyor.")
            return
        }
        val remote = "$toolPath/device-profile.xml"
        try {
            device.push(profile.deviceProfileFile.readBytes(), remote)
            log.write("Cihaz profili gönderildi: $remote")
        } catch (error: IOException) {
            log.write("Cihaz profili gönderilemedi ($remote): ${error.message}")
        }
    }

    private fun connect(): SdbConnection = try {
        SdbConnection.connect(host, adbKey()).also { log.write("sdb bağlantısı kuruldu ($host:${SdbConnection.PORT}).") }
    } catch (error: IOException) {
        throw SamsungInstallException(SamsungInstallError.UNREACHABLE, "sdb $host:${SdbConnection.PORT}: ${error.message}")
    }

    private fun readDuid(device: SdbConnection): String {
        // Yavaş TV'lerde ilk yanıt boş gelebiliyor; birkaç kez dene.
        var last = ""
        repeat(3) {
            last = device.shell("0 getduid")
            val duid = last.split('\n')[0].trim()
            if (isDuid(duid)) return duid
            Thread.sleep(500)
        }
        throw SamsungInstallException(SamsungInstallError.UNREACHABLE,
            "TV kimliği (DUID) okunamadı; TV'nin yanıtı: ${last.trim().ifEmpty { "boş" }}")
    }

    /** Gerçek TV: paket `sdk_toolpath`'e gönderilir ve `vd_appinstall` ile kurulur. */
    private class SdbShell(private val device: SdbConnection, private val signed: ByteArray, private val toolPath: String) : SamsungTvShell {
        private val remote = "$toolPath/couchsubs-%08x.wgt".format(SecureRandom().nextInt())

        /** TizenSdb'deki gibi hata da çıktıya yazılır; tanı çıktıdan yapılır. */
        override fun install(): String {
            val output = StringBuilder()
            try {
                device.push(signed, remote)
                output.append("Push complete.\n")
                output.append(device.shell("0 vd_appinstall $APP_ID $remote"))
            } catch (error: Exception) {
                output.append("\ninstall failed: ${error.javaClass.simpleName}: ${error.message}\n")
            }
            return output.toString()
        }

        override fun shell(command: String) = device.shell(command)
    }
}
