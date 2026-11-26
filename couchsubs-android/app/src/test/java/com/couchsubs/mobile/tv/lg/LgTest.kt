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
                         private val sizeOverride: Long? = null, private val clock: String = "") : LgShell {
        val commands = mutableListOf<String>()
        var uploaded: ByteArray? = null

        override fun run(command: String, input: ByteArray?): CommandResult {
            commands += command
            return when {
                command.startsWith("cat /media/developer/apps") ->
                    CommandResult(if (installed == null) 1 else 0, installed?.let { """{"id":"com.couchsubs.tv","version":"$it"}""" } ?: "cat: no such file")
                command.contains("cat > ") -> { uploaded = input; CommandResult(0, "") }
                command.startsWith("wc -c") -> CommandResult(0, "${sizeOverride ?: uploaded?.size ?: 0}\n")
                command == LgInstaller.CLOCK_COMMAND -> CommandResult(0, clock)
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
            "cat > '/media/developer/temp/com.couchsubs.tv_0.9.18_all.ipk'", tv.commands[2])
        assertTrue(tv.commands.contains("rm -f '/media/developer/temp/com.couchsubs.tv_0.9.18_all.ipk'"))
        assertEquals(LgInstaller.launchCommand(), tv.commands.last())
        assertTrue(tv.commands.last().contains("luna://com.webos.applicationManager/launch"))
        assertEquals(listOf(InstallStep.CONNECTING, InstallStep.INSTALLING, InstallStep.LAUNCHING), steps)
        // Geliştirici modunun süresine dokunulmaz.
        assertFalse(tv.commands.any { it.contains("devmode_enabled") })
    }

    /** LG OLED CX (webOS 5): "ipk verified failed" (errorCode -5); Mac, iPhone ve Windows'taki testlerle aynı. */
    private val verifyFailed = """{"details":{"state":"FAILED_IPKG_INSTALL","verified":false,"errorCode":-5,"reason":"ipk verified failed"},"returnValue":true}"""

    @Test
    fun recognisesPackageVerifyFailuresAndNamesBothClocks() {
        assertTrue(LgInstaller.isPackageVerifyFailure("ipk verified failed (errorCode -5)"))
        assertTrue(LgInstaller.isPackageVerifyFailure("FAILED_IPKG_INSTALL (errorCode -5)"))
        assertFalse(LgInstaller.isPackageVerifyFailure("FAILED_IPKG_INSTALL (errorCode -50)"))
        assertFalse(LgInstaller.isPackageVerifyFailure("Not enough space"))
        assertEquals("date +%s", LgInstaller.CLOCK_COMMAND)
        assertEquals(600L, LgInstaller.MAX_CLOCK_LAG)
        val now = 1_795_660_080L // 2026-11-26 02:28:00 UTC
        assertEquals(LgInstaller.VerifyFailure(true, "ipk verified failed (errorCode -5); TV saati 2020-01-01 00:23:49 UTC, bu cihaz 2026-11-26 02:28:00 UTC (TV 217821851 sn geride)"),
            LgInstaller.verifyFailureDetail("ipk verified failed (errorCode -5)", "1577838229\n", now))
        assertEquals(LgInstaller.VerifyFailure(false, "r; TV saati 2026-11-26 02:27:00 UTC, bu cihaz 2026-11-26 02:28:00 UTC (TV 60 sn geride)"),
            LgInstaller.verifyFailureDetail("r", "1795660020", now))
        assertTrue(LgInstaller.verifyFailureDetail("r", "1795660090", now).detail.endsWith("(TV 10 sn ileride)"))
        assertEquals(LgInstaller.VerifyFailure(false, "r; TV saati okunamadı"), LgInstaller.verifyFailureDetail("r", "sh: date: not found", now))
    }

    @Test
    fun verifyFailureWithTheTvClockBehindAsksToFixTheClock() {
        val tv = FakeTv(installed = "0.9.10", installReply = verifyFailed, clock = "1577838229\n")
        val error = expect<LgInstallException> { LgInstaller(tv, pollIntervalMs = 1).install(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18") }
        assertEquals(LgInstallError.TV_CLOCK_WRONG, error.error)
        assertTrue(error.detail!!.startsWith("ipk verified failed (errorCode -5); TV saati 2020-01-01 00:23:49 UTC"))
        assertEquals("rm -f '/media/developer/temp/com.couchsubs.tv_0.9.18_all.ipk'", tv.commands.last())
    }

    @Test
    fun verifyFailureWithTheRightClockStaysAnInstallFailure() {
        val tv = FakeTv(installed = "0.9.10", installReply = verifyFailed, clock = "${System.currentTimeMillis() / 1000}")
        val error = expect<LgInstallException> { LgInstaller(tv, pollIntervalMs = 1).install(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18") }
        assertEquals(LgInstallError.INSTALL_FAILED, error.error)
        assertTrue(LgInstaller.isPackageVerifyFailure(error.detail!!))
        assertTrue(error.detail!!.contains("TV saati"))
    }

    @Test
    fun recognisesOtherAppsInAppInfo() {
        val ours = """{"id":"com.couchsubs.tv","version":"0.9.74","vendor":"Enmera","title":"CouchSubs"}"""
        assertFalse(LgInstaller.isForeignAppInfo(ours))
        assertFalse(LgInstaller.isForeignAppInfo(ours.replace("CouchSubs\"", "couchsubs \"")))
        assertTrue(LgInstaller.isForeignAppInfo(ours.replace("\"CouchSubs\"", "\"Other App\"")))
        assertTrue(LgInstaller.isForeignAppInfo(ours.replace("Enmera", "Someone")))
        // Alan yoksa ya da dosya yoksa bizim sayılır.
        assertFalse(LgInstaller.isForeignAppInfo("""{"id":"com.couchsubs.tv","version":"0.9.18"}"""))
        assertFalse(LgInstaller.isForeignAppInfo("cat: no such file"))
        assertTrue(LgInstaller.REMOVE_COMMAND.contains("dev/remove"))
    }

    @Test
    fun otherAppIsRemovedOnlyWithConsent() {
        class OtherTv : LgShell {
            val commands = mutableListOf<String>()
            var info: String? = """{"id":"com.couchsubs.tv","version":"9.9.9","vendor":"Someone","title":"Other App"}"""
            override fun run(command: String, input: ByteArray?): CommandResult {
                commands += command
                return when {
                    command.startsWith("cat /media/developer/apps") -> CommandResult(if (info == null) 1 else 0, info ?: "cat: no such file")
                    command.contains("dev/remove") -> { info = null; CommandResult(0, """{"returnValue":true}""") }
                    command.contains("cat > ") -> CommandResult(0, "")
                    command.startsWith("wc -c") -> CommandResult(0, "${ipk.size}\n")
                    command.contains("dev/install") -> {
                        info = """{"id":"com.couchsubs.tv","version":"0.9.18","vendor":"Enmera","title":"CouchSubs"}"""
                        CommandResult(0, """{"returnValue":true,"details":{"state":"installed"}}""")
                    }
                    else -> CommandResult(0, "")
                }
            }
        }
        val tv = OtherTv()
        val error = expect<LgInstallException> { LgInstaller(tv).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18") }
        assertEquals(LgInstallError.FOREIGN_APP, error.error)
        assertEquals(1, tv.commands.size)
        val result = LgInstaller(tv, pollIntervalMs = 1).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18", replaceForeign = true)
        assertEquals(LgInstaller.Result("0.9.18", true), result)
        assertTrue(tv.commands.any { it.contains("dev/remove") })
    }

    /** beta.89: kurulum doğrulandıktan sonra açık (eski) uygulama kapatılır, sonra açılır; webOS eski süreci tutuyordu. */
    @Test
    fun installClosesTheRunningAppBeforeLaunching() {
        val tv = FakeTv(installed = "0.9.10")
        LgInstaller(tv, pollIntervalMs = 1).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18")
        assertEquals(listOf(LgInstaller.CLOSE_COMMAND, LgInstaller.launchCommand()), tv.commands.takeLast(2))
        // Mac, Windows ve iPhone'daki komutla aynı.
        assertEquals("/usr/bin/luna-send-pub -n 1 'luna://com.webos.applicationManager/closeByAppId' '{\"id\":\"com.couchsubs.tv\"}'; sleep 2",
            LgInstaller.CLOSE_COMMAND)
    }

    /** Paket güncel ama açık uygulama eski sürümü bildiriyor: yeniden kurulmaz, kapatılıp açılır. */
    @Test
    fun upToDatePackageWithAnOldRunningAppIsRestarted() {
        val tv = FakeTv(installed = "0.9.18")
        val result = LgInstaller(tv).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18", runningVersion = "0.9.10")
        assertEquals(LgInstaller.Result("0.9.18", false), result)
        assertNull(tv.uploaded)
        assertEquals(listOf(LgInstaller.CLOSE_COMMAND, LgInstaller.launchCommand()), tv.commands.takeLast(2))
        // Açık uygulama güncelse kapatılmaz.
        val fine = FakeTv(installed = "0.9.18")
        LgInstaller(fine).ensureInstalled(ipk, "com.couchsubs.tv_0.9.18_all.ipk", "0.9.18", runningVersion = "0.9.18")
        assertFalse(fine.commands.contains(LgInstaller.CLOSE_COMMAND))
    }

    @Test
    fun runningCheckRestartsOnceThenReportsAStaleApp() {
        val check = TvAppRunningCheck("0.9.86")
        assertEquals(TvAppRunningCheck.Verdict.RESTART_AGAIN, check.report("0.9.81"))
        assertEquals(TvAppRunningCheck.Verdict.STALE, check.report("0.9.81"))
        assertEquals(TvAppRunningCheck.Verdict.RUNNING, TvAppRunningCheck("0.9.86").report("0.9.86"))
        assertEquals(TvAppRunningCheck.Verdict.RUNNING, TvAppRunningCheck("0.9.9").report("0.9.10"))
        assertEquals(TvAppRunningCheck.Verdict.RESTART_AGAIN, TvAppRunningCheck("0.9.86").report(""))
        assertTrue(TvAppRunningCheck.isStale("0.9.81", "0.9.84"))
        assertFalse(TvAppRunningCheck.isStale("0.9.84", "0.9.84"))
        assertFalse(TvAppRunningCheck.isStale("0.9.81", ""))
    }

    /** Kurulumdan sonra açılan uygulama eski: bir kez daha kapat-aç, yine eskiyse ana ekran "TV'de kapatıp açın" der. */
    @Test
    fun phoneRestartsAnOldRunningAppOnceThenTellsTheUser() {
        val tv = com.couchsubs.mobile.tv.InstalledTv(com.couchsubs.mobile.tv.TvBrand.LG, "192.168.1.20", version = "0.9.86")
        val update = com.couchsubs.mobile.tv.TvAppUpdate
        val restarts = mutableListOf<String>()
        val log = mutableListOf<String>()
        update.expectRunning("0.9.86")
        assertTrue(update.lgRunningReported(null, tv, "0.9.81", { host, done -> restarts += host; done(true) }, { log += it }))
        assertEquals(listOf("192.168.1.20"), restarts)
        assertTrue(update.lgRunningReported(null, tv, "0.9.81", { host, done -> restarts += host; done(true) }, { log += it }))
        assertEquals(1, restarts.size)
        assertEquals(com.couchsubs.mobile.tv.TvAppStatus.RunningStale(tv, "0.9.81", "0.9.86"), update.status.value)
        // Denetim bitti: sonraki bildirim olağan yoldan geçer.
        assertFalse(update.lgRunningReported(null, tv, "0.9.86", { _, _ -> }, { log += it }))
        // Kurulumdan sonra yeni sürüm bağlanırsa kapat-aç yok.
        update.expectRunning("0.9.86")
        assertFalse(update.lgRunningReported(null, tv, "0.9.86", { host, done -> restarts += host; done(true) }, { log += it }))
        assertEquals(1, restarts.size)
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

    /** 9922 kapalıyken TV'nin diğer portlarına göre ne yapılacağı ayrılır (TestFlight: 14 denemede hep "Connection refused"). */
    @Test
    fun closedDeveloperSshIsExplainedByTheOtherPorts() {
        assertEquals(LgUnreachableReason.RESTART_NEEDED, LgUnreachableReason.probe("tv") { it == 9991 })
        assertEquals(LgUnreachableReason.DEV_MODE_OFF, LgUnreachableReason.probe("tv") { it == 3001 })
        assertEquals(LgUnreachableReason.DEV_MODE_OFF, LgUnreachableReason.probe("tv") { it == 3000 })
        assertEquals(LgUnreachableReason.TV_NOT_FOUND, LgUnreachableReason.probe("tv") { false })
    }
}
