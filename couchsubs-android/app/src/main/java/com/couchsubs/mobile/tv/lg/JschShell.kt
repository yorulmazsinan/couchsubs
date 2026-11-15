// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki SshNetShell'in (windows/src/CouchSubs.Core/LgTv/RemoteShell.cs) telefon karşılığı; SSH mwiede/jsch'tendir (BSD).
package com.couchsubs.mobile.tv.lg

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.KeyPair
import java.io.ByteArrayOutputStream

/**
 * LG geliştirici modunun SSH sunucusuna (9922, kullanıcı prisoner) bağlanır. TV'nin anahtarı her fabrika ayarında
 * değişir; denetlenmez (ssh'deki StrictHostKeyChecking=no gibi). Eski webOS'lar yalnız ssh-rsa (SHA-1) ve eski
 * anahtar değişimlerini bilir; jsch bunları varsayılan olarak kapattığı için bu bağlantıda açılır.
 */
class JschShell(
    private val host: String,
    private val key: ByteArray,
    private val port: Int = LgInstaller.PORT,
    private val user: String = "prisoner",
    private val connectTimeoutMs: Int = 8_000,
    private val commandTimeoutMs: Long = 5 * 60_000L,
) : LgShell {
    companion object {
        private fun withLegacy(current: String?, vararg extra: String) =
            (listOfNotNull(current?.takeIf { it.isNotBlank() }) + extra.filter { current?.split(',')?.contains(it) != true }).joinToString(",")

        /**
         * Key Server'ın yanıtı eski PEM değilse (ör. OpenSSH biçimi) jsch çözer ve parolasız PEM olarak yazar; parola
         * yanlışsa [LgInstallError.WRONG_PASSPHRASE].
         */
        fun decryptOtherFormat(key: ByteArray, passphrase: String): ByteArray {
            val pair = try {
                KeyPair.load(JSch(), key, null)
            } catch (error: JSchException) {
                throw LgInstallException(LgInstallError.KEY_SERVER_OFF, "anahtar okunamadı: ${error.message}")
            }
            try {
                if (pair.isEncrypted && !pair.decrypt(passphrase) && !pair.decrypt(passphrase.uppercase()))
                    throw LgInstallException(LgInstallError.WRONG_PASSPHRASE)
                return ByteArrayOutputStream().also { pair.writePrivateKey(it) }.toByteArray()
            } finally {
                pair.dispose()
            }
        }
    }

    override fun run(command: String, input: ByteArray?): CommandResult {
        val jsch = JSch()
        try {
            jsch.addIdentity("couchsubs-lg", key, null, null)
        } catch (error: JSchException) {
            throw LgInstallException(LgInstallError.KEY_REFUSED, "anahtar okunamadı: ${error.message}")
        }
        val session = try {
            jsch.getSession(user, host, port).apply {
                setConfig("StrictHostKeyChecking", "no")
                setConfig("PreferredAuthentications", "publickey")
                setConfig("server_host_key", withLegacy(getConfig("server_host_key"), "ssh-rsa"))
                setConfig("PubkeyAcceptedAlgorithms", withLegacy(getConfig("PubkeyAcceptedAlgorithms"), "rsa-sha2-256", "rsa-sha2-512", "ssh-rsa"))
                setConfig("kex", withLegacy(getConfig("kex"), "diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1"))
                connect(connectTimeoutMs)
            }
        } catch (error: JSchException) {
            val message = error.message ?: ""
            throw if (message.contains("Auth fail", ignoreCase = true) || message.contains("USERAUTH fail", ignoreCase = true))
                LgInstallException(LgInstallError.KEY_REFUSED, message)
            else LgInstallException(LgInstallError.UNREACHABLE, message.ifEmpty { error.javaClass.simpleName })
        }
        try {
            val channel = session.openChannel("exec") as ChannelExec
            channel.setCommand(command)
            val output = ByteArrayOutputStream()
            val errors = ByteArrayOutputStream()
            // jsch'te akışlar connect'ten önce alınmalı.
            val stdin = if (input != null) channel.outputStream else null
            val stdout = channel.inputStream
            channel.setErrStream(errors, true)
            channel.connect(connectTimeoutMs)
            if (stdin != null) {
                // Giriş kapatılınca komut dosyanın bittiğini anlar ("cat > dosya").
                stdin.write(input!!)
                stdin.flush()
                stdin.close()
            }
            val deadline = System.currentTimeMillis() + commandTimeoutMs
            val buffer = ByteArray(8192)
            while (true) {
                while (stdout.available() > 0) {
                    val n = stdout.read(buffer)
                    if (n < 0) break
                    output.write(buffer, 0, n)
                }
                if (channel.isClosed && stdout.available() == 0) break
                if (System.currentTimeMillis() > deadline) {
                    channel.disconnect()
                    throw LgInstallException(LgInstallError.CONNECTION_LOST, "komut ${commandTimeoutMs / 1000} saniyede bitmedi")
                }
                Thread.sleep(50)
            }
            val status = channel.exitStatus
            channel.disconnect()
            return CommandResult(status, String(output.toByteArray() + errors.toByteArray(), Charsets.UTF_8))
        } catch (error: JSchException) {
            throw LgInstallException(LgInstallError.CONNECTION_LOST, error.message)
        } finally {
            session.disconnect()
        }
    }
}
