// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.lg

import com.couchsubs.mobile.tv.samsung.InstallStep
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import org.bouncycastle.openssl.jcajce.JcaPEMWriter
import org.bouncycastle.openssl.jcajce.JcePEMEncryptorBuilder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.StringWriter
import java.net.InetAddress
import kotlin.concurrent.thread
import java.net.ServerSocket
import java.nio.file.Files
import java.security.KeyPairGenerator
import java.util.Base64

/** LG: Key Server anahtarı, parolasının çözülmesi ve sahte TV kabuğuyla kurulum komutları (gerçek TV olmadan). */
class LgTest {
    private val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()

    /** LG Key Server'ın verdiği gibi: eski PEM, "Proc-Type: 4,ENCRYPTED". */
    private fun encryptedPem(passphrase: String, cipher: String = "AES-128-CBC"): String {
        val writer = StringWriter()
        JcaPEMWriter(writer).use { it.writeObject(pair.private, JcePEMEncryptorBuilder(cipher).setProvider(org.bouncycastle.jce.provider.BouncyCastleProvider()).build(passphrase.toCharArray())) }
        return writer.toString()
    }

    /** PKCS#1 RSAPrivateKey (eski PEM'in içi) = PKCS#8'deki privateKey alanı. */
    private fun pkcs1(): ByteArray = org.bouncycastle.asn1.pkcs.PrivateKeyInfo.getInstance(pair.private.encoded).parsePrivateKey().toASN1Primitive().encoded

    private fun body(pem: String) = Base64.getDecoder().decode(pem.lines().filter { it.isNotBlank() && !it.startsWith("-----") }.joinToString(""))

    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try {
            block()
        } catch (error: Throwable) {
            if (error is T) return error
            throw error
        }
        fail("${T::class.simpleName} bekleniyordu")
        throw IllegalStateException()
    }

    @Test
    fun decryptsTheKeyServerKeyWithThePassphrase() {
        for (cipher in listOf("AES-128-CBC", "DES-EDE3-CBC", "AES-256-CBC")) {
            val pem = encryptedPem("A1B2C3", cipher)
            assertTrue(LegacyPemKey.isLegacyEncrypted(pem))
            val plain = LegacyPemKey.decrypt(pem, "A1B2C3")
            assertTrue(plain.startsWith("-----BEGIN RSA PRIVATE KEY-----\n"))
            assertArrayEquals(pkcs1(), body(plain))
            // jsch parolasız anahtarı okuyabiliyor.
            val loaded = KeyPair.load(JSch(), plain.toByteArray(), null)
            assertFalse(loaded.isEncrypted)
            assertEquals(KeyPair.RSA, loaded.keyType)
        }
    }

    @Test
    fun wrongPassphraseIsReportedAndLowercaseIsForgiven() {
        val pem = encryptedPem("A1B2C3")
        assertEquals(LgInstallError.WRONG_PASSPHRASE, expect<LgInstallException> { LegacyPemKey.decrypt(pem, "ZZZZZZ") }.error)
        assertEquals(LgInstallError.WRONG_PASSPHRASE, expect<LgInstallException> { LegacyPemKey.decrypt(pem, "a1b2c3") }.error)
        assertArrayEquals(pkcs1(), body(LegacyPemKey.decryptWithCaseFallback(pem, "a1b2c3")))
    }

    @Test
    fun evpBytesToKeyMatchesOpenSsl() {
        // İlk blok MD5(parola + tuz), ikincisi MD5(ilk blok + parola + tuz).
        val md5 = java.security.MessageDigest.getInstance("MD5")
        val two = LegacyPemKey.deriveKey("p".toByteArray(), ByteArray(8), 24)
        val block1 = md5.digest("p".toByteArray() + ByteArray(8))
        assertArrayEquals(block1 + md5.digest(block1 + "p".toByteArray() + ByteArray(8)).copyOf(8), two)
        val first = LegacyPemKey.deriveKey("p".toByteArray(), ByteArray(8), 16)
        assertArrayEquals(java.security.MessageDigest.getInstance("MD5").digest("p".toByteArray() + ByteArray(8)), first)
    }

    @Test
    fun keyServerResponseIsDownloadedAndDecoded() {
        val pem = encryptedPem("QWERTY")
        // Sahte Key Server: tek isteğe yanıt veren en küçük HTTP sunucusu (testler android.jar'la derlenir; com.sun yok).
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        var path = ""
        val worker = thread(isDaemon = true) {
            server.accept().use { socket ->
                val request = socket.getInputStream().bufferedReader()
                path = request.readLine() ?: ""
                while (!request.readLine().isNullOrEmpty()) Unit
                val bytes = pem.toByteArray()
                socket.getOutputStream().apply {
                    write("HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    write(bytes)
                    flush()
                }
            }
        }
        try {
            val response = LgInstaller.downloadKey("127.0.0.1", server.localPort)
            val key = LgInstaller.decodeKey(response, " qwerty ") { _, _ -> fail("eski PEM'de jsch'e gidilmemeli"); ByteArray(0) }
            assertArrayEquals(pkcs1(), body(String(key)))
            worker.join(5000)
            assertTrue(path.startsWith("GET /webos_rsa "))
        } finally {
            server.close()
        }
        val closed = ServerSocket(0).use { it.localPort }
        assertEquals(LgInstallError.KEY_SERVER_OFF, expect<LgInstallException> { LgInstaller.downloadKey("127.0.0.1", closed, 1000) }.error)
        assertEquals(LgInstallError.KEY_SERVER_OFF,
            expect<LgInstallException> { LgInstaller.decodeKey("<html>Key Server</html>".toByteArray(), "X") { k, _ -> k } }.error)
        assertEquals("http://192.168.1.9:9991/webos_rsa", LgInstaller.keyUrl("192.168.1.9"))
    }

    @Test
    fun otherKeyFormatsGoToJsch() {
        // OpenSSH'nin yeni biçimi gibi eski PEM olmayan anahtar: jsch çözer.
        val generated = KeyPair.genKeyPair(JSch(), KeyPair.RSA, 2048)
        val out = java.io.ByteArrayOutputStream()
        generated.writePrivateKey(out, "PASS12".toByteArray())
        val encrypted = out.toByteArray()
        if (LegacyPemKey.isLegacyEncrypted(String(encrypted))) {
            // jsch eski PEM yazdıysa bizim çözücümüz de açabilmeli.
            assertTrue(String(LgInstaller.decodeKey(encrypted, "PASS12") { k, p -> JschShell.decryptOtherFormat(k, p) }).contains("PRIVATE KEY"))
        } else {
            val plain = JschShell.decryptOtherFormat(encrypted, "PASS12")
            assertFalse(KeyPair.load(JSch(), plain, null).isEncrypted)
            assertEquals(LgInstallError.WRONG_PASSPHRASE, expect<LgInstallException> { JschShell.decryptOtherFormat(encrypted, "nope") }.error)
        }
    }

    @Test
    fun parsesPackageNamesAndInstallReplies() {
        assertEquals("0.9.18", LgInstaller.versionOfPackage("com.couchsubs.tv_0.9.18_all.ipk"))
        assertNull(LgInstaller.versionOfPackage("couchsubs.ipk"))
        assertEquals("/media/developer/temp/com.couchsubs.tv_0.9.18_all.ipk", LgInstaller.remotePackage("com.couchsubs.tv_0.9.18_all.ipk"))
        assertEquals("0.9.18", LgInstaller.versionFromAppInfo("""{ "id": "com.couchsubs.tv", "version" : "0.9.18" }"""))
        assertTrue(LgInstaller.parseInstallReplies("""{"returnValue":true,"details":{"state":"IPK download"}}""" + "\n" +
            """{"returnValue":true,"details":{"state":"installed"}}""").installed)
        // Satıra bölünmüş JSON birleştirilir; luna-send'in kendi yazısı atlanır.
        val failed = LgInstaller.parseInstallReplies("Error: something\n{\"returnValue\":true,\n\"details\":{\"state\":\"FAILED\",\"reason\":\"not enough space\",\"errorCode\":-5}}\n")
        assertTrue(failed.failed)
        assertEquals("not enough space (errorCode -5)", failed.reason)
        assertTrue(LgInstaller.parseInstallReplies("""{"returnValue":false,"errorText":"Invalid ipk"}""").failed)
        assertFalse(LgInstaller.parseInstallReplies("").installed)
        assertTrue(LgInstaller.isStorageProblem("No space left on device"))
        val command = LgInstaller.installCommand("/media/developer/temp/x.ipk", 180)
        assertTrue(command.contains("luna-send-pub -i 'luna://com.webos.appInstallService/dev/install' '{\"id\":\"com.ares.defaultName\",\"ipkUrl\":\"/media/developer/temp/x.ipk\",\"subscribe\":true}'"))
        assertTrue(command.contains("sleep 210"))
        assertTrue(command.contains("while [ \$i -lt 180 ]"))
    }

    /** Sahte TV kabuğu: komutları ve gelen veriyi kaydeder, appinfo.json'u kurulumdan sonra yeni sürümle döner. */
    private class FakeTv(var installed: String?, private val installReply: String = """{"returnValue":true,"details":{"state":"installed"}}""",
                         private val sizeOverride: Long? = null) : LgShell {
        val commands = mutableListOf<String>()
        var uploaded: ByteArray? = null

        override fun run(command: String, input: ByteArray?): CommandResult {
            commands += command
            return when {
                command.startsWith("cat /media/developer/apps") ->
                    CommandResult(if (installed == null) 1 else 0, installed?.let { """{"id":"com.couchsubs.tv","version":"$it"}""" } ?: "cat: no such file")
                command.contains("cat > ") -> { uploaded = input; CommandResult(0, "") }
                command.startsWith("wc -c") -> CommandResult(0, "${sizeOverride ?: uploaded?.size ?: 0}\n")
                command.contains("appInstallService") -> {
                    if (installReply.contains("installed")) installed = "0.9.18"
                    CommandResult(0, installReply)
                }
                else -> CommandResult(0, "")
            }
        }
    }

    private val ipk = ByteArray(34_000) { it.toByte() }

    @Test
    fun installsUploadsVerifiesCleansUpAndLaunches() {
        val tv = FakeTv(installed = "0.9.10")
        val steps = mutableListOf<InstallStep>()
        val result = LgInstaller(tv, { steps += it }, pollIntervalMs = 1).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18")
        assertEquals(LgInstaller.Result("0.9.18", true), result)
        assertArrayEquals(ipk, tv.uploaded)
        assertEquals("mkdir -p /media/developer/temp && rm -f /media/developer/temp/com.couchsubs.tv_*.ipk /media/developer/temp/couchsubs.ipk && " +
            "cat > '/media/developer/temp/com.couchsubs.tv_0.9.18_all.ipk'", tv.commands[1])
        assertTrue(tv.commands.contains("rm -f '/media/developer/temp/com.couchsubs.tv_0.9.18_all.ipk'"))
        assertEquals(LgInstaller.launchCommand(), tv.commands.last())
        assertTrue(tv.commands.last().contains("luna://com.webos.applicationManager/launch"))
        assertEquals(listOf(InstallStep.CONNECTING, InstallStep.INSTALLING, InstallStep.LAUNCHING), steps)
        // Geliştirici modunun süresine dokunulmaz.
        assertFalse(tv.commands.any { it.contains("devmode_enabled") })
    }

    @Test
    fun upToDateTvIsOnlyLaunched() {
        val tv = FakeTv(installed = "0.9.18")
        assertEquals(LgInstaller.Result("0.9.18", false), LgInstaller(tv).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18"))
        assertEquals(2, tv.commands.size)
        assertNull(tv.uploaded)
    }

    @Test
    fun failuresAreClassified() {
        val space = FakeTv(null, """{"returnValue":false,"errorText":"Installation failed: not enough space"}""")
        assertEquals(LgInstallError.NOT_ENOUGH_SPACE,
            expect<LgInstallException> { LgInstaller(space).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18") }.error)
        val broken = FakeTv(null, sizeOverride = 100)
        val error = expect<LgInstallException> { LgInstaller(broken).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18") }
        assertEquals(LgInstallError.INSTALL_FAILED, error.error)
        assertTrue(error.detail!!.contains("100/34000"))
        // TV "installed" dedi ama sürüm görünmüyor.
        val silent = object : LgShell {
            override fun run(command: String, input: ByteArray?) = when {
                command.startsWith("wc -c") -> CommandResult(0, "${ipk.size}")
                command.contains("appInstallService") -> CommandResult(0, """{"returnValue":true,"details":{"state":"installed"}}""")
                else -> CommandResult(0, "")
            }
        }
        assertEquals(LgInstallError.INSTALL_FAILED, expect<LgInstallException> {
            LgInstaller(silent, pollIntervalMs = 1, verifyTimeoutMs = 20).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18")
        }.error)
    }

    @Test
    fun savedKeysAreKeptPerTv() {
        val keys = LgKeys(Files.createTempDirectory("lg").toFile())
        assertNull(keys.load("192.168.1.9"))
        keys.save("192.168.1.9", "key".toByteArray())
        assertArrayEquals("key".toByteArray(), keys.load(" 192.168.1.9 "))
        assertNull(keys.load("192.168.1.10"))
        keys.remove("192.168.1.9")
        assertNull(keys.load("192.168.1.9"))
    }

    @Test
    fun unreachableTvIsReportedBySsh() {
        val closed = ServerSocket(0).use { it.localPort }
        val key = LegacyPemKey.decrypt(encryptedPem("A1B2C3"), "A1B2C3").toByteArray()
        val error = expect<LgInstallException> { JschShell("127.0.0.1", key, port = closed, connectTimeoutMs = 1000).run("true", null) }
        assertEquals(LgInstallError.UNREACHABLE, error.error)
    }
}
