// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.File
import java.io.RandomAccessFile

/**
 * Telefondaki "Günlükleri paylaş" (Profil › Hakkında): uygulamanın günlükleri tek bir metin dosyasında birleştirilir;
 * dosyada kişisel veri kalmaz. Yerel ağ adresleri (IP) sorunu anlamak için kalır; PSN hesap kimliği, e-posta, jetonlar,
 * eşleştirme anahtarları (RegistKey, RP key, morning), oturum kimliği ve uzun kimlik dizileri `***` olur. iPhone'daki
 * core LogShare.swift ile aynı kurallar; ikisi de ortak deneme dosyası log-redaction.json ile sınanır.
 */
object LogShare {
    const val FILE_NAME = "couchsubs-logs.txt"

    /** Her günlükten alınan en çok bayt (dosyanın sonu; en yeni satırlar). */
    const val MAX_BYTES_PER_LOG = 1_500_000

    /** Değeri maskelenen alan adları ("ad: değer", "ad=değer", "\"ad\":\"değer\"" biçimleri). */
    private val secretKeys = listOf(
        "hesap kimliği", "account ?id", "account_id", "accountid", "psn ?id", "online ?id", "user ?id", "user_id",
        "rp-?regist-?key", "regist_?key", "registkey", "rp_?key", "rp-key", "rpkey", "morning", "rp-auth", "rp-did",
        "session ?id", "sessionid", "host-?id", "npsso", "access_token", "refresh_token", "id_token", "token",
        "authorization", "password", "passcode", "client_secret", "xuid", "gamertag", "uhs", "userhash", "email", "e-posta",
    )

    private val rules: List<Pair<Regex, String>> = run {
        fun rule(pattern: String, template: String) = Regex(pattern, RegexOption.IGNORE_CASE) to template
        val keys = secretKeys.joinToString("|")
        listOf(
            // E-posta adresi.
            rule("""[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}""", "***@***"),
            // Bearer / XBL3.0 yetki başlığı.
            rule("""\b(Bearer|XBL3\.0)\s+[^\s"',]+""", "$1 ***"),
            // "ad: değer", "ad=değer", "\"ad\":\"değer\"".
            rule("""(\b(?:$keys)["']?\s*[:=]\s*["']?)[^\s"',;&}\])]+""", "$1***"),
            // "hesap kimliği değer", "Session Id \"değer\"".
            rule("""(\b(?:hesap kimliği|session ?id)\s+["']?)[^\s"',;&}\])]+""", "$1***"),
            // URL'deki tek kullanımlık kod (?code=…&…).
            rule("""([?&](?:code|state)=)[^\s&"']+""", "$1***"),
            // Uzun base64/onaltılık dizi (jeton, anahtar): 32 karakter ve üstü. "/" sayılmaz; dosya yolları kalır.
            rule("""(?<![A-Z0-9+_-])[A-Z0-9+_-]{32,}={0,2}""", "***"),
        )
    }

    /** Metindeki kişisel verileri maskeler; IP adresleri, saatler ve hata kodları kalır. */
    fun redact(text: String): String = rules.fold(text) { acc, (regex, template) -> regex.replace(acc, template) }

    /**
     * Paylaşılacak metin: başlık (uygulama, sürüm, cihaz) ve her günlük kendi başlığıyla, maskelenmiş. Metni olmayan
     * günlük "(yok)" diye yazılır.
     */
    fun combined(header: String, logs: List<Pair<String, String?>>): String {
        val parts = mutableListOf(header)
        for ((name, text) in logs) {
            parts += "===== $name ====="
            parts += if (text.isNullOrEmpty()) "(yok)" else redact(if (text.endsWith("\n")) text else text + "\n")
        }
        return parts.joinToString("\n\n") + "\n"
    }

    /** Dosyanın en çok [MAX_BYTES_PER_LOG] baytlık sonu (kesilen ilk satır atılır); dosya yoksa null. */
    fun tail(file: File): String? {
        if (!file.isFile) return null
        return RandomAccessFile(file, "r").use { handle ->
            val start = (handle.length() - MAX_BYTES_PER_LOG).coerceAtLeast(0)
            val bytes = ByteArray((handle.length() - start).toInt())
            handle.seek(start)
            handle.readFully(bytes)
            val text = String(bytes, Charsets.UTF_8)
            if (start > 0) text.substringAfter('\n', text) else text
        }.ifEmpty { null }
    }
}
