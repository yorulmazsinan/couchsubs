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
            val dumpsys = adb.run("shell:dumpsys package $PACKAGE_NAME")
            val installed = versionFromDumpsys(dumpsys)
            val fromPlay = installedFromPlay(dumpsys)
            log.write("TV'deki CouchSubs: ${installed ?: "yok"}${if (fromPlay) " (Google Play'den)" else ""}")
            if (installed != null && version != null && !SamsungDiagnostics.isNewer(version, installed)) {
                grantOverlay(adb, log)
                launch(adb)
                return Result(installed, false)
            }

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
            val after = versionFromDumpsys(adb.run("shell:dumpsys package $PACKAGE_NAME"))
            launch(adb)
            return Result(after ?: version ?: "", true)
        }
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
            log.write("Uygulama açılıyor: ${adb.run("shell:am start -n $PACKAGE_NAME/.MainActivity").trim()}")
        } catch (error: IOException) {
            log.write("Uygulama açılamadı (kurulum yine tamam): ${error.message}")
        }
    }
}
