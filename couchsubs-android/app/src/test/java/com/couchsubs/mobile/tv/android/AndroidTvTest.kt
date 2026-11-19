// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.android

import com.couchsubs.mobile.tv.samsung.AdbKey
import com.couchsubs.mobile.tv.samsung.InstallStep
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import kotlin.concurrent.thread

/** ADB paket biçimi, imza, sahte adbd'ye karşı bağlantı ve kurulum, kablosuz hata ayıklama (TLS, eşleme), SPAKE2. */
class AndroidTvTest {
    private val apk = ByteArray(300_000) { (it * 31).toByte() }

    private fun dumpsys(version: String?, installer: String = "null") =
        if (version == null) "Unable to find package: com.couchsubs.tv\n"
        else "Packages:\n  Package [com.couchsubs.tv] (abc):\n    versionCode=21 minSdk=21 targetSdk=34\n    versionName=$version\n    installerPackageName=$installer\n"

    private fun installer(adbd: FakeAdbd, key: AdbKey, steps: MutableList<InstallStep> = mutableListOf(), pairing: AndroidTvInstaller.Pairing? = null,
                          pairer: (AdbKey, AndroidTvInstaller.Pairing) -> Unit = { _, _ -> }) =
        AndroidTvInstaller("127.0.0.1", adbd.port, { key }, pairing, { steps += it }, pairer = pairer)

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
    fun packetHeaderIsLittleEndianAndZeroChecksumIsAccepted() {
        val bytes = AdbPacket.encode(AdbPacket(AdbPacket.CNXN, AdbConnection.VERSION, 256 * 1024, "host::\u0000".toByteArray()))
        assertEquals("434e584e" + "01000001" + "00000400" + "07000000",
            bytes.copyOfRange(0, 16).joinToString("") { "%02x".format(it) })
        assertEquals(AdbPacket.CNXN xor -1, ByteBuffer.wrap(bytes, 20, 4).order(ByteOrder.LITTLE_ENDIAN).int)
        // Yeni adbd denetim toplamını 0 gönderir.
        val zeroed = bytes.copyOf().also { for (i in 16 until 20) it[i] = 0 }
        val read = AdbPacket.read(ByteArrayInputStream(zeroed))
        assertEquals(AdbPacket.CNXN, read.command)
        assertEquals("host::\u0000", String(read.payload))
        expect<java.io.IOException> { AdbPacket.read(ByteArrayInputStream(bytes.copyOf().also { it[20] = 0 })) }
        assertEquals("STLS", String(AdbPacket.encode(AdbPacket(AdbPacket.STLS, 0, 0)), 0, 4))
    }

    @Test
    fun adbSignatureSignsTokenWithoutHashingItAgain() {
        val key = tempKey()
        val token = ByteArray(20) { it.toByte() }
        val signature = key.signAdbToken(token)
        assertEquals(256, signature.size)
        assertTrue(adbSignatureValid(key.publicKey, token, signature))
        // JVM'in "NONEwithRSA"sıyla (DigestInfo önekli jeton) aynı sonuç.
        val private = java.security.KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(key.privateKeyBytes()))
        val expected = Signature.getInstance("NONEwithRSA").run {
            initSign(private)
            update(byteArrayOf(0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14) + token)
            sign()
        }
        assertArrayEquals(expected, signature)
        // Samsung'un sdb imzası jetonu özetler; ADB'ninki bundan farklıdır.
        assertFalse(adbSignatureValid(key.publicKey, token, key.sign(token)))
        assertEquals(key.publicKey, decodePublicKeyLine(key.publicKeyLine("x@y")))
    }

    @Test
    fun parsesAddressesAndDumpsys() {
        assertEquals("192.168.1.5" to 5555, AndroidTvInstaller.parseAddress(" 192.168.1.5 "))
        assertEquals("192.168.1.5" to 37123, AndroidTvInstaller.parseAddress("192.168.1.5:37123"))
        assertNull(AndroidTvInstaller.parseAddress("192.168.1.5:abc"))
        assertNull(AndroidTvInstaller.parseAddress(""))
        assertEquals("0.9.18", AndroidTvInstaller.versionFromDumpsys(dumpsys("0.9.18")))
        assertNull(AndroidTvInstaller.versionFromDumpsys(dumpsys(null)))
        assertTrue(AndroidTvInstaller.installedFromPlay(dumpsys("0.9.18", "com.android.vending")))
        assertFalse(AndroidTvInstaller.installedFromPlay(dumpsys("0.9.18")))
        assertTrue(AndroidTvInstaller.needsReplace("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package com.couchsubs.tv signatures do not match]"))
        assertTrue(AndroidTvInstaller.isStorageProblem("Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"))
        assertTrue(AndroidTvInstaller.streamInstallUnsupported("/system/bin/sh: cmd: not found"))
        assertFalse(AndroidTvInstaller.streamInstallUnsupported("Success"))
    }

    // #352, #389: TV'den kaldırılan uygulamanın kaydı kalmış; dumpsys sürümü söylüyor ama hiçbir kullanıcıda kurulu değil.
    @Test
    fun leftoverRecordOfAnUninstalledAppCountsAsNotInstalled() {
        val installed = "    versionName=0.9.18\n    User 0: ceDataInode=1 installed=true hidden=false\n"
        val leftover = installed.replace("installed=true", "installed=false")
        assertFalse(AndroidTvInstaller.isLeftover(installed))
        assertEquals("0.9.18", AndroidTvInstaller.installedVersionFromDumpsys(installed))
        assertTrue(AndroidTvInstaller.isLeftover(leftover))
        assertNull(AndroidTvInstaller.installedVersionFromDumpsys(leftover))
        // Başka bir profilde kuruluysa kalıntı değildir; kullanıcı satırı olmayan eski çıktı da öyle.
        assertFalse(AndroidTvInstaller.isLeftover(leftover + "    User 10: ceDataInode=2 installed=true\n"))
        assertFalse(AndroidTvInstaller.isLeftover("    versionName=0.9.18\n"))
    }

    @Test
    fun leftoverRecordIsInstalledAgain() {
        val key = tempKey()
        var installed = false
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") ->
                    "    versionName=0.9.18\n    User 0: ceDataInode=1 installed=$installed hidden=false\n"
                service.startsWith("exec:cmd package install") -> { installed = true; "Success\n" }
                else -> ""
            }
        }).start()
        val result = installer(adbd, key, mutableListOf()).ensureInstalled({ apk }, "0.9.18")
        assertEquals(AndroidTvInstaller.Result("0.9.18", true), result)
        assertTrue(adbd.opened.any { it.startsWith("exec:cmd package install") })
        adbd.join()
    }

    @Test
    fun firstConnectionAsksApprovalThenInstallsGrantsOverlayAndLaunches() {
        val key = tempKey()
        var installed: String? = null
        val adbd = FakeAdbd(services = { service, data ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys(installed)
                service.startsWith("exec:cmd package install") -> { assertArrayEquals(apk, data); installed = "0.9.18"; "Success\n" }
                service.startsWith("shell:am start") -> "Starting: Intent { cmp=com.couchsubs.tv/.MainActivity }\n"
                else -> ""
            }
        }).start(connections = 2)
        val steps = mutableListOf<InstallStep>()
        val result = installer(adbd, key, steps).ensureInstalled({ apk }, "0.9.18")
        assertEquals(AndroidTvInstaller.Result("0.9.18", true), result)
        assertTrue(adbd.approvalAsked)
        assertTrue(InstallStep.APPROVE_ON_TV in steps)
        assertEquals(listOf("shell:dumpsys package com.couchsubs.tv", "exec:cmd package install -r -S ${apk.size}",
            "shell:appops set com.couchsubs.tv SYSTEM_ALERT_WINDOW allow", "shell:dumpsys package com.couchsubs.tv",
            "shell:am start -n com.couchsubs.tv/.MainActivity"), adbd.opened)

        // İkinci kez: anahtar tanınıyor, onay sorulmuyor; sürüm güncel, yalnız açılıyor.
        adbd.approvalAsked = false
        adbd.opened.clear()
        val again = mutableListOf<InstallStep>()
        assertEquals(AndroidTvInstaller.Result("0.9.18", false), installer(adbd, key, again).ensureInstalled({ apk }, "0.9.18"))
        assertFalse(adbd.approvalAsked)
        assertFalse(InstallStep.APPROVE_ON_TV in again)
        assertFalse(adbd.opened.any { it.contains("install") })
        adbd.join()
    }

    @Test
    fun refusedApprovalIsReported() {
        val adbd = FakeAdbd(approve = false).start()
        val error = expect<AndroidInstallException> { installer(adbd, tempKey()).ensureInstalled({ apk }, "0.9.18") }
        assertEquals(AndroidInstallError.NOT_APPROVED, error.error)
        adbd.join()
    }

    @Test
    fun closedPortIsUnreachable() {
        val port = ServerSocket(0).use { it.localPort }
        val error = expect<AndroidInstallException> {
            AndroidTvInstaller("127.0.0.1", port, { tempKey() }).ensureInstalled({ apk }, "0.9.18")
        }
        assertEquals(AndroidInstallError.UNREACHABLE, error.error)
    }

    @Test
    fun playCopyIsNotRemovedWithoutConsent() {
        val key = tempKey()
        var removed = false
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys(if (removed) null else "0.9.10", "com.android.vending")
                service.startsWith("exec:cmd package install") ->
                    if (removed) "Success\n" else "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]\n"
                service == "shell:pm uninstall com.couchsubs.tv" -> { removed = true; "Success\n" }
                else -> ""
            }
        }).start(connections = 2)
        val error = expect<AndroidInstallException> { installer(adbd, key).ensureInstalled({ apk }, "0.9.18") }
        assertEquals(AndroidInstallError.REPLACE_NEEDED, error.error)
        assertTrue(error.installedFromPlay)
        assertFalse(removed)
        assertFalse(adbd.opened.any { it.contains("uninstall") })

        // Kullanıcı onaylayınca kaldırılıp kurulur.
        val steps = mutableListOf<InstallStep>()
        val result = installer(adbd, key, steps).ensureInstalled({ apk }, "0.9.18", allowReplace = true)
        assertTrue(result.installed)
        assertTrue(removed)
        assertTrue(InstallStep.UNINSTALLING in steps)
        adbd.join()
    }

    @Test
    fun oldTvWithoutCmdGetsPushAndPmInstall() {
        val key = tempKey()
        val adbd = FakeAdbd(expectedInput = { 0 }, services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys(null)
                // Android 6: cmd yok; exec: veriyi okumadan kapanır.
                service.startsWith("exec:") -> "/system/bin/sh: cmd: not found\n"
                service == "shell:pm install -r /data/local/tmp/couchsubs-tv.apk" -> "\tpkg: /data/local/tmp/couchsubs-tv.apk\nSuccess\n"
                else -> ""
            }
        }).start()
        val result = installer(adbd, key).ensureInstalled({ apk }, "0.9.18")
        assertTrue(result.installed)
        assertArrayEquals(apk, adbd.received["sync:"])
        assertTrue("shell:rm -f /data/local/tmp/couchsubs-tv.apk" in adbd.opened)
        adbd.join()
    }

    @Test
    fun storageFailureIsReported() {
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys(null)
                service.startsWith("exec:") -> "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]\n"
                else -> ""
            }
        }).start()
        val error = expect<AndroidInstallException> { installer(adbd, tempKey()).ensureInstalled({ apk }, "0.9.18") }
        assertEquals(AndroidInstallError.NOT_ENOUGH_SPACE, error.error)
        adbd.join()
    }

    @Test
    fun wirelessDebuggingPortUsesTlsWithThePairedKey() {
        val key = tempKey()
        val adbd = FakeAdbd(authorized = mutableListOf(key.publicKey), tlsKey = tempKey("tv"), services = { service, _ ->
            if (service.startsWith("shell:dumpsys")) dumpsys("0.9.18") else ""
        }).start()
        val result = installer(adbd, key).ensureInstalled({ apk }, "0.9.18")
        assertEquals(AndroidTvInstaller.Result("0.9.18", false), result)
        assertEquals(FakeTlsServer.sha256(key.publicKey.encoded), adbd.tlsClientKeyHash)
        adbd.join()
    }

    @Test
    fun wirelessDebuggingWithoutPairingSaysNotPaired() {
        val adbd = FakeAdbd(tlsKey = tempKey("tv")).start()
        val error = expect<AndroidInstallException> { installer(adbd, tempKey()).ensureInstalled({ apk }, "0.9.18") }
        assertEquals(AndroidInstallError.NOT_PAIRED, error.error)
        adbd.join()
    }

    @Test
    fun spake2BothSidesAgreeOnlyWithTheSameCode() {
        val alice = Spake2(alice = true, password = "123456".toByteArray())
        val bob = Spake2(alice = false, password = "123456".toByteArray())
        val a = alice.finish(bob.message)
        val b = bob.finish(alice.message)
        assertNotNull(a)
        assertEquals(64, a!!.size)
        assertArrayEquals(a, b)
        val wrong = Spake2(alice = false, password = "654321".toByteArray())
        assertFalse(alice.finish(wrong.message).contentEquals(wrong.finish(alice.message)))
        // RFC 8032 taban noktasının kodlaması: y = 4/5.
        assertEquals("5866666666666666666666666666666666666666666666666666666666666666",
            EdPoint.BASE.encode().joinToString("") { "%02x".format(it) })
        assertNull(Spake2(true, "1".toByteArray()).finish(ByteArray(31)))
    }

    @Test
    fun pairingCipherMatchesBothDirections() {
        val material = ByteArray(64) { it.toByte() }
        val ours = AdbPairing.PairingCipher(material)
        val theirs = AdbPairing.PairingCipher(material)
        val sealed = ours.encrypt("merhaba".toByteArray())
        assertEquals(7 + 16, sealed.size)
        assertArrayEquals("merhaba".toByteArray(), theirs.decrypt(sealed))
        assertNull(AdbPairing.PairingCipher(ByteArray(64)).decrypt(ours.encrypt("x".toByteArray())))
        // RFC 5869 A.3 (tuzsuz, bilgisiz) ilk 16 bayt.
        val ikm = ByteArray(22) { 0x0b }
        assertEquals("8da4e775a563c18f715f802a063c5a31",
            AdbPairing.PairingCipher.hkdf(ikm, ByteArray(0), 16).joinToString("") { "%02x".format(it) })
    }

    /** Sahte TV'nin eşleme sunucusu: TLS, SPAKE2 (bob) ve şifreli eş bilgisi. Öğrendiği açık anahtar satırını döner. */
    private fun pairingServer(code: String, tvKey: AdbKey): Pair<Int, () -> String?> {
        val server = ServerSocket(0)
        var learned: String? = null
        var failure: Throwable? = null
        val worker = thread(isDaemon = true) {
            try {
                server.accept().use { socket ->
                    val (tls, protocol) = FakeTlsServer.start(socket.getInputStream(), socket.getOutputStream(), tvKey)
                    val password = code.toByteArray() + tls.exported!!
                    val bob = Spake2(alice = false, password = password)
                    val theirs = AdbPairing.readPacket(protocol.inputStream, AdbPairing.SPAKE2_MESSAGE)
                    AdbPairing.writePacket(protocol.outputStream, AdbPairing.SPAKE2_MESSAGE, bob.message)
                    val cipher = AdbPairing.PairingCipher(bob.finish(theirs)!!)
                    val info = cipher.decrypt(AdbPairing.readPacket(protocol.inputStream, AdbPairing.PEER_INFO_MESSAGE))
                    if (info == null) {
                        // Gerçek adbd yanlış kodda bağlantıyı kapatır.
                        protocol.close()
                        return@use
                    }
                    val end = (1 until info.size).firstOrNull { info[it] == 0.toByte() } ?: info.size
                    learned = String(info, 1, end - 1)
                    val mine = ByteArray(AdbPairing.PEER_INFO_SIZE).also { tvKey.publicKeyLine("tv@fake").toByteArray().copyInto(it, 1) }
                    AdbPairing.writePacket(protocol.outputStream, AdbPairing.PEER_INFO_MESSAGE, cipher.encrypt(mine))
                    protocol.close()
                }
            } catch (error: Throwable) {
                failure = error
            } finally {
                server.close()
            }
        }
        return server.localPort to {
            worker.join(10_000)
            failure?.let { throw AssertionError("sahte eşleme sunucusu", it) }
            learned
        }
    }

    @Test
    fun pairingWithTheRightCodeTeachesTheTvOurKey() {
        val key = tempKey()
        val (port, result) = pairingServer("482913", tempKey("tv"))
        AdbPairing.pair("127.0.0.1", port, " 482913 ", key)
        assertEquals(key.publicKeyLine(AdbConnection.KEY_NAME), result())
    }

    @Test
    fun pairingWithAWrongCodeFails() {
        val (port, result) = pairingServer("482913", tempKey("tv"))
        val error = expect<AndroidInstallException> { AdbPairing.pair("127.0.0.1", port, "111111", tempKey()) }
        assertEquals(AndroidInstallError.PAIRING_FAILED, error.error)
        assertNull(result())
    }

    @Test
    fun installerPairsFirstWhenAPairingCodeIsGiven() {
        val key = tempKey()
        val adbd = FakeAdbd(services = { service, _ -> if (service.startsWith("shell:dumpsys")) dumpsys("0.9.18") else "" }).start()
        var paired: AndroidTvInstaller.Pairing? = null
        val steps = mutableListOf<InstallStep>()
        installer(adbd, key, steps, AndroidTvInstaller.Pairing(41000, "123456")) { _, pairing ->
            paired = pairing
            adbd.authorized += key.publicKey
        }.ensureInstalled({ apk }, "0.9.18")
        assertEquals(AndroidTvInstaller.Pairing(41000, "123456"), paired)
        assertEquals(InstallStep.PAIRING, steps.first())
        assertFalse(adbd.approvalAsked)
        adbd.join()
    }
}
