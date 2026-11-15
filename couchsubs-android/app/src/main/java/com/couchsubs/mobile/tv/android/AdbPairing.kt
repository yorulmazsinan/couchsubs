// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki AdbPairing.cs'in (windows/src/CouchSubs.TvInstall/Android) Kotlin karşılığı.
package com.couchsubs.mobile.tv.android

import com.couchsubs.mobile.tv.samsung.AdbKey
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Android 11 ve sonrasının "Kablosuz hata ayıklama › Cihazı eşleme kodu ile eşle" eşleştirmesi (AOSP
 * packages/modules/adb pairing_connection, pairing_auth): TLS 1.3 üstünde, TV'nin gösterdiği 6 haneli kod ve TLS'ten
 * dışa aktarılan 64 bayt şifre olarak SPAKE2'ye verilir; çıkan anahtarla (HKDF-SHA256, AES-128-GCM) iki taraf açık
 * anahtarlarını şifreli değiş tokuş eder. Sonra TV bu telefonun anahtarını tanır ve bağlantı portunda TLS'le kabul eder.
 */
object AdbPairing {
    private const val HEADER_VERSION: Byte = 1
    internal const val SPAKE2_MESSAGE: Byte = 0
    internal const val PEER_INFO_MESSAGE: Byte = 1
    internal const val PEER_INFO_SIZE = 8192
    internal const val EXPORTED_KEY_LABEL = "adb-label\u0000"

    /** Eşleştirme portuna bağlanır ve kodla eşleşir. Kod yanlışsa [AndroidInstallError.PAIRING_FAILED]. */
    fun pair(host: String, port: Int, code: String, key: AdbKey) {
        Socket().use { socket ->
            try {
                socket.connect(InetSocketAddress(host, port), 5_000)
                socket.tcpNoDelay = true
                socket.soTimeout = 15_000
            } catch (error: IOException) {
                throw AndroidInstallException(AndroidInstallError.UNREACHABLE, "eşleme $host:$port: ${error.message}")
            }
            pair(socket.getInputStream(), socket.getOutputStream(), code, key)
        }
    }

    /** Akış üstünde eşleştirme (testler sahte TV ile çağırır). */
    internal fun pair(input: InputStream, output: OutputStream, code: String, key: AdbKey) {
        val tls = try {
            AdbTlsClient.connect(input, output, key)
        } catch (error: IOException) {
            throw AndroidInstallException(AndroidInstallError.PAIRING_FAILED, "TLS: ${error.message}")
        }
        try {
            val password = code.trim().toByteArray(Charsets.US_ASCII) + (tls.client.exportedKeyingMaterial
                ?: throw AndroidInstallException(AndroidInstallError.PAIRING_FAILED, "TLS anahtar dışa aktarımı yok"))
            val spake = Spake2(alice = true, password = password)
            writePacket(tls.output, SPAKE2_MESSAGE, spake.message)
            val theirs = readPacket(tls.input, SPAKE2_MESSAGE)
            val keyMaterial = spake.finish(theirs) ?: throw AndroidInstallException(AndroidInstallError.PAIRING_FAILED, "geçersiz SPAKE2 mesajı")
            val cipher = PairingCipher(keyMaterial)

            val peerInfo = ByteArray(PEER_INFO_SIZE)
            peerInfo[0] = 0 // ADB_RSA_PUB_KEY
            key.publicKeyLine(AdbConnection.KEY_NAME).toByteArray(Charsets.US_ASCII).copyInto(peerInfo, 1)
            writePacket(tls.output, PEER_INFO_MESSAGE, cipher.encrypt(peerInfo))
            // Kod yanlışsa TV'nin anahtarı farklıdır; gelen bilgi çözülemez (ya da TV bağlantıyı kapatır).
            val answer = readPacket(tls.input, PEER_INFO_MESSAGE)
            cipher.decrypt(answer) ?: throw AndroidInstallException(AndroidInstallError.PAIRING_FAILED, "eşleştirme kodu yanlış")
        } finally {
            tls.close()
        }
    }

    internal fun writePacket(output: OutputStream, type: Byte, payload: ByteArray) {
        output.write(ByteBuffer.allocate(6 + payload.size).put(HEADER_VERSION).put(type).putInt(payload.size).put(payload).array())
        output.flush()
    }

    internal fun readPacket(input: InputStream, expectedType: Byte): ByteArray {
        val header = try {
            AdbPacket.readExactly(input, 6)
        } catch (error: IOException) {
            // TV yanlış kodda bağlantıyı kapatır.
            throw AndroidInstallException(AndroidInstallError.PAIRING_FAILED, "TV eşleştirmeyi kapattı: ${error.message}")
        }
        val length = ByteBuffer.wrap(header, 2, 4).int
        if (header[0] != HEADER_VERSION || header[1] != expectedType || length < 0 || length > PEER_INFO_SIZE * 2)
            throw AndroidInstallException(AndroidInstallError.PAIRING_FAILED, "beklenmeyen eşleştirme paketi ${header[0]}/${header[1]}/$length")
        return AdbPacket.readExactly(input, length)
    }

    /** adb'nin Aes128Gcm'i: HKDF-SHA256 ("adb pairing_auth aes-128-gcm key"), her yönde 0'dan sayan nonce. */
    internal class PairingCipher(keyMaterial: ByteArray) {
        private val key = SecretKeySpec(hkdf(keyMaterial, "adb pairing_auth aes-128-gcm key".toByteArray(Charsets.US_ASCII), 16), "AES")
        private var encrypted = 0L
        private var decrypted = 0L

        private fun nonce(sequence: Long) = ByteArray(12).also { for (i in 0 until 8) it[i] = (sequence ushr (8 * i)).toByte() }

        fun encrypt(plain: ByteArray): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce(encrypted++)))
            doFinal(plain)
        }

        fun decrypt(sealed: ByteArray): ByteArray? = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce(decrypted++)))
                doFinal(sealed)
            }
        } catch (error: java.security.GeneralSecurityException) {
            null
        }

        companion object {
            /** RFC 5869, tuz yok (sıfır), tek blok yeter. */
            fun hkdf(secret: ByteArray, info: ByteArray, length: Int): ByteArray {
                val mac = Mac.getInstance("HmacSHA256")
                mac.init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
                val prk = mac.doFinal(secret)
                mac.init(SecretKeySpec(prk, "HmacSHA256"))
                mac.update(info)
                mac.update(1)
                return mac.doFinal().copyOf(length)
            }
        }
    }
}
