// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki AndroidTvInstaller.cs'in (windows/src/CouchSubs.TvInstall/Android) telefon karşılığı. Fark: TV'deki
// kopya başka imzalıysa (Google Play'den kurulmuş) kendiliğinden kaldırılmaz; kullanıcı onaylarsa kaldırılır.
package com.couchsubs.mobile.tv.android

import com.couchsubs.mobile.tv.samsung.AdbKey
import com.couchsubs.mobile.tv.samsung.InstallLog
import com.couchsubs.mobile.tv.samsung.InstallStep
import com.couchsubs.mobile.tv.samsung.SamsungDiagnostics
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * CouchSubs'ın Android TV uygulamasını (com.couchsubs.tv) ağ üzerinden kurar. TV'de geliştirici seçenekleri ve
 * USB/ağ hata ayıklaması açık olmalıdır (çoğu Android TV 5555 portunda ADB bekler); Android 11 ve sonrasında
 * kablosuz hata ayıklama da olur: önce eşleme kodu ile eşlenir, sonra ekranda yazan portla bağlanılır.
 *
 * @param pairing Kablosuz hata ayıklama: eşleme portu ve TV'nin gösterdiği 6 haneli kod; verilirse önce eşlenir.
 */
class AndroidTvInstaller(
    private val host: String,
    private val port: Int,
    private val adbKey: () -> AdbKey,
    private val pairing: Pairing? = null,
    private val progress: (InstallStep) -> Unit = {},
    private val log: InstallLog = InstallLog(null),
    private val connector: (AdbKey, () -> Unit) -> AdbConnection = { key, approve -> AdbConnection.connect(host, port, key, approve) },
    private val pairer: (AdbKey, Pairing) -> Unit = { key, pair -> AdbPairing.pair(host, pair.port, pair.code, key) },
    /** CouchSubs TV Google Play'de herkese açık mı? Açıksa ve TV'de Play Store varsa uygulama Play'den kurulur. */
    private val playListed: () -> Boolean = { false },
    private val playWaitMs: Long = 4 * 60 * 1000L,
    private val playPollMs: Long = 3_000L,
    /** Uygulama açılırken verilecek başlatma parametreleri (`{"server":"http://…"}`); TV telefonu ağda aramadan bağlanır. */
    private val launchParams: String? = null,
) {
    data class Pairing(val port: Int, val code: String)
    data class Result(val version: String, val installed: Boolean)

    companion object {
        const val PACKAGE_NAME = "com.couchsubs.tv"
        private const val PLAY_STORE = "com.android.vending"
        private const val TEMP_APK = "/data/local/tmp/couchsubs-tv.apk"

        private val versionName = Regex("""versionName=(\S+)""")
        private val installerName = Regex("""installerPackageName=(\S+)""")

        fun versionFromDumpsys(output: String): String? = versionName.find(output)?.groupValues?.get(1)

        private val userInstalled = Regex("""^\s*User (\d+):.*?\binstalled=(true|false)\b""", RegexOption.MULTILINE)

        /** dumpsys'teki kullanıcı satırları: kullanıcı numarası -> kurulu mu. */
        private fun usersFromDumpsys(output: String): Map<String, Boolean> =
            userInstalled.findAll(output).associate { it.groupValues[1] to (it.groupValues[2] == "true") }

        /**
         * dumpsys sürüm söylüyor ama uygulama TV'nin ana kullanıcısında (User 0) kurulu değil: TV'den kaldırılan
         * uygulamanın kaydı kalmış (veri saklanarak kaldırma, arşivleme; #352, #389) ya da TV uygulamayı yalnız ana
         * kullanıcıdan kaldırmış, çocuk/ikincil profilde kurulu kalmış (#528). Önceden "kurulu" sayılıyor, kurulum
         * atlanıyor, `am start` hata veriyordu. Kullanıcı satırı yoksa (eski Android) kalıntı sayılmaz.
         * Masaüstündeki AndroidTvApp.IsLeftover ile aynıdır.
         */
        fun isLeftover(output: String): Boolean {
            if (versionFromDumpsys(output) == null) return false
            val users = usersFromDumpsys(output)
            if (users.isEmpty()) return false
            return users["0"] == false || users.values.none { it }
        }

        /** Kalıntı ama APK başka bir profilde kurulu: `pm install-existing --user 0` ile APK göndermeden geri getirilir (#528). */
        fun canInstallExisting(output: String): Boolean = isLeftover(output) && usersFromDumpsys(output).values.any { it }

        const val INSTALL_EXISTING_COMMAND = "shell:pm install-existing --user 0 $PACKAGE_NAME"

        /** `pm install-existing` başarılı mı ("Package com.couchsubs.tv installed for user: 0")? */
        fun installExistingSucceeded(output: String): Boolean = output.contains("installed for user")

        /** TV'de kurulu CouchSubs sürümü; yoksa ya da yalnız kaydı kalmışsa null. */
        fun installedVersionFromDumpsys(output: String): String? = versionFromDumpsys(output)?.takeUnless { isLeftover(output) }

        const val PLAY_URL = "https://play.google.com/store/apps/details?id=$PACKAGE_NAME"
        const val OPEN_PLAY_COMMAND = "shell:am start -a android.intent.action.VIEW -d market://details?id=$PACKAGE_NAME"

        /** Play sayfası herkese açık mı (200)? Ağ yoksa ya da sayfa yoksa false. */
        fun isListedOnPlay(timeoutMs: Int = 5_000): Boolean = try {
            val connection = java.net.URL(PLAY_URL).openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = true
            try {
                connection.responseCode == 200
            } finally {
                connection.disconnect()
            }
        } catch (error: IOException) {
            false
        }

        /** `pm list packages com.android.vending` çıktısında Play Store var mı? */
        fun hasPlayStore(output: String) = output.lineSequence().any { it.trim() == "package:$PLAY_STORE" }

        /** Paket Google Play'den mi kurulmuş (Play'in imzası telefondakinden farklıdır)? */
        fun installedFromPlay(output: String) = installerName.find(output)?.groupValues?.get(1) == PLAY_STORE

        /** appops ve pm başarıda bir şey yazmaz; hata metni döner. */
        fun looksFailed(output: String) = listOf("Error", "Exception", "Unknown", "not allowed").any { output.contains(it, ignoreCase = true) }

        /** TV'deki kopya başka imzalı ya da daha yeni sürüm kodlu: kaldırılmadan bu paket kurulamaz. */
        fun needsReplace(output: String) =
            output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || output.contains("INSTALL_FAILED_VERSION_DOWNGRADE")

        fun isStorageProblem(output: String) =
            output.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") || output.contains("No space left", ignoreCase = true)

        /** `cmd package` yok (Android 7 öncesi) ya da `exec:` hizmeti yok: dosya gönderilip `pm install` ile kurulur. */
        fun streamInstallUnsupported(output: String) = !output.contains("Success") && !output.contains("Failure")

        /** "192.168.1.5:37123" → (adres, port); port yoksa [defaultPort]. */
        fun parseAddress(text: String, defaultPort: Int = AdbConnection.DEFAULT_PORT): Pair<String, Int>? {
            val value = text.trim()
            if (value.isEmpty()) return null
            val colon = value.lastIndexOf(':')
            if (colon < 0) return value to defaultPort
            val port = value.substring(colon + 1).toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val address = value.substring(0, colon).trim()
            return if (address.isEmpty()) null else address to port
        }

        /** Uygulamayı açan ADB komutu; [launchParams] varsa `--es params '…'` ile (Windows'taki StartCommand ile aynı kural). */
        fun startCommand(launchParams: String?): String {
            val command = "shell:am start -n $PACKAGE_NAME/.MainActivity"
            // TV'de sh çalıştırır: değer tek tırnak içinde gider; tek tırnak ve satır sonu içeren değer hiç gönderilmez.
            if (launchParams.isNullOrEmpty() || launchParams.any { it == '\'' || it == '\n' || it == '\r' || it == '\u0000' }) return command
            return "$command --es params '$launchParams'"
        }

        /**
         * TV'de çalışan CouchSubs'a adresi bildiren yayın (TV uygulamasındaki AddressReceiver): ekranı öne çekmez, görüntü
         * modunu değiştirmez. Parametre yoksa ya da kabukta güvenle gönderilemiyorsa null (Windows'taki AddressCommand ile aynı).
         */
        fun addressCommand(launchParams: String?): String? {
            if (launchParams.isNullOrEmpty() || launchParams.any { it == '\'' || it == '\n' || it == '\r' || it == '\u0000' }) return null
            return "shell:am broadcast -a $PACKAGE_NAME.action.ADDRESS -n $PACKAGE_NAME/.AddressReceiver --es params '$launchParams'"
        }

        /**
         * CouchSubs TV çalışıyor mu: etkinlik yığınlarındaki kayıtlar (ekran arka planda olsa da yığındadır) ve paketin
         * servisleri (katman). Windows'taki RunningCommand ve Mac/iPhone'daki AndroidTVApp.runningCommand ile aynı.
         */
        const val RUNNING_COMMAND = "shell:dumpsys activity activities | grep Hist; dumpsys activity services $PACKAGE_NAME | grep ServiceRecord"

        /** Uygulama zaten açıkken [open]'ın döndürdüğü sonuç (`am start` gönderilmedi). */
        const val ALREADY_RUNNING = "zaten açık"

        /**
         * [RUNNING_COMMAND] çıktısında CouchSubs TV'nin ekranı ya da katman servisi var mı. Boş ya da tanınmayan çıktı (çok
         * eski TV'de `grep` yok) çalışmıyor sayılır: eski yol, bekçinin açma sınırı yine geçerli.
         */
        fun isRunning(output: String): Boolean = output.lineSequence().any { line ->
            ((line.contains("Hist") && line.contains("ActivityRecord{")) || line.contains("ServiceRecord{")) &&
                line.contains("$PACKAGE_NAME/")
        }

        /**
         * Yalnız sunucu adresi gider; erişim anahtarı gitmez (Android TV kullanıcı onaylı eşleştirmeyle bağlanır). Adres
         * tırnak ya da ters bölü içeriyorsa null.
         */
        fun launchParams(server: String): String? =
            if (server.isEmpty() || server.any { it == '"' || it == '\\' || it < ' ' }) null else "{\"server\":\"$server\"}"

        /** TV'de ADB açık mı (port yanıt veriyor mu)? */
        fun isReachable(host: String, port: Int = AdbConnection.DEFAULT_PORT, timeoutMs: Int = 700): Boolean = try {
            Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
            true
        } catch (error: IOException) {
            false
        }

        /**
         * "Diğer uygulamaların üzerinde göster" izni: katman modunda altyazı TV'nin kendi HDMI ekranının üstünde çizilir.
         * Android TV'de bu ayar çoğu zaman menüde yoktur; ADB ile verilir. Verilemezse kurulum yine başarılıdır.
         */
        internal fun grantOverlay(adb: AdbConnection, log: InstallLog): Boolean = try {
            var output = adb.run("shell:appops set $PACKAGE_NAME SYSTEM_ALERT_WINDOW allow")
            if (looksFailed(output)) output = adb.run("shell:pm grant $PACKAGE_NAME android.permission.SYSTEM_ALERT_WINDOW")
            (!looksFailed(output)).also { log.write("Üstte gösterme izni: ${if (it) "verildi" else "verilemedi (${output.trim()})"}") }
        } catch (error: IOException) {
            log.write("Üstte gösterme izni verilemedi: ${error.message}")
            false
        }
    }

    /**
     * Uygulama eksikse ya da eskiyse kurar ve açar; hepsi tek bağlantıda yapılır, TV onayı en çok bir kez sorulur.
     * @param allowReplace TV'deki kopya başka imzalıysa kaldırılıp kurulsun mu (kullanıcı onayıyla).
     */
    fun ensureInstalled(apk: () -> ByteArray, version: String?, allowReplace: Boolean = false): Result {
        log.write("--- Android TV kurulumu (telefon) başlıyor: TV $host:$port, paket $version${if (pairing != null) ", eşleme portu ${pairing.port}" else ""}")
        try {
            return installCore(apk, version, allowReplace).also {
                log.write(if (it.installed) "Kurulum tamam." else "TV'de ${it.version} sürümü var; kurulum gerekmedi.")
            }
        } catch (error: AndroidInstallException) {
            log.write("HATA ${error.error}: ${error.detail}")
            throw error
        } catch (error: IOException) {
            log.write("Bağlantı koptu: $error")
            throw AndroidInstallException(AndroidInstallError.CONNECTION_LOST, error.message ?: error.javaClass.simpleName)
        }
    }

    /**
     * Yalnız TV'deki CouchSubs sürümünü okur (kurmaz, açmaz); uygulama yoksa null. Güncelleme denetimi için: TV bu
     * telefonu onaylamamışsa onay beklenmez, NOT_APPROVED ile vazgeçilir.
     */
    fun installedVersion(): String? {
        val key = adbKey()
        return connector(key) { throw AndroidInstallException(AndroidInstallError.NOT_APPROVED, "denetimde onay beklenmez") }.use { adb ->
            installedVersionFromDumpsys(adb.run("shell:dumpsys package $PACKAGE_NAME"))
        }
    }

    /**
     * Kurulu uygulamayı telefonun adresiyle açar (kurmadan, sessizce): TV telefonu ağda aramadan bağlanır. TV bu telefonu
     * onaylamamışsa onay beklenmez, NOT_APPROVED ile vazgeçilir. Uygulama TV'de zaten çalışıyorsa (ekranı önde ya da
     * arkada, ya da katmanı) `am start` gönderilmez, [ALREADY_RUNNING] döner: `am start` çalışan uygulamayı öne çekiyor,
     * TV uygulaması da parametreli açılışta katmana dönüp ekranı kapatıyordu (X, Android TV 8, beta.74; Windows ve iPhone'la
     * aynı).
     */
    fun open(params: String? = launchParams): String {
        val key = adbKey()
        return connector(key) { throw AndroidInstallException(AndroidInstallError.NOT_APPROVED, "açılışta onay beklenmez") }.use { adb ->
            val running = try { adb.run(RUNNING_COMMAND) } catch (_: IOException) { "" }
            if (isRunning(running)) {
                // Çalışan uygulama telefona bağlı değil (bekçi yalnız o zaman açar): kayıtlı eski bir adrese bağlı kalmış
                // olabilir. Adres ekranı öne çekmeden bildirilir (TV 0.9.63+; eski TV uygulaması yok sayar).
                addressCommand(params)?.let { command -> try { adb.run(command) } catch (_: IOException) { } }
                ALREADY_RUNNING
            } else adb.run(startCommand(params)).trim()
        }
    }

    private fun installCore(apk: () -> ByteArray, version: String?, allowReplace: Boolean): Result {
        val key = adbKey()
        pairing?.let {
            progress(InstallStep.PAIRING)
            pairer(key, it)
            log.write("Eşleme tamam (port ${it.port}).")
        }
        progress(InstallStep.CONNECTING)
        connector(key) {
            log.write("TV bu telefonu ilk kez görüyor; onay bekleniyor.")
            progress(InstallStep.APPROVE_ON_TV)
        }.use { adb ->
            log.write("ADB bağlantısı kuruldu (${if (adb.secure) "TLS" else "düz"}, en çok ${adb.maxData} bayt).")
            progress(InstallStep.READING)
            var dumpsys = adb.run("shell:dumpsys package $PACKAGE_NAME")
            if (canInstallExisting(dumpsys)) {
                // TV uygulamayı yalnız ana kullanıcıdan kaldırmış, başka profilde duruyor: APK göndermeden geri getirilir (#528).
                val existing = runCatching { adb.run(INSTALL_EXISTING_COMMAND) }.getOrDefault("")
                log.write("CouchSubs TV başka bir profilde kurulu; ana kullanıcıya geri getiriliyor: ${existing.trim()}")
                if (installExistingSucceeded(existing)) dumpsys = adb.run("shell:dumpsys package $PACKAGE_NAME")
            }
            val installed = installedVersionFromDumpsys(dumpsys)
            val fromPlay = installedFromPlay(dumpsys)
            if (isLeftover(dumpsys)) log.write("TV'de CouchSubs'ın kaydı kalmış ama uygulama kurulu değil; yeniden kuruluyor.")
            log.write("TV'deki CouchSubs: ${installed ?: "yok"}${if (fromPlay) " (Google Play'den)" else ""}")
            if (installed != null && version != null && !SamsungDiagnostics.isNewer(version, installed)) {
                grantOverlay(adb, log)
                launch(adb)
                return Result(installed, false)
            }

            // CouchSubs TV Play'de ve TV'de Play Store varsa uygulama Play'den kurulur/güncellenir (Play kopyası
            // kendiliğinden güncel kalır). Kullanıcı Play sayfasında Yükle'ye basmazsa APK ile kurulur.
            installFromPlay(adb, installed, fromPlay)?.let { return it }

            progress(InstallStep.INSTALLING)
            val bytes = apk()
            var output = install(adb, bytes)
            if (needsReplace(output)) {
                if (!allowReplace) throw AndroidInstallException(AndroidInstallError.REPLACE_NEEDED, output.trim(), fromPlay)
                progress(InstallStep.UNINSTALLING)
                log.write("Eski kopya kaldırılıyor (kullanıcı onayladı): ${adb.run("shell:pm uninstall $PACKAGE_NAME").trim()}")
                progress(InstallStep.INSTALLING)
                output = install(adb, bytes)
            }
            if (!output.contains("Success")) {
                val error = if (isStorageProblem(output)) AndroidInstallError.NOT_ENOUGH_SPACE else AndroidInstallError.INSTALL_FAILED
                throw AndroidInstallException(error, output.trim().ifEmpty { "TV yanıt vermedi" })
            }
            grantOverlay(adb, log)
            val after = installedVersionFromDumpsys(adb.run("shell:dumpsys package $PACKAGE_NAME"))
            launch(adb)
            return Result(after ?: version ?: "", true)
        }
    }

    /**
     * TV'de Play sayfasını açar ve kurulmasını (ya da güncellenmesini) bekler; olunca izin verip uygulamayı açar. Play
     * yolu yoksa, sayfa açılmazsa ya da süre dolarsa null: APK ile kurulur.
     */
    private fun installFromPlay(adb: AdbConnection, before: String?, fromPlay: Boolean): Result? {
        if (!playListed()) return null
        if (!fromPlay && !hasPlayStore(runCatching { adb.run("shell:pm list packages $PLAY_STORE") }.getOrDefault(""))) {
            log.write("TV'de Play Store yok; APK ile kuruluyor.")
            return null
        }
        val opened = adb.run(OPEN_PLAY_COMMAND)
        log.write("Play sayfası açılıyor: ${opened.trim()}")
        if (opened.contains("Error", ignoreCase = true)) return null
        progress(InstallStep.OPEN_PLAY)
        val deadline = System.currentTimeMillis() + playWaitMs
        while (System.currentTimeMillis() < deadline) {
            Thread.sleep(playPollMs)
            val now = installedVersionFromDumpsys(adb.run("shell:dumpsys package $PACKAGE_NAME"))
            if (now != null && now != before) {
                log.write("Play'den kuruldu: $now")
                grantOverlay(adb, log)
                launch(adb)
                return Result(now, true)
            }
        }
        log.write("Play'den ${playWaitMs / 1000} sn içinde kurulmadı; APK ile kuruluyor.")
        return null
    }

    /** Android 7 ve sonrası: dosya ayrıca kopyalanmadan paket yöneticisine akıtılır; olmazsa gönderilip `pm install`. */
    private fun install(adb: AdbConnection, apk: ByteArray): String {
        val streamed = try {
            adb.run("exec:cmd package install -r -S ${apk.size}", apk)
        } catch (error: IOException) {
            if (error is AndroidInstallException) throw error
            "exec: ${error.message}"
        }
        log.write("cmd package install çıktısı: ${streamed.trim()}")
        if (!streamInstallUnsupported(streamed)) return streamed
        adb.push(apk, TEMP_APK)
        val output = adb.run("shell:pm install -r $TEMP_APK")
        log.write("pm install çıktısı: ${output.trim()}")
        runCatching { adb.run("shell:rm -f $TEMP_APK") }
        return output
    }

    /** Uygulamayı açar; açılmasa da kurulum başarılıdır. */
    private fun launch(adb: AdbConnection) {
        progress(InstallStep.LAUNCHING)
        try {
            log.write("Uygulama açılıyor: ${adb.run(startCommand(launchParams)).trim()}")
        } catch (error: IOException) {
            log.write("Uygulama açılamadı (kurulum yine tamam): ${error.message}")
        }
    }
}
