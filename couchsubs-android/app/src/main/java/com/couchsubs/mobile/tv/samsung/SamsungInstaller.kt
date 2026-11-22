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

        /** `0 was_execute` yanıtı uygulamanın açıldığını söylüyor mu ("app_id[…] launched"; Windows/Mac/iPhone ile aynı). */
        fun sdbLaunched(reply: String): Boolean = reply.contains("] launched") && !reply.contains("fail", ignoreCase = true)

        fun isTooOld(platform: String) =platform.isNotEmpty() && SamsungDiagnostics.isNewer(MINIMUM_TIZEN, platform)

        fun needsDeviceProfile(platform: String) =
            platform.isNotEmpty() && !isTooOld(platform) && !SamsungDiagnostics.isNewer(platform, DEVICE_PROFILE_UP_TO)

        /** Tizen 2.x'te cihaz profilinin konduğu klasör (Tizen Studio ve Apps2Samsung ile aynı). */
        const val LEGACY_DEVICE_PROFILE_DIRECTORY = "/home/developer"

        /**
         * Cihaz profilinin TV'deki yolu: Tizen 3.0–4.0'da `sdk_toolpath`, Tizen 2.x'te (2016) `/home/developer`. 2.4 TV
         * profili yalnız orada arar; #71'de çalışan kurulum (Apps2Samsung) oraya gönderiyordu, profili `/opt/usr/apps/tmp`'ye
         * gönderen her 2.4 kurulumu `install failed[118]` verdi (#890). Windows/Mac ve iPhone ile aynı.
         */
        fun deviceProfileRemotePath(platform: String, toolPath: String) =
            (if (LegacyTizenPackage.applies(platform)) LEGACY_DEVICE_PROFILE_DIRECTORY else toolPath) + "/device-profile.xml"

        private val duidPattern = Regex("""^[A-Za-z0-9_\-+=/]{8,}$""")
        fun isDuid(text: String) = duidPattern.matches(text)

        internal fun safeName(duid: String) = duid.replace(Regex("""[^A-Za-z0-9_\-]"""), "_")

        /**
         * Kurar; TV başka sertifikayla kurulmuş eski kopya ya da paket kimliği yüzünden reddederse eski kopyayı kaldırıp
         * bir kez daha dener. Sonuç yine başarısızsa TV'nin söylediği sebeple [SamsungInstallException] atar.
         *
         * @param alternative İki deneme de sebepsiz (yalın `[118]`) başarısız olursa çağrılır: başka biçimde hazırlanmış
         * paketi sıraya koyup adını döner (yoksa null); o paketle üçüncü kez denenir.
         * @param keepExisting TV'deki kopyaya dokunulmaz (`vd_appuninstall` yok): Tizen 2.x'te TV'de CouchSubs varsa ya da
         * liste okunamadıysa. 2016 TV'de Tizen Studio ile elle kurulmuş, çalışan kopya kurtarma adımında silinmesin
         * (docs/tv-samsung.md, #638). Sebepsiz `[118]`'de [alternative] yine bir kez denenir.
         */
        fun installWithRecovery(tv: SamsungTvShell, progress: (InstallStep) -> Unit, log: InstallLog, alternative: (() -> String?)? = null,
                                keepExisting: Boolean = false) {
            val output = tv.install()
            log.write("vd_appinstall çıktısı:\n${output.trim()}")
            val problem = SamsungDiagnostics.classify(output)
            if (problem == InstallProblem.NONE) return
            log.write("Kurulum başarısız: $problem")
            if (keepExisting && SamsungDiagnostics.removingOldCopyMayHelp(problem)) {
                log.write("TV'de CouchSubs var ya da liste okunamadı (elle kurulmuş olabilir); eski kopya kaldırılmıyor.")
                val kept = if (problem == InstallProblem.OTHER) alternative?.invoke() else null
                if (kept != null) {
                    val second = tv.install()
                    log.write("İkinci deneme ($kept) vd_appinstall çıktısı:\n${second.trim()}")
                    val secondProblem = SamsungDiagnostics.classify(second)
                    if (secondProblem == InstallProblem.NONE) return
                    throw SamsungInstallException(SamsungDiagnostics.toError(secondProblem), SamsungDiagnostics.summary(second))
                }
                throw SamsungInstallException(SamsungDiagnostics.toError(problem), SamsungDiagnostics.summary(output))
            }
            if (!SamsungDiagnostics.removingOldCopyMayHelp(problem))
                throw SamsungInstallException(SamsungDiagnostics.toError(problem), SamsungDiagnostics.summary(output))
            progress(InstallStep.UNINSTALLING)
            fun remove(): String {
                val removal = StringBuilder()
                for (id in listOf(PACKAGE_ID, APP_ID)) {
                    try {
                        removal.append("$id: ${tv.shell("0 vd_appuninstall $id").trim()}\n")
                    } catch (error: IOException) {
                        removal.append("$id: ${error.message}\n")
                    }
                }
                return removal.toString().trim()
            }
            log.write("Eski kopya kaldırıldı mı:\n${remove()}")
            val retry = tv.install()
            log.write("İkinci deneme vd_appinstall çıktısı:\n${retry.trim()}")
            val retryProblem = SamsungDiagnostics.classify(retry)
            if (retryProblem == InstallProblem.NONE) return
            // TV iki kez de sebep söylemediyse (yalın [118]) ve başka biçimde hazırlanabilen paket varsa onunla bir kez daha.
            val label = if (problem == InstallProblem.OTHER && retryProblem == InstallProblem.OTHER) alternative?.invoke() else null
            if (label != null) {
                log.write("Eski kopya kaldırıldı mı:\n${remove()}")
                val last = tv.install()
                log.write("Üçüncü deneme ($label) vd_appinstall çıktısı:\n${last.trim()}")
                val lastProblem = SamsungDiagnostics.classify(last)
                if (lastProblem == InstallProblem.NONE) return
                throw SamsungInstallException(SamsungDiagnostics.toError(lastProblem), SamsungDiagnostics.summary(last))
            }
            throw SamsungInstallException(SamsungDiagnostics.toError(retryProblem), SamsungDiagnostics.summary(retry))
        }
    }

    data class Result(val version: String, val installed: Boolean)

    /** Bu TV için kayıtlı geçerli sertifika var mı (giriş gerekmeden kurulabilir mi)? */
    fun profileFor(duid: String) = SigningProfile(File(profilesDirectory, safeName(duid)))

    /**
     * TV'deki CouchSubs sürümüne bakar; yoksa ya da [version]'dan eskiyse imzalayıp kurar, sonra uygulamayı açar.
     * @param wgt İmzasız paket (uygulamayla gelir).
     * @param replaceForeign Bizim kimliğimizle başka bir uygulama kuruluysa kaldırılıp kurulsun mu (yalnız kullanıcı onayıyla).
     */
    fun ensureInstalled(wgt: () -> ByteArray, version: String?, replaceForeign: Boolean = false): Result {
        log.write("--- Samsung kurulumu (telefon) başlıyor: TV $host, paket $version")
        try {
            val result = installCore(wgt, version, replaceForeign)
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
    fun installedVersion(): String? = connect().use { device -> readInstalledVersion(device).takeUnless { lastForeign } }

    /**
     * Kurulu TV uygulamasını geliştirici bağlantısıyla (sdb, `was_execute`) açar; arka plandaysa öne getirir (Windows, Mac ve
     * iPhone'daki bekçiyle aynı). sdb izin sormaz, TV'de bildirim çıkarmaz. Geliştirici modu kapalıysa ya da Host PC IP başka
     * cihazınsa false.
     */
    fun openApp(): Boolean {
        log.write("--- Samsung: TV uygulaması bağlı değil, açılıyor (TV $host)")
        return try {
            connect().use { device ->
                val reply = device.shell("0 was_execute $APP_ID")
                log.write("Uygulama açılıyor: ${reply.trim()}")
                sdbLaunched(reply)
            }
        } catch (error: Exception) {
            log.write("Uygulama açılamadı: ${error.message}")
            false
        }
    }

    private fun installCore(wgt: () -> ByteArray, version: String?, replaceForeign: Boolean): Result {
        progress(InstallStep.CONNECTING)
        connect().use { device ->
            progress(InstallStep.READING)
            val capabilities = device.capability()
            val platform = capabilities["platform_version"]?.trim() ?: ""
            val toolPath = capabilities["sdk_toolpath"]?.trim()?.takeIf { it.isNotEmpty() } ?: "/opt/usr/apps/tmp"
            log.write("TV: Tizen ${platform.ifEmpty { "?" }}, sdk_toolpath $toolPath")
            if (isTooOld(platform)) throw SamsungInstallException(SamsungInstallError.TOO_OLD, "Tizen $platform")
            if (platform.isNotEmpty() && SamsungDiagnostics.isNewer("5.0", platform)) log.write("Tizen $platform: 2016–2018 TV si, destek deneysel.")

            var onTv = readInstalledVersion(device)
            // "CouchSubs yok" ile "liste okunamadı" ayrılsın (Tizen 2.x'te okunamayan listede kopya kaldırılmaz).
            val listRead = lastListRead
            if (lastForeign) {
                // Bizim kimliğimizle başka bir uygulama: yalnız kullanıcı onaylarsa kaldırılır.
                if (!replaceForeign) throw SamsungInstallException(SamsungInstallError.FOREIGN_APP, "TV'deki uygulamanın adı CouchSubs değil")
                progress(InstallStep.UNINSTALLING)
                for (id in listOf(PACKAGE_ID, APP_ID)) {
                    val reply = try { device.shell("0 vd_appuninstall $id").trim() } catch (error: IOException) { error.message ?: "" }
                    log.write("Diğer uygulama kaldırılıyor (kullanıcı onayladı) $id: $reply")
                }
                onTv = null
            }
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

            if (needsDeviceProfile(platform)) pushDeviceProfile(device, profile, platform, toolPath)

            progress(InstallStep.SIGNING)
            val key = profile.privateKey()
            // Tizen 2.x (2016): #71'de çalışan paket: o config.xml ve SHA-512 imza (Apps2Samsung'un TizenSdb'si, #890);
            // TV yine yalın [118] derse SHA-256 imzalı yalın paket (#638).
            val legacy = LegacyTizenPackage.applies(platform)
            fun sign(unsigned: ByteArray, digest: WgtSigner.Digest = WgtSigner.Digest.SHA512) = WgtSigner.sign(unsigned,
                WgtSigner.Signer(key, SamsungCertificates.chain(profile.author())),
                WgtSigner.Signer(key, SamsungCertificates.chain(profile.distributor())), digest)
            val original = wgt()
            val signed = if (legacy) {
                sign(LegacyTizenPackage.adapt(original)).also {
                    log.write("Tizen $platform: paketten network.public izni ve ultra geniş ekran ayarı çıkarıldı (#621).")
                    log.write("Tizen $platform: imza SHA-512 ile üretildi (#71'de çalışan paketle aynı).")
                }
            } else {
                // 21:9 / 32:9 Samsung monitör: geniş uygulama yüzeyi (#886; TV'lerde paket değişmez).
                val info = SamsungTvInfo.fetch(host)
                log.write("Ekran: model ${info?.model ?: "?"}, çözünürlük ${info?.resolution ?: "?"}")
                val wide = WideScreenPackage.applies(info?.model, info?.resolution)
                if (wide) log.write("Ultra geniş monitör: paket geniş uygulama yüzeyiyle (base_screen_resolution, device-width) kuruluyor (#886).")
                sign(if (wide) WideScreenPackage.adapt(original) else original)
            }
            log.write("Paket imzalandı (${signed.size} bayt).")
            progress(InstallStep.INSTALLING)
            try {
                val shell = SdbShell(device, signed, toolPath)
                var lean = false
                val alternative: (() -> String?)? = if (!legacy) null else {
                    {
                        shell.signed = sign(LegacyTizenPackage.adapt(original, lean = true), WgtSigner.Digest.SHA256)
                        lean = true
                        log.write("Tizen $platform: yalın paket hazırlandı (${LegacyTizenPackage.LEAN_REMOVED} de çıkarıldı), imza SHA-256.")
                        "yalın paket"
                    }
                }
                installWithRecovery(shell, progress, log, alternative, keepExisting = legacy && (onTv != null || !listRead))
                if (legacy) log.write("Tizen $platform: ${if (lean) "yalın paket SHA-256" else "tam paket SHA-512"} imzayla kuruldu.")
            } catch (error: SamsungInstallException) {
                if (error.error == SamsungInstallError.CERTIFICATE_REJECTED) {
                    // TV bu sertifikayı kabul etmiyor; bir sonraki denemede Samsung'dan yenisi istensin.
                    profile.discard()
                    log.write("Kayıtlı sertifika bırakıldı; bir sonraki denemede yenisi alınacak.")
                }
                if (!legacy || onTv == null) throw error
                // Tizen 2.x: TV'deki kopya (ör. Tizen Studio ile elle kurulmuş) yerinde; yeni paket kurulamadı diye
                // çalışan uygulama "kurulamadı" gösterilmez, o açılır (#638).
                log.write("Tizen $platform: yeni paket kurulamadı (${error.error}); TV'deki CouchSubs $onTv korunuyor ve açılıyor.")
                launch(device)
                return Result(onTv, false)
            }
            val after = readInstalledVersion(device)
            if (version != null && after != null && SamsungDiagnostics.isNewer(version, after))
                throw SamsungInstallException(SamsungInstallError.INSTALL_FAILED,
                    "TV kurulumu bitirdi ama TV'de hâlâ $after sürümü var ($version kurulmalıydı)")
            launch(device)
            return Result(after ?: version ?: "", true)
        }
    }

    /** Son `vd_applist` okunabildi mi. */
    private var lastListRead = false

    /** Son `vd_applist`'te bizim kimliğimizle başka bir uygulama (adı CouchSubs değil) kurulu muydu. */
    private var lastForeign = false

    private fun readInstalledVersion(device: SdbConnection): String? = try {
        lastListRead = false
        lastForeign = false
        val listing = device.shell("0 vd_applist")
        lastListRead = true
        lastForeign = SamsungDiagnostics.isForeignApp(listing)
        SamsungDiagnostics.installedVersion(listing).also {
            log.write("vd_applist: ${if (it == null) "CouchSubs yok" else if (lastForeign) "CouchSubs kimliğiyle başka bir uygulama ($it)" else "CouchSubs $it"} (${listing.length} karakter)")
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

    /**
     * Tizen 2.4–4.0: sertifika alınırken saklanan cihaz profili TV'ye gönderilir ([deviceProfileRemotePath]); Tizen 2.x'te
     * `/home/developer`'a gönderilemezse `sdk_toolpath` denenir.
     */
    private fun pushDeviceProfile(device: SdbConnection, profile: SigningProfile, platform: String, toolPath: String) {
        if (!profile.deviceProfileFile.exists()) {
            log.write("Cihaz profili (device-profile.xml) yok; gönderilmeden kuruluyor.")
            return
        }
        val remote = deviceProfileRemotePath(platform, toolPath)
        val fallback = "$toolPath/device-profile.xml"
        for (target in if (remote == fallback) listOf(remote) else listOf(remote, fallback)) {
            try {
                device.push(profile.deviceProfileFile.readBytes(), target)
                log.write("Cihaz profili gönderildi: $target")
                return
            } catch (error: IOException) {
                log.write("Cihaz profili gönderilemedi ($target): ${error.message}")
            }
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
    private class SdbShell(private val device: SdbConnection, var signed: ByteArray, private val toolPath: String) : SamsungTvShell {
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
