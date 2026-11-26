// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki AndroidTvInstaller.cs'in (windows/src/CouchSubs.TvInstall/Android) telefon karşılığı. Fark: TV'deki
// kopya başka imzalıysa (Google Play'den kurulmuş) kendiliğinden kaldırılmaz; kullanıcı onaylarsa kaldırılır.
package com.couchsubs.mobile.tv.android

import com.couchsubs.mobile.tv.TvStall
import com.couchsubs.mobile.tv.TvStepTimeoutException
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
    progress: (InstallStep) -> Unit = {},
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

    private val report = progress

    /** Adımların süreleri (ms; testlerde kısaltılır); verilmezse [TvStall.limitFor]. */
    var stallLimits: (String) -> Long? = { TvStall.limitFor(it) }

    /** Sürmekte olan denemenin bekçisi. */
    private var stall: TvStall? = null

    /** Bu çağrıda eşleme yapıldı (eşleme kodu tek kullanımlık: ikinci denemede yeniden eşlenmez). */
    private var paired = false

    /** Bu çağrıda APK kuruldu (ikinci deneme güncel bulsa da "kuruldu" sayılır). */
    private var installCompleted = false

    /** Yeni adım: bekçinin süresi baştan başlar, arayüz adımı yazar. */
    private fun step(step: InstallStep) {
        stall?.enter(step)
        report(step)
    }

    /** Kibar kapanma isteğinden sonra uygulamanın kapanması için beklenen süre (testlerde kısaltılır). */
    internal var exitWaitMs = EXIT_WAIT_MS

    /**
     * Çalışan uygulamayı kapatır (#1221): önce kendisinden kapanmasını ister ([EXIT_COMMAND]; HDMI girişini bırakır),
     * [exitWaitMs] bekler, hâlâ çalışıyorsa (ya da bilinemiyorsa) `am force-stop`. Eskiden doğrudan `am force-stop`
     * gönderiliyordu; MediaTek'li Philips Google TV'lerde bırakılmayan HDMI TV kapatılıp açılana kadar siyah kalıyordu.
     * Günlüğe yazılacak sonucu döner. Windows/Mac (AndroidTvInstaller.StopAppAsync) ve iPhone (stopApp) ile aynı.
     */
    private fun stopApp(adb: AdbConnection): String {
        val exit = runCatching { adb.run(EXIT_COMMAND).trim() }.getOrElse { it.message ?: "?" }
        if (exitWaitMs > 0) Thread.sleep(exitWaitMs)
        val after = try { adb.run(RUNNING_COMMAND) } catch (_: IOException) { "" }
        if (!needsForceStop(after)) return "kapanma isteğiyle kapandı ($exit)"
        val forced = runCatching { adb.run(FORCE_STOP_COMMAND).trim() }.getOrElse { it.message ?: "?" }
        return "kapanma isteğinden ${exitWaitMs} ms sonra hâlâ çalışıyordu; am force-stop ($forced)"
    }

    companion object {
        const val PACKAGE_NAME = "com.couchsubs.tv"

        /** Çalışan uygulamayı kapatan komut (Windows/Mac ForceStopCommand, iPhone forceStopCommand ile aynı). */
        const val FORCE_STOP_COMMAND = "shell:am force-stop $PACKAGE_NAME"

        /**
         * Uygulamadan kendisinin kapanmasını isteyen komut (TV 0.9.114+: MainActivity EXTRA_EXIT → HDMI bırakılır, ekran
         * ve katman kapanır). Eski TV uygulaması bunu sıradan açılış sayar; o zaman [FORCE_STOP_COMMAND] gönderilir.
         * Windows/Mac ExitCommand ve iPhone exitCommand ile aynı.
         */
        const val EXIT_COMMAND = "shell:am start -n $PACKAGE_NAME/.MainActivity --ez exit true"

        /** Kapanma isteğinden sonra `am force-stop`'a kadar beklenen süre. */
        const val EXIT_WAIT_MS = 1_500L

        /**
         * Kapanma isteğinden sonraki [RUNNING_COMMAND] çıktısına göre `am force-stop` gerekiyor mu: uygulama hâlâ
         * görünüyorsa ya da çıktı okunamıyorsa (boş, `grep` yok: yığın satırı hiç yok) evet.
         */
        fun needsForceStop(runningOutput: String): Boolean = isRunning(runningOutput) || !runningOutput.contains("Hist")

        /** Takılma ya da bağlantı kopması: yeni bağlantıyla bir kez daha denenir. */
        fun isRetryable(error: Exception): Boolean = when (error) {
            is TvStepTimeoutException -> true
            is AndroidInstallException -> error.error == AndroidInstallError.CONNECTION_LOST
            is IOException -> true
            else -> false
        }
        private const val PLAY_STORE = "com.android.vending"
        private const val TEMP_APK = "/data/local/tmp/couchsubs-tv.apk"

        private val versionName = Regex("""versionName=(\S+)""")
        private val installerName = Regex("""installerPackageName=(\S+)""")

        fun versionFromDumpsys(output: String): String? = versionName.find(output)?.groupValues?.get(1)

        /**
         * Bizim TV imza sertifikamızın (CN=CouchSubs TV, O=Enmera; SHA-256 5FFE122E…D0D5FB) dumpsys'te görünen özeti:
         * Android Signature.hashCode() (sertifikanın DER baytları üzerinde Arrays.hashCode) Integer.toHexString ile. Play'in
         * uygulama imza anahtarı da aynı anahtardır (tv-android/app/build.gradle).
         */
        const val SIGNATURE_HASH = "32d37cf9"

        /**
         * dumpsys'teki imza özetleri: `signatures=PackageSignatures{…` satırındaki ilk `[...]`. Yeni biçim
         * `PackageSignatures{a1b2c3 version:2, signatures:[32d37cf9], past signatures:[]}`, eski biçim
         * `PackageSignatures{41ab21 [32d37cf9]}`. Satır yoksa boş liste.
         */
        fun signatureHashes(output: String): List<String> {
            val line = output.lineSequence().firstOrNull { it.contains("signatures=PackageSignatures{") } ?: return emptyList()
            val open = line.indexOf('[')
            val close = if (open < 0) -1 else line.indexOf(']', open)
            if (close < 0) return emptyList()
            return line.substring(open + 1, close).split(',').map { it.trim() }.filter { it.isNotEmpty() }
        }

        /** TV'deki kopya bizim anahtarımızla imzalı mı (özet okunabildi ve bizimki). */
        fun isOurs(output: String): Boolean = signatureHashes(output).any { it.equals(SIGNATURE_HASH, ignoreCase = true) }

        /**
         * TV'de bu kimlikle başka bir uygulama mı kurulu: sürüm var, imza özeti okunabildi ve bizimki değil. Okunamazsa
         * bizim sayılır (Windows, Mac ve iPhone ile aynı kural); o zaman TV'nin imza hatası aynı onaya götürür.
         */
        fun isForeign(output: String): Boolean =
            versionFromDumpsys(output) != null && signatureHashes(output).let { it.isNotEmpty() && it.none { hash -> hash.equals(SIGNATURE_HASH, ignoreCase = true) } }

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
     * @param allowReplace TV'deki kopya başka imzalıysa ya da bu kimlikle başka bir uygulama kuruluysa kaldırılıp kurulsun
     *   mu (yalnız kullanıcı onayıyla; masaüstündeki replaceForeign).
     */
    fun ensureInstalled(apk: () -> ByteArray, version: String?, allowReplace: Boolean = false): Result =
        // Aynı TV'de kurulum zaten sürüyorsa yenisi başlatılmaz, sürenin sonucu döner; bekçinin açma denemesi kurulum bitene
        // kadar bekler (#1223; TvLane, Windows, Mac ve iPhone ile aynı).
        lane.install(host, log::write) { ensureInstalledNow(apk, version, allowReplace) }

    /** Aynı TV'nin ADB işlemlerini sıraya koyan kanal (testlerde ayrı kanal verilir). */
    internal var lane: com.couchsubs.mobile.tv.TvLane = com.couchsubs.mobile.tv.TvLane.shared

    private fun ensureInstalledNow(apk: () -> ByteArray, version: String?, allowReplace: Boolean): Result {
        log.write("--- Android TV kurulumu (telefon) başlıyor: TV $host:$port, paket $version${if (pairing != null) ", eşleme portu ${pairing.port}" else ""}")
        paired = false
        installCompleted = false
        try {
            // Her adımın süre sınırı var (TvStall); takılırsa ya da bağlantı koparsa yeni bağlantıyla bir kez daha denenir.
            val found = TvStall.retryOnce(log::write, { isRetryable(it) }) {
                val watch = TvStall(stallLimits)
                stall = watch
                try { watch.run { installCore(apk, version, allowReplace) } } finally { stall = null }
            }
            return Result(found.version, found.installed || installCompleted).also {
                log.write(if (it.installed) "Kurulum tamam." else "TV'de ${it.version} sürümü var; kurulum gerekmedi.")
            }
        } catch (error: TvStepTimeoutException) {
            log.write("HATA ${AndroidInstallError.CONNECTION_LOST}: ${error.gaveUp}")
            throw AndroidInstallException(AndroidInstallError.CONNECTION_LOST, error.gaveUp)
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
    fun installedVersion(): String? = lane.run(host, "sürüm denetimi", log::write) {
        val key = adbKey()
        connector(key) { throw AndroidInstallException(AndroidInstallError.NOT_APPROVED, "denetimde onay beklenmez") }.use { adb ->
            // Bu kimlikle başka bir uygulama kuruluysa CouchSubs yok sayılır (denetim hiçbir şeyi kaldırmaz).
            adb.run("shell:dumpsys package $PACKAGE_NAME").let { if (isForeign(it)) null else installedVersionFromDumpsys(it) }
        }
    }

    /**
     * Kurulu uygulamayı telefonun adresiyle açar (kurmadan, sessizce): TV telefonu ağda aramadan bağlanır. TV bu telefonu
     * onaylamamışsa onay beklenmez, NOT_APPROVED ile vazgeçilir. Uygulama TV'de zaten çalışıyorsa (ekranı önde ya da
     * arkada, ya da katmanı) `am start` gönderilmez, [ALREADY_RUNNING] döner: `am start` çalışan uygulamayı öne çekiyor,
     * TV uygulaması da parametreli açılışta katmana dönüp ekranı kapatıyordu (X, Android TV 8, beta.74; Windows ve iPhone'la
     * aynı).
     */
    fun open(params: String? = launchParams, restart: Boolean = false): String =
        // [restart]: uygulama çalışıyor olsa da kapatılıp (`am force-stop`) temiz açılır: bekçi uygulamayı çalışırken buldu
        // ama uygulama 10 sn'de bağlanmadı (TvSessionLauncher.openAndroidTv; Samsung'daki #1248 ile aynı). Aynı TV'de kurulum ya
        // da başka bir ADB oturumu sürüyorsa sırası beklenir (#1223; TvLane).
        lane.run(host, if (restart) "kapatıp açma" else "açma", log::write) { openNow(params, restart) }

    /** Uygulamayı kapatır ([stopApp]: kapanma isteği, gerekirse `am force-stop`) ve temiz açar (`am start`); `am start` çıktısı döner. */
    private fun restartOn(adb: AdbConnection, params: String?): String {
        log.write("Android TV uygulaması kapatılıyor: ${stopApp(adb)}")
        return adb.run(startCommand(params)).trim()
    }

    private fun openNow(params: String?, restart: Boolean): String {
        val key = adbKey()
        return connector(key) { throw AndroidInstallException(AndroidInstallError.NOT_APPROVED, "açılışta onay beklenmez") }.use { adb ->
            if (restart) return@use restartOn(adb, params)
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
        pairing?.takeUnless { paired }?.let {
            step(InstallStep.PAIRING)
            pairer(key, it)
            paired = true
            log.write("Eşleme tamam (port ${it.port}).")
        }
        step(InstallStep.CONNECTING)
        connector(key) {
            log.write("TV bu telefonu ilk kez görüyor; onay bekleniyor.")
            step(InstallStep.APPROVE_ON_TV)
        }.use { adb ->
            // Takılınca bağlantı kapatılır: bekleyen okuma hatayla döner.
            stall?.onStall { adb.close() }
            log.write("ADB bağlantısı kuruldu (${if (adb.secure) "TLS" else "düz"}, en çok ${adb.maxData} bayt).")
            step(InstallStep.READING)
            var dumpsys = adb.run("shell:dumpsys package $PACKAGE_NAME")
            // Bu kimlikle başka imzalı bir uygulama: sürüme bakılmadan, Play'e ve kalıntı temizliğine geçilmeden önce sorulur.
            if (isForeign(dumpsys)) {
                log.write("TV'de CouchSubs kimliğiyle başka bir uygulama kurulu (sürüm ${versionFromDumpsys(dumpsys)}, imza ${signatureHashes(dumpsys).joinToString()}).")
                if (!allowReplace) throw AndroidInstallException(AndroidInstallError.FOREIGN_APP, "imza ${signatureHashes(dumpsys).joinToString()}")
                step(InstallStep.UNINSTALLING)
                log.write("Diğer uygulama kaldırılıyor (kullanıcı onayladı): ${adb.run("shell:pm uninstall $PACKAGE_NAME").trim()}")
                dumpsys = adb.run("shell:dumpsys package $PACKAGE_NAME")
            }
            if (canInstallExisting(dumpsys)) {
                // TV uygulamayı yalnız ana kullanıcıdan kaldırmış, başka profilde duruyor: APK göndermeden geri getirilir (#528).
                val existing = runCatching { adb.run(INSTALL_EXISTING_COMMAND) }.getOrDefault("")
                log.write("CouchSubs TV başka bir profilde kurulu; ana kullanıcıya geri getiriliyor: ${existing.trim()}")
                if (installExistingSucceeded(existing)) dumpsys = adb.run("shell:dumpsys package $PACKAGE_NAME")
            }
            val installed = installedVersionFromDumpsys(dumpsys)
            val fromPlay = installedFromPlay(dumpsys)
            val ours = isOurs(dumpsys)
            if (isLeftover(dumpsys)) log.write("TV'de CouchSubs'ın kaydı kalmış ama uygulama kurulu değil; yeniden kuruluyor.")
            log.write("TV'deki CouchSubs: ${installed ?: "yok"}${if (fromPlay) " (Google Play'den)" else ""}")
            // Unknown signatures must not make another app with this package name appear up to date.
            if (installed != null && ours && version != null && !SamsungDiagnostics.isNewer(version, installed)) {
                grantOverlay(adb, log)
                launch(adb)
                return Result(installed, false)
            }

            // CouchSubs TV Play'de ve TV'de Play Store varsa uygulama Play'den kurulur/güncellenir (Play kopyası
            // kendiliğinden güncel kalır). Kullanıcı Play sayfasında Yükle'ye basmazsa APK ile kurulur.
            installFromPlay(adb, installed, fromPlay)?.let { return it }

            // Güncellemede TV'de çalışan eski uygulama önce kapatılır; kurulumdan sonra temiz açılır.
            if (installed != null) {
                stall?.enter("closing")
                log.write("Güncellemeden önce eski uygulama kapatılıyor: ${stopApp(adb)}")
            }
            step(InstallStep.INSTALLING)
            val bytes = apk()
            var output = install(adb, bytes)
            if (needsReplace(output)) {
                // İmza tutmuyor (ya da imzası doğrulanamayan kopya daha yeni): başka bir uygulama olabilir, aynı onay sorulur.
                // Yalnız imzası bizim olduğu bilinen kopyanın sürüm düşürmesinde eski "kopyayı kaldırıp kur" önerisi kalır.
                if (!allowReplace) {
                    val error = if (ours && !output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE")) AndroidInstallError.REPLACE_NEEDED
                    else AndroidInstallError.FOREIGN_APP
                    throw AndroidInstallException(error, output.trim(), fromPlay)
                }
                step(InstallStep.UNINSTALLING)
                log.write("Eski kopya kaldırılıyor (kullanıcı onayladı): ${adb.run("shell:pm uninstall $PACKAGE_NAME").trim()}")
                step(InstallStep.INSTALLING)
                output = install(adb, bytes)
            }
            if (!output.contains("Success")) {
                val error = if (isStorageProblem(output)) AndroidInstallError.NOT_ENOUGH_SPACE else AndroidInstallError.INSTALL_FAILED
                throw AndroidInstallException(error, output.trim().ifEmpty { "TV yanıt vermedi" })
            }
            installCompleted = true
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
        step(InstallStep.OPEN_PLAY)
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
        step(InstallStep.LAUNCHING)
        try {
            val started = adb.run(startCommand(launchParams)).trim()
            log.write("Uygulama açılıyor: $started")
            // TV "zaten çalışıyor, öne getirildi" derse eski ekran kapatılıp temiz açılır (Samsung'daki "resumed" gibi, #1248).
            if (started.contains("Activity not started")) {
                log.write("Uygulama zaten çalışıyordu (eski ekran); kapatılıp (kapanma isteği, gerekirse am force-stop) yeniden açılıyor")
                log.write("Uygulama açılıyor: ${restartOn(adb, launchParams)}")
            }
        } catch (error: IOException) {
            log.write("Uygulama açılamadı (kurulum yine tamam): ${error.message}")
        }
    }
}
