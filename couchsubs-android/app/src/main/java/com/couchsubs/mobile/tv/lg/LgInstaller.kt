// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki DevModeInstaller.cs'in (windows/src/CouchSubs.Core/LgTv; Mac'te core/.../LGTV/DevModeInstaller.swift)
// telefon karşılığı. Fark: geliştirici modunun süresi uzatılmaz.
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

    companion object {
        const val PORT = 9922
        const val KEY_SERVER_PORT = 9991
        const val APP_ID = "com.couchsubs.tv"
        private const val APP_INFO = "/media/developer/apps/usr/palm/applications/$APP_ID/appinfo.json"
        const val TEMP_DIR = "/media/developer/temp"
        private const val INSTALL_LOG = "$TEMP_DIR/couchsubs-install.log"

        fun keyUrl(host: String, port: Int = KEY_SERVER_PORT) = "http://$host:$port/webos_rsa"

        /** ares-install gibi paket TV'ye kendi adıyla yüklenir. */
        fun remotePackage(name: String) = "$TEMP_DIR/${name.substringAfterLast('/')}"

        /** `com.couchsubs.tv_0.6.1_all.ipk` → `0.6.1` */
        fun versionOfPackage(name: String): String? {
            val parts = name.split('_')
            return if (name.endsWith(".ipk") && parts.size >= 3) parts[1] else null
        }

        fun versionFromAppInfo(text: String): String? = Regex(""""version"\s*:\s*"([^"]+)"""").find(text)?.groupValues?.get(1)

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
    }

    /** TV'deki sürüm; uygulama kurulu değilse null. */
    fun installedVersion(): String? = versionFromAppInfo(shell.run("cat $APP_INFO", null).output)

    /** TV'deki CouchSubs [version]'dan eskiyse ya da yoksa [ipk]'yı kurar, sonra uygulamayı açar. */
    fun ensureInstalled(ipk: ByteArray, packageName: String, version: String): Result {
        log.write("--- LG kurulumu (telefon) başlıyor: paket $packageName")
        try {
            progress(InstallStep.CONNECTING)
            val onTv = installedVersion()
            log.write("TV'deki CouchSubs: ${onTv ?: "yok"}")
            if (onTv != null && !SamsungDiagnostics.isNewer(version, onTv)) {
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
            remove(remote)
            throw failure(outcome.reason?.takeIf { it.isNotBlank() } ?: "kurulum başarısız: ${short(response.output)}", response.output)
        }
        val limit = verifyTimeoutMs ?: if (outcome.installed) 30_000L else 60_000L
        val started = System.currentTimeMillis()
        while (true) {
            if (installedVersion() == version) {
                remove(remote)
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
