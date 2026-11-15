// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki LegacyPemKey.cs'in (windows/src/CouchSubs.Core/LgTv) Kotlin karşılığı.
package com.couchsubs.mobile.tv.lg

import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * LG Key Server'ın verdiği parolalı anahtarı (eski PEM biçimi: "Proc-Type: 4,ENCRYPTED") uygulamanın içinde çözer ve
 * parolasız PEM olarak döner; SSH kütüphanesine parolasız anahtar verilir.
 */
object LegacyPemKey {
    private val header = Regex("""-----BEGIN ([A-Z ]+?) PRIVATE KEY-----""")
    private val dekInfo = Regex("""DEK-Info:\s*([A-Za-z0-9-]+),([0-9A-Fa-f]+)\s*""")

    /** Anahtar bu biçimde değilse false (çağıran başka yolu dener). */
    fun isLegacyEncrypted(pem: String) = pem.contains("Proc-Type: 4,ENCRYPTED")

    /** Çözer; parola yanlışsa [LgInstallError.WRONG_PASSPHRASE]. */
    fun decrypt(pem: String, passphrase: String): String {
        val kind = header.find(pem)?.groupValues?.get(1)
        val info = dekInfo.find(pem)
        if (kind == null || info == null) throw LgInstallException(LgInstallError.INSTALL_FAILED, "PEM başlığı okunamadı")
        val cipherName = info.groupValues[1].uppercase()
        val iv = hex(info.groupValues[2])
        val body = pem.substring(info.range.last + 1)
        val end = body.indexOf("-----END")
        if (end < 0) throw LgInstallException(LgInstallError.INSTALL_FAILED, "PEM sonu bulunamadı")
        val encrypted = Base64.getDecoder().decode(body.substring(0, end).filterNot { it.isWhitespace() })

        val (transformation, algorithm, keyLength) = when (cipherName) {
            "DES-EDE3-CBC" -> Triple("DESede/CBC/PKCS5Padding", "DESede", 24)
            "AES-128-CBC" -> Triple("AES/CBC/PKCS5Padding", "AES", 16)
            "AES-192-CBC" -> Triple("AES/CBC/PKCS5Padding", "AES", 24)
            "AES-256-CBC" -> Triple("AES/CBC/PKCS5Padding", "AES", 32)
            else -> throw LgInstallException(LgInstallError.INSTALL_FAILED, "Desteklenmeyen şifre: $cipherName")
        }
        val key = deriveKey(passphrase.toByteArray(Charsets.UTF_8), iv.copyOf(8), keyLength)
        val plain = try {
            Cipher.getInstance(transformation).run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, algorithm), IvParameterSpec(iv))
                doFinal(encrypted)
            }
        } catch (error: GeneralSecurityException) {
            // Yanlış parolada dolgu (padding) hemen hemen her zaman bozuk çıkar.
            throw LgInstallException(LgInstallError.WRONG_PASSPHRASE)
        }
        // Dolgu tesadüfen tutsa bile çözülen veri bir ASN.1 dizisi (0x30) olmalı ve uzunluğu tutmalı.
        if (!looksLikeDer(plain)) throw LgInstallException(LgInstallError.WRONG_PASSPHRASE)
        val base64 = Base64.getEncoder().encodeToString(plain).chunked(64).joinToString("\n")
        return "-----BEGIN $kind PRIVATE KEY-----\n$base64\n-----END $kind PRIVATE KEY-----\n"
    }

    /** TV parolayı büyük harfle gösterir; küçük harfle yazılmışsa büyük harfli hâli de denenir. */
    fun decryptWithCaseFallback(pem: String, passphrase: String): String = try {
        decrypt(pem, passphrase)
    } catch (error: LgInstallException) {
        if (error.error != LgInstallError.WRONG_PASSPHRASE || passphrase == passphrase.uppercase()) throw error
        decrypt(pem, passphrase.uppercase())
    }

    /** OpenSSL'in EVP_BytesToKey'i (MD5, tek tur): eski PEM anahtarlarının parola türetmesi. */
    internal fun deriveKey(password: ByteArray, salt: ByteArray, length: Int): ByteArray {
        val key = ArrayList<Byte>(length + 16)
        var previous = ByteArray(0)
        while (key.size < length) {
            previous = MessageDigest.getInstance("MD5").digest(previous + password + salt)
            key.addAll(previous.toList())
        }
        return key.take(length).toByteArray()
    }

    private fun looksLikeDer(data: ByteArray): Boolean {
        if (data.size < 4 || data[0] != 0x30.toByte()) return false
        val first = data[1].toInt() and 0xFF
        val (length, offset) = if (first < 0x80) first to 2 else {
            val bytes = first and 0x7F
            if (bytes == 0 || bytes > 3 || data.size < 2 + bytes) return false
            var value = 0
            for (i in 0 until bytes) value = (value shl 8) or (data[2 + i].toInt() and 0xFF)
            value to 2 + bytes
        }
        return offset + length == data.size
    }

    private fun hex(text: String) = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
