// SPDX-License-Identifier: AGPL-3.0-only
// Hata kodlarının anlamları Apps2Samsung'un TizenInstallDiagnostics'inden (MIT, Patrick Stel); masaüstündeki
// SamsungInstallDiagnostics.cs'in Kotlin karşılığı.
package com.couchsubs.mobile.tv.samsung

/** Kurulumun duraksadığı sebep (masaüstündeki SamsungInstallError). */
enum class SamsungInstallError {
    /** TV'de geliştirici modu kapalı ya da TV'ye girilen Host PC IP bu telefonunki değil. */
    UNREACHABLE,
    LOGIN_FAILED,
    CERTIFICATE_FAILED,
    /** TV, Tizen 2.4'ten (2016) eski. */
    TOO_OLD,
    INSTALL_FAILED,
    NOT_ENOUGH_SPACE,
    CERTIFICATE_MISMATCH,
    CERTIFICATE_REJECTED,
    TV_CLOCK_WRONG,
    PACKAGE_BLOCKED,
    CONNECTION_LOST,
    /**
     * TV'de CouchSubs'ın kimliğiyle (CouchSubsT) başka bir uygulama kurulu (adı CouchSubs değil). Kullanıcı onaylamadan
     * kaldırılmaz; onaylarsa kaldırılıp CouchSubs kurulur.
     */
    FOREIGN_APP,
}

/** [detail] kullanıcıya da gösterilir: TV'nin hata satırı, Samsung'un yanıtı ya da istisna iletisi. */
class SamsungInstallException(val error: SamsungInstallError, val detail: String? = null) :
    Exception(if (detail == null) error.name else "${error.name}: $detail")

/** `vd_appinstall` çıktısından anlaşılan sorun. */
enum class InstallProblem { NONE, CONNECTION_LOST, NOT_ENOUGH_SPACE, CERTIFICATE_MISMATCH, CERTIFICATE_REJECTED, CERTIFICATE_NOT_YET_VALID, PACKAGE_BLOCKED, INCOMPATIBLE, OTHER }

/** TV, kurulum başarısız olsa da komutu başarılı bitirir; ne olduğu çıktıdan anlaşılır. */
object SamsungDiagnostics {
    /** Yalın "failed" aranmaz; ilgisiz bir satır başarısızlık sanılmasın. */
    fun failed(log: String?) = has(log, "install failed") || has(log, "val[fail]") || has(log, "not enough space") ||
        has(log, "download failed[116]") || isConnectionLost(log)

    fun classify(log: String?): InstallProblem {
        if (!failed(log)) return InstallProblem.NONE
        if (isConnectionLost(log)) return InstallProblem.CONNECTION_LOST
        if (has(log, "install failed[118, -4]") || has(log, "install failed[118, -19]") || has(log, "install failed[118019]"))
            return InstallProblem.INCOMPATIBLE
        if (has(log, "download failed[116]") || has(log, "not enough space")) return InstallProblem.NOT_ENOUGH_SPACE
        val certificate = has(log, "install failed[118, -12]") || has(log, "install failed[118012]") ||
            has(log, "install failed[118, -11]") || has(log, "install failed[118011]")
        // [118, -12] iki şey olabilir: TV'de başka sertifikalı kopya (kaldırınca düzelir) ya da TV'nin sertifikayı reddetmesi.
        if (certificate && has(log, "Check certificate error") && !has(log, "same id and different certificate"))
            return if (has(log, "not valid yet")) InstallProblem.CERTIFICATE_NOT_YET_VALID else InstallProblem.CERTIFICATE_REJECTED
        if (certificate || has(log, "Author certificate not match")) return InstallProblem.CERTIFICATE_MISMATCH
        if (has(log, "install failed[118, -22]") || has(log, "install failed[118022]")) return InstallProblem.PACKAGE_BLOCKED
        return InstallProblem.OTHER
    }

    fun removingOldCopyMayHelp(problem: InstallProblem) =
        problem == InstallProblem.CERTIFICATE_MISMATCH || problem == InstallProblem.PACKAGE_BLOCKED || problem == InstallProblem.OTHER

    fun toError(problem: InstallProblem) = when (problem) {
        InstallProblem.CONNECTION_LOST -> SamsungInstallError.CONNECTION_LOST
        InstallProblem.NOT_ENOUGH_SPACE -> SamsungInstallError.NOT_ENOUGH_SPACE
        InstallProblem.CERTIFICATE_MISMATCH -> SamsungInstallError.CERTIFICATE_MISMATCH
        InstallProblem.CERTIFICATE_REJECTED -> SamsungInstallError.CERTIFICATE_REJECTED
        InstallProblem.CERTIFICATE_NOT_YET_VALID -> SamsungInstallError.TV_CLOCK_WRONG
        InstallProblem.PACKAGE_BLOCKED -> SamsungInstallError.PACKAGE_BLOCKED
        else -> SamsungInstallError.INSTALL_FAILED
    }

    /** Kullanıcıya gösterilecek kısa ayrıntı: TV'nin hata satırı, yoksa çıktının sonu. */
    fun summary(log: String?): String {
        if (log.isNullOrBlank()) return "TV yanıt vermedi"
        val lines = log.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
        val key = lines.filter { line ->
            listOf("fail", "error", "reason", "not match", "space").any { line.contains(it, ignoreCase = true) }
        }.distinct().take(3)
        val text = if (key.isNotEmpty()) key.joinToString(" | ") else lines.takeLast(3).joinToString(" | ")
        return if (text.length <= 400) text else text.take(400) + "…"
    }

    private fun isConnectionLost(log: String?) =
        has(log, "transport connection") || has(log, "connection reset by peer") || has(log, "broken pipe")

    private fun has(log: String?, token: String) = !log.isNullOrEmpty() && log.contains(token, ignoreCase = true)

    /** Sayısal karşılaştırma: 0.10.0, 0.9.9'dan yenidir (masaüstündeki Versions.IsNewer). */
    fun isNewer(a: String, b: String): Boolean {
        val x = parts(a)
        val y = parts(b)
        for (i in 0 until maxOf(x.size, y.size)) {
            val left = x.getOrElse(i) { 0 }
            val right = y.getOrElse(i) { 0 }
            if (left != right) return left > right
        }
        return false
    }

    private fun parts(version: String) = version.split('.', '-').map { it.toIntOrNull() ?: 0 }

    private val fieldLine = Regex("""^[\s-]*([A-Za-z_]+)\s*=\s*(.*?)[\s-]*$""")

    /** `0 vd_applist` çıktısında CouchSubs'ın sürümü; satırlar `---- anahtar = değer ----` biçimindedir. */
    fun installedVersion(listing: String?): String? = couchSubsBlock(listing)?.get("app_version")?.takeIf { it.isNotEmpty() }

    /** Bizim config.xml'deki uygulama adı (tv-tizen/config.xml). */
    const val OUR_TITLE = "CouchSubs"

    /**
     * `vd_applist`'te bizim kimliğimizle (CouchSubsT / CouchSubsT.CouchSubs) kurulu uygulamanın adı CouchSubs değil mi?
     * Ad yoksa bizim sayılır (Windows, Mac ve iPhone ile aynı kural). Samsung'da imza sertifikası kullanıcının Samsung
     * hesabına göre değiştiği için ayırt etmede ada bakılır.
     */
    fun isForeignApp(listing: String?): Boolean {
        val title = couchSubsBlock(listing)?.get("app_title")?.trim()
        return !title.isNullOrEmpty() && !title.equals(OUR_TITLE, ignoreCase = true)
    }

    /** `vd_applist`'te bizim kimliğimizin alanları (sürümü olan ilk blok); yoksa null. */
    private fun couchSubsBlock(listing: String?): Map<String, String>? {
        if (listing.isNullOrBlank()) return null
        val fields = HashMap<String, String>()
        var found: Map<String, String>? = null
        fun flush() {
            val ids = listOf(fields["app_tizen_id"], fields["app_id"])
            val version = fields["app_version"]
            if (found == null && ids.any { isCouchSubs(it) } && !version.isNullOrEmpty()) found = HashMap(fields)
            fields.clear()
        }
        for (raw in listing.replace("\r", "").split('\n')) {
            if (!raw.contains('=') && raw.contains("----")) {
                flush()
                continue
            }
            fieldLine.find(raw)?.let { fields[it.groupValues[1].lowercase()] = it.groupValues[2].trim() }
        }
        flush()
        return found
    }

    private fun isCouchSubs(id: String?) = id != null && id.isNotBlank() &&
        (id.trim().equals(SamsungInstaller.APP_ID, ignoreCase = true) || id.trim().equals(SamsungInstaller.PACKAGE_ID, ignoreCase = true))
}
