// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki DevModeInstaller.cs'in (windows/src/CouchSubs.Core/LgTv; Mac'te core/.../LGTV/DevModeInstaller.swift)
// telefon karşılığı; geliştirici modunun süresi de masaüstündeki gibi uzatılır (renewSession).
package com.couchsubs.mobile.tv.lg

import com.couchsubs.mobile.tv.samsung.InstallLog
import com.couchsubs.mobile.tv.samsung.InstallStep
import com.couchsubs.mobile.tv.samsung.SamsungDiagnostics
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL

/** LG kurulumunda çıkan sorunlar; arayüz her birine ne yapılacağını söyler (masaüstündeki DevModeError). */
enum class LgInstallError {
    /** 9922 yanıt vermiyor: geliştirici modu kapalı ya da TV başka ağda. */
    UNREACHABLE,
    /** Developer Mode uygulamasında Key Server kapalı. */
    KEY_SERVER_OFF,
    WRONG_PASSPHRASE,
    /** TV anahtarı reddetti (geliştirici modu yeniden açılınca TV yeni anahtar üretir). */
    KEY_REFUSED,
    NOT_ENOUGH_SPACE,
    INSTALL_FAILED,
    CONNECTION_LOST,
    PACKAGE_MISSING,
    /**
     * TV'de com.couchsubs.tv kimliğiyle başka bir uygulama kurulu (appinfo.json'da başlık ya da üretici bizim değil).
     * Kullanıcı onaylamadan kaldırılmaz; onaylarsa kaldırılıp CouchSubs kurulur.
     */
    FOREIGN_APP,
    /**
     * TV paketi "ipk verified failed" (errorCode -5) ile reddetti ve TV'nin saati çok geride (paketteki dosya tarihleri
     * ona göre gelecekte). Kullanıcı TV'nin saatini düzeltir (iPhone'daki LGInstallError.tvClockWrong).
     */
    TV_CLOCK_WRONG,
}

/**
 * Geliştirici modunun SSH'si (9922) yanıt vermediğinde TV'nin durumu: diğer portlara bakılarak ayrılır (iPhone'daki
 * LGUnreachableReason). Eskiden hep "TV yanıt vermedi" deniyordu; oysa TV açık ve Key Server'ı da açık olabiliyordu.
 */
enum class LgUnreachableReason {
    /** Key Server (9991) açık ama SSH kapalı: Dev Mode Status açıldıktan sonra TV yeniden başlamamış. */
    RESTART_NEEDED,
    /** TV bu adreste (3000/3001 yanıt veriyor) ama geliştirici modu kapalı ya da süresi dolmuş. */
    DEV_MODE_OFF,
    /** Bu adreste hiçbir port yanıt vermiyor: TV kapalı, başka ağda ya da adresi değişmiş. */
    TV_NOT_FOUND;

    companion object {
        fun classify(keyServer: Boolean, ssap: Boolean) = when {
            keyServer -> RESTART_NEEDED
            ssap -> DEV_MODE_OFF
            else -> TV_NOT_FOUND
        }

        /** TV'nin Key Server (9991) ve kumanda (3000/3001) portlarına bakar. Bloklar. */
        fun probe(host: String, timeoutMs: Int = 1_500, isOpen: (Int) -> Boolean = { port ->
            try { java.net.Socket().use { it.connect(java.net.InetSocketAddress(host, port), timeoutMs) }; true } catch (error: java.io.IOException) { false }
        }): LgUnreachableReason {
            val keyServer = isOpen(LgInstaller.KEY_SERVER_PORT)
            return classify(keyServer, keyServer || isOpen(3001) || isOpen(3000))
        }
    }
}

class LgInstallException(val error: LgInstallError, val detail: String? = null) :
    IOException(if (detail == null) error.name else "${error.name}: $detail")

data class CommandResult(val status: Int, val output: String)

/** Key Server'dan alınıp çözülmüş anahtarlar, TV adresine göre (uygulamanın yedeklenmeyen klasöründe). */
class LgKeys(private val directory: File) {
    private fun file(host: String) = File(directory, host.trim().replace(Regex("""[^A-Za-z0-9._-]"""), "_") + ".key")

    fun load(host: String): ByteArray? = file(host).takeIf { it.isFile }?.readBytes()

    fun save(host: String, key: ByteArray) {
        directory.mkdirs()
        file(host).writeBytes(key)
    }

    fun remove(host: String) {
        file(host).delete()
    }
}

/** TV'de komut çalıştırır; [input] verilirse komutun girişine yazılır ve giriş kapatılır. */
fun interface LgShell {
    fun run(command: String, input: ByteArray?): CommandResult
}

/**
 * TV uygulamasını LG'nin geliştirici modu üzerinden kurar ve günceller. Geliştirici modu açık TV 9922 portunda SSH
 * bekler; anahtar Key Server'dan (9991) bir kez alınır, TV ekranındaki parolayla çözülür.
 */
class LgInstaller(
    private val shell: LgShell,
    private val progress: (InstallStep) -> Unit = {},
    private val log: InstallLog = InstallLog(null),
    private val pollIntervalMs: Long = 2_000,
    private val installTimeoutSeconds: Int = 180,
    private val verifyTimeoutMs: Long? = null,
) {
    data class Result(val version: String, val installed: Boolean)

    /** "ipk verified failed" (-5) ayrıntısı; saat çok gerideyse `clockWrong`. */
    data class VerifyFailure(val clockWrong: Boolean, val detail: String)

    companion object {
        const val PORT = 9922
        const val KEY_SERVER_PORT = 9991
        const val APP_ID = "com.couchsubs.tv"
        private const val APP_INFO = "/media/developer/apps/usr/palm/applications/$APP_ID/appinfo.json"
        const val TEMP_DIR = "/media/developer/temp"
        private const val INSTALL_LOG = "$TEMP_DIR/couchsubs-install.log"
        private const val SESSION_TOKEN = "/var/luna/preferences/devmode_enabled"

        /** LG'nin yanıtındaki kalan süre `999:58:40` (saat:dakika:saniye) biçimindedir. */
        fun remainingHours(response: String): Int? =
            Regex("""\d{1,4}:\d{2}:\d{2}""").find(response)?.value?.substringBefore(':')?.toIntOrNull()

        fun keyUrl(host: String, port: Int = KEY_SERVER_PORT) = "http://$host:$port/webos_rsa"

        /** ares-install gibi paket TV'ye kendi adıyla yüklenir. */
        fun remotePackage(name: String) = "$TEMP_DIR/${name.substringAfterLast('/')}"

        /** `com.couchsubs.tv_0.6.1_all.ipk` → `0.6.1` */
        fun versionOfPackage(name: String): String? {
            val parts = name.split('_')
            return if (name.endsWith(".ipk") && parts.size >= 3) parts[1] else null
        }

        fun versionFromAppInfo(text: String): String? = Regex(""""version"\s*:\s*"([^"]+)"""").find(text)?.groupValues?.get(1)

        /** Bizim appinfo.json'daki başlık ve üretici (tv-webos/appinfo.json). */
        const val OUR_TITLE = "CouchSubs"
        const val OUR_VENDOR = "Enmera"

        private fun appInfoField(text: String, name: String): String? =
            Regex(""""$name"\s*:\s*"([^"]*)"""").find(text)?.groupValues?.get(1)

        /**
         * TV'deki appinfo.json başka bir uygulamanın mı: başlık "CouchSubs" değil ya da üretici "Enmera" değil (büyük/küçük
         * harf gözetilmez). Dosya ya da alan yoksa bizim sayılır (Windows, Mac ve iPhone ile aynı kural).
         */
        fun isForeignAppInfo(text: String): Boolean {
            if (versionFromAppInfo(text) == null) return false
            val title = appInfoField(text, "title")?.trim()
            val vendor = appInfoField(text, "vendor")?.trim()
            return (title != null && !title.equals(OUR_TITLE, ignoreCase = true)) ||
                (vendor != null && !vendor.equals(OUR_VENDOR, ignoreCase = true))
        }

        /**
         * Geliştirici modunda kurulu uygulamayı kaldıran komut (ares-install --remove'un kullandığı istek); appinfo.json
         * silinene kadar (en çok 20 sn) bekler.
         */
        const val REMOVE_COMMAND =
            "/usr/bin/luna-send-pub -n 1 'luna://com.webos.appInstallService/dev/remove' '{\"id\":\"$APP_ID\",\"subscribe\":false}'; " +
                "i=0; while [ -f $APP_INFO ] && [ \$i -lt 20 ]; do sleep 1; i=\$((i+1)); done"

        /** Geliştirici modu açık mı (9922 yanıt veriyor mu)? */
        fun isDevModeOn(host: String, timeoutMs: Int = 1_500): Boolean = try {
            Socket().use { it.connect(InetSocketAddress(host, PORT), timeoutMs) }
            true
        } catch (error: IOException) {
            false
        }

        /** Key Server'dan anahtarı alır (yanıt yoksa [LgInstallError.KEY_SERVER_OFF]). */
        fun downloadKey(host: String, port: Int = KEY_SERVER_PORT, timeoutMs: Int = 5_000): ByteArray = try {
            val connection = URL(keyUrl(host, port)).openConnection() as HttpURLConnection
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            try {
                if (connection.responseCode != 200) throw IOException("HTTP ${connection.responseCode}")
                connection.inputStream.use { it.readBytes() }
            } finally {
                connection.disconnect()
            }
        } catch (error: IOException) {
            throw LgInstallException(LgInstallError.KEY_SERVER_OFF, error.message)
        }

        /**
         * Key Server'ın yanıtını parolasız PEM'e çevirir. TV'nin anahtarı eski PEM biçimindedir; başka biçimdeyse
         * çözmeyi SSH kütüphanesi dener ([otherFormat]).
         */
        fun decodeKey(response: ByteArray, passphrase: String, otherFormat: (ByteArray, String) -> ByteArray): ByteArray {
            val text = String(response, Charsets.UTF_8)
            if (!text.contains("PRIVATE KEY")) throw LgInstallException(LgInstallError.KEY_SERVER_OFF, "Key Server anahtar yerine başka bir şey döndü")
            if (LegacyPemKey.isLegacyEncrypted(text)) return LegacyPemKey.decryptWithCaseFallback(text, passphrase.trim()).toByteArray(Charsets.US_ASCII)
            return otherFormat(response, passphrase.trim())
        }

        /**
         * TV'de kurulumu başlatan kabuk komutu (masaüstüyle aynı). `luna-send-pub -i` (ares-install'un biçimi) girişi açık
         * kaldıkça aboneliği sürdürür; giriş `sleep`'ten gelir. Yanıtlar dosyaya yazılır; TV "installed" ya da hata
         * dediğinde, luna-send çıktığında ya da süre dolduğunda yanıtlar basılır ve luna-send kapatılır.
         */
        fun installCommand(remotePackage: String, waitSeconds: Int): String {
            val parameters = """{"id":"com.ares.defaultName","ipkUrl":"$remotePackage","subscribe":true}"""
            return listOf(
                "rm -f $INSTALL_LOG",
                "sleep ${waitSeconds + 30} </dev/null 2>/dev/null | /usr/bin/luna-send-pub -i 'luna://com.webos.appInstallService/dev/install' '$parameters' >$INSTALL_LOG 2>&1 & L=$!",
                "i=0",
                "while [ \$i -lt $waitSeconds ]; do grep -q -i -e '\"state\" *: *\"installed' -e 'failed' -e '\"returnValue\" *: *false' -e '\"state\" *: *\"success' $INSTALL_LOG 2>/dev/null && break; kill -0 \$L 2>/dev/null || break; sleep 1; i=\$((i+1)); done",
                "cat $INSTALL_LOG",
                "kill \$L 2>/dev/null",
                "rm -f $INSTALL_LOG",
            ).joinToString("; ")
        }

        fun launchCommand() = """/usr/bin/luna-send-pub -n 1 'luna://com.webos.applicationManager/launch' '{"id":"$APP_ID"}'"""

        /**
         * Açık uygulamayı kapatır (ares-launch --close gibi) ve webOS'un süreci bırakması için bekler. beta.89 (LG): kurulumdan
         * sonra açık uygulama kapatılmıyordu; açma komutu onu yalnız öne getiriyor, TV eski sürümü çalıştırmayı sürdürüyordu.
         * Masaüstündeki DevModeInstaller.closeCommand ve iPhone'daki LGInstaller.closeCommand ile aynı.
         */
        const val CLOSE_COMMAND = "/usr/bin/luna-send-pub -n 1 'luna://com.webos.applicationManager/closeByAppId' '{\"id\":\"$APP_ID\"}'; sleep 2"

        data class InstallOutcome(val installed: Boolean, val failed: Boolean, val reason: String?)

        /**
         * luna-send'in satır satır JSON yanıtlarını ares-install gibi okur: `returnValue: false` ya da `details.state`
         * içinde FAILED hata, `installed`/`SUCCESS` başarıdır.
         */
        fun parseInstallReplies(output: String): InstallOutcome {
            var pending = ""
            for (line in output.split('\n')) {
                pending += line.trim()
                if (pending.isEmpty()) continue
                if (!pending.startsWith("{")) {
                    pending = ""
                    continue
                }
                val reply = try {
                    JSONObject(pending)
                } catch (error: JSONException) {
                    continue // Satır yarım; sonrakiyle birleşir.
                }
                pending = ""
                val details = reply.optJSONObject("details")
                val state = details?.text("state") ?: ""
                if (reply.has("returnValue") && reply.opt("returnValue") == false)
                    return InstallOutcome(false, true, reason(reply.text("errorText") ?: reply.text("errorMessage"), reply.text("errorCode")))
                if (state.contains("failed", ignoreCase = true))
                    return InstallOutcome(false, true, reason(details?.text("reason") ?: details?.text("errorText") ?: state,
                        details?.text("errorCode") ?: reply.text("errorCode")))
                if (state.contains("installed", ignoreCase = true) || state.startsWith("success", ignoreCase = true))
                    return InstallOutcome(true, false, null)
            }
            return InstallOutcome(false, false, null)
        }

        private fun JSONObject.text(name: String): String? = when (val value = opt(name)) {
            is String -> value
            is Number -> value.toString()
            else -> null
        }

        private fun reason(text: String?, code: String?): String {
            val value = (text ?: "").trim()
            return if (code.isNullOrBlank()) value else "$value (errorCode $code)".trim()
        }

        /** TV ya da kabuk yer kalmadığını mı söylüyor? */
        fun isStorageProblem(text: String) = Regex(
            """no space|not enough (free )?(space|storage)|insufficient (free )?(space|storage)|out of space|storage (is )?full|disk (is )?full|ENOSPC|lack of (space|storage)""",
            RegexOption.IGNORE_CASE).containsMatchIn(text)

        private fun short(text: String) = if (text.length <= 500) text.trim() else text.substring(0, 500).trim() + "…"

        /**
         * TV'nin saati (UTC, saniye). webOS'un kurulum servisi paketi GNU tar ile açar ve tar'ın her uyarısını hata sayar:
         * paketteki dosya tarihleri TV'nin saatine göre gelecekteyse kurulum "ipk verified failed" (errorCode -5) ile
         * reddedilir (LG OLED CX/webOS 5'te ağ saati alınamayınca saat 2020-01-01'e döner). Paket artık tarihleri 2010'a
         * çekilmiş gelir (scripts/normalize-ipk.py); TV'nin saati yine de günlüğe yazılır ve çok gerideyse kullanıcıya
         * saati düzeltmesi söylenir. Mac, iPhone ve Windows'taki komut, eşik ve ayrıntı metniyle aynı.
         */
        const val CLOCK_COMMAND = "date +%s"
        /** TV bu kadar saniyeden fazla geride ise sebep saattir. */
        const val MAX_CLOCK_LAG = 600L

        /** TV paketi doğrulayamadı mı ("ipk verified failed", errorCode -5)? */
        fun isPackageVerifyFailure(text: String) = Regex("""verif|errorCode -5\b""", RegexOption.IGNORE_CASE).containsMatchIn(text)

        /** -5 hatasının ayrıntısı: TV'nin sebebi ve iki saat; saat çok gerideyse `clockWrong`. */
        fun verifyFailureDetail(reason: String, tvClock: String?, nowSeconds: Long): VerifyFailure {
            val tv = tvClock?.trim()?.toLongOrNull() ?: return VerifyFailure(false, "$reason; TV saati okunamadı")
            val lag = nowSeconds - tv
            val side = if (lag >= 0) "$lag sn geride" else "${-lag} sn ileride"
            return VerifyFailure(lag > MAX_CLOCK_LAG, "$reason; TV saati ${utc(tv)} UTC, bu cihaz ${utc(nowSeconds)} UTC (TV $side)")
        }

        private fun utc(seconds: Long): String = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }.format(java.util.Date(seconds * 1000))
    }

    /**
     * Geliştirici modunun 1000 saatlik süresini baştan başlatır (TV'deki Developer Mode uygulamasının EXTEND düğmesi,
     * masaüstündeki DevModeInstaller.renewSession). Kalan saati döner; olmazsa null.
     */
    fun renewSession(timeoutMs: Int = 10_000): Int? {
        val token = shell.run("cat $SESSION_TOKEN", null).output.trim()
        if (token.isEmpty() || token.contains(' ')) return null
        fun get(url: String): String? = try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            try {
                connection.inputStream.use { String(it.readBytes(), Charsets.UTF_8) }
            } finally {
                connection.disconnect()
            }
        } catch (error: IOException) {
            null
        }
        val encoded = java.net.URLEncoder.encode(token, "UTF-8")
        val renewed = get("https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=$encoded") ?: return null
        if (!renewed.contains("success", ignoreCase = true)) return null
        val checked = get("https://developer.lge.com/secure/CheckDevModeSession.dev?sessionToken=$encoded") ?: return null
        return remainingHours(checked)
    }

    /** TV'deki sürüm; uygulama kurulu değilse null. */
    /** TV'deki CouchSubs sürümü; uygulama kurulu değilse ya da bu kimlikle başka bir uygulama kuruluysa null. */
    fun installedVersion(): String? =
        shell.run("cat $APP_INFO", null).output.let { if (isForeignAppInfo(it)) null else versionFromAppInfo(it) }

    /**
     * TV'deki CouchSubs [version]'dan eskiyse ya da yoksa [ipk]'yı kurar, sonra uygulamayı açar.
     * @param replaceForeign Bu kimlikle başka bir uygulama kuruluysa kaldırılıp kurulsun mu (yalnız kullanıcı onayıyla).
     */
    fun ensureInstalled(
        ipk: ByteArray, packageName: String, version: String, replaceForeign: Boolean = false,
        /** TV'de açık uygulamanın bildirdiği sürüm (bağlı değilse null); paket güncel ama bu eskiyse kapatılıp açılır. */
        runningVersion: String? = null,
    ): Result {
        log.write("--- LG kurulumu (telefon) başlıyor: paket $packageName")
        try {
            progress(InstallStep.CONNECTING)
            val appInfo = shell.run("cat $APP_INFO", null).output
            var onTv = versionFromAppInfo(appInfo)
            if (isForeignAppInfo(appInfo)) {
                log.write("TV'de CouchSubs kimliğiyle başka bir uygulama kurulu (sürüm ${onTv ?: "?"}).")
                if (!replaceForeign) throw LgInstallException(LgInstallError.FOREIGN_APP, "appinfo.json başka bir uygulamanın")
                progress(InstallStep.UNINSTALLING)
                log.write("Diğer uygulama kaldırılıyor (kullanıcı onayladı): ${shell.run(REMOVE_COMMAND, null).output.trim()}")
                onTv = null
            }
            log.write("TV'deki CouchSubs: ${onTv ?: "yok"}")
            if (onTv != null && !SamsungDiagnostics.isNewer(version, onTv)) {
                if (runningVersion != null && TvAppRunningCheck.isStale(runningVersion, onTv)) {
                    log.write("TV'deki paket $onTv, çalışan CouchSubs ${runningVersion.ifEmpty { TvAppRunningCheck.UNREPORTED }}; uygulama kapatılıp yeniden açılıyor.")
                    close()
                }
                launch()
                return Result(onTv, false)
            }
            progress(InstallStep.INSTALLING)
            install(ipk, packageName, version)
            log.write("Kurulum tamam.")
            launch()
            return Result(version, true)
        } catch (error: LgInstallException) {
            log.write("HATA ${error.error}: ${error.detail}")
            throw error
        } catch (error: IOException) {
            log.write("Bağlantı koptu: $error")
            throw LgInstallException(LgInstallError.CONNECTION_LOST, error.message ?: error.javaClass.simpleName)
        }
    }

    /**
     * Paketi TV'ye yükler ve ares-install gibi kurar: kurulum aboneliği TV "installed" ya da hata diyene kadar açık kalır,
     * paket ancak bundan sonra silinir. Sürüm appinfo.json'dan doğrulanır.
     */
    fun install(ipk: ByteArray, packageName: String, version: String) {
        val remote = remotePackage(packageName)
        // Önceki denemelerden kalan paketler TV'de yer kaplamasın.
        val upload = shell.run("mkdir -p $TEMP_DIR && rm -f $TEMP_DIR/com.couchsubs.tv_*.ipk $TEMP_DIR/couchsubs.ipk && cat > '$remote'", ipk)
        if (upload.status != 0) throw failure("yükleme çıkış kodu ${upload.status}: ${short(upload.output)}", upload.output)
        // Paket TV'ye eksiksiz ulaştı mı? (wc yoksa ya da çıktı okunamazsa denetim atlanır.)
        val size = shell.run("wc -c < '$remote'", null).output.trim().toLongOrNull()
        if (size != null && size != ipk.size.toLong())
            throw LgInstallException(LgInstallError.INSTALL_FAILED, "paket TV'ye eksik ya da bozuk ulaştı: $size/${ipk.size} bayt")

        val response = shell.run(installCommand(remote, installTimeoutSeconds), null)
        log.write("Kurulum yanıtı (${response.status}):\n${response.output.trim()}")
        val outcome = parseInstallReplies(response.output)
        if (outcome.failed) {
            val reason = outcome.reason?.takeIf { it.isNotBlank() } ?: "kurulum başarısız: ${short(response.output)}"
            // "ipk verified failed" (-5): TV'nin saati okunur ve günlüğe yazılır; çok gerideyse kullanıcıya saati
            // düzeltmesi söylenir (Mac, iPhone ve Windows ile aynı).
            if (isPackageVerifyFailure(reason)) {
                val clock = try { shell.run(CLOCK_COMMAND, null).output } catch (error: IOException) { null }
                remove(remote)
                val result = verifyFailureDetail(reason, clock, System.currentTimeMillis() / 1000)
                log.write("LG paket doğrulaması reddedildi: ${result.detail}")
                throw LgInstallException(if (result.clockWrong) LgInstallError.TV_CLOCK_WRONG else LgInstallError.INSTALL_FAILED, result.detail)
            }
            remove(remote)
            throw failure(reason, response.output)
        }
        val limit = verifyTimeoutMs ?: if (outcome.installed) 30_000L else 60_000L
        val started = System.currentTimeMillis()
        while (true) {
            if (installedVersion() == version) {
                remove(remote)
                // Açık (eski) uygulama kapatılır; sonra açılan uygulama yeni sürümü diskten yükler (bkz. CLOSE_COMMAND).
                close()
                return
            }
            if (System.currentTimeMillis() - started >= limit) break
            Thread.sleep(pollIntervalMs)
        }
        // Sonuç gelmediyse paket silinmez: kurulum TV'de sürüyor olabilir; bir sonraki deneme onu temizler.
        if (outcome.installed) remove(remote)
        throw LgInstallException(LgInstallError.INSTALL_FAILED,
            "TV'de $version sürümü görünmedi; kurulum yanıtı (${response.status}): ${short(response.output)}")
    }

    /** Açık uygulamayı kapatır; açık değilse ya da TV reddederse kurulum yine başarılıdır. */
    fun close() {
        try {
            log.write("TV'deki CouchSubs kapatıldı: ${shell.run(CLOSE_COMMAND, null).output.trim()}")
        } catch (error: IOException) {
            log.write("TV'deki CouchSubs kapatılamadı: ${error.message}")
        }
    }

    /** Kapatır ve yeniden açar (çalışan sürüm kurulu sürümden eskiyse). */
    fun restart() {
        close()
        launch()
    }

    /** Uygulamayı açar (ares-launch gibi); açılmasa da kurulum başarılıdır. */
    private fun launch() {
        progress(InstallStep.LAUNCHING)
        try {
            log.write("Uygulama açılıyor: ${shell.run(launchCommand(), null).output.trim()}")
        } catch (error: IOException) {
            log.write("Uygulama açılamadı (kurulum yine tamam): ${error.message}")
        }
    }

    private fun failure(detail: String, evidence: String) = LgInstallException(
        if (isStorageProblem(evidence) || isStorageProblem(detail)) LgInstallError.NOT_ENOUGH_SPACE else LgInstallError.INSTALL_FAILED, detail)

    private fun remove(remote: String) {
        try {
            shell.run("rm -f '$remote'", null)
        } catch (error: IOException) {
            // Geçici dosya kalabilir.
        }
    }
}
