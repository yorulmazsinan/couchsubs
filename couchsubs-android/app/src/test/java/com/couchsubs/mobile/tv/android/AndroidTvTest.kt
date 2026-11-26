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

    private fun dumpsys(
        version: String?,
        installer: String = "null",
        signatureHash: String? = AndroidTvInstaller.SIGNATURE_HASH
    ) =
        if (version == null) "Unable to find package: com.couchsubs.tv\n"
        else "Packages:\n  Package [com.couchsubs.tv] (abc):\n    versionCode=21 minSdk=21 targetSdk=34\n    versionName=$version\n    installerPackageName=$installer\n" +
            signatureHash?.let { "    signatures=PackageSignatures{a1b2c3 version:2, signatures:[$it], past signatures:[]}\n" }.orEmpty()

    private fun installer(adbd: FakeAdbd, key: AdbKey, steps: MutableList<InstallStep> = mutableListOf(), pairing: AndroidTvInstaller.Pairing? = null,
                          pairer: (AdbKey, AndroidTvInstaller.Pairing) -> Unit = { _, _ -> }) =
        AndroidTvInstaller("127.0.0.1", adbd.port, { key }, pairing, { steps += it }, pairer = pairer).apply { exitWaitMs = 0 }

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
        assertFalse(AndroidTvInstaller.canInstallExisting(leftover))
        // Kullanıcı satırı olmayan eski çıktı kalıntı değildir; ana kullanıcıda kuruluysa başka profil önemsizdir.
        assertFalse(AndroidTvInstaller.isLeftover("    versionName=0.9.18\n"))
        assertFalse(AndroidTvInstaller.isLeftover(installed + "    User 10: ceDataInode=2 installed=false\n"))
    }

    // #528: TV uygulamayı yalnız ana kullanıcıdan (User 0) kaldırmış, çocuk/ikincil profilde kurulu kalmış.
    private val multiProfile = """
        Packages:
          Package [com.couchsubs.tv] (5d1c2a7):
            userId=10123
            versionCode=918 minSdk=24 targetSdk=34
            versionName=0.9.18
            installerPackageName=null
            signatures=PackageSignatures{a1b2c3 version:2, signatures:[32d37cf9], past signatures:[]}
            User 0: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false
            User 10: ceDataInode=48213 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false
    """.trimIndent()

    @Test
    fun appRemovedOnlyFromMainUserCountsAsNotInstalled() {
        assertTrue(AndroidTvInstaller.isLeftover(multiProfile))
        assertNull(AndroidTvInstaller.installedVersionFromDumpsys(multiProfile))
        assertTrue(AndroidTvInstaller.canInstallExisting(multiProfile))
        assertTrue(AndroidTvInstaller.installExistingSucceeded("Package com.couchsubs.tv installed for user: 0\n"))
        assertFalse(AndroidTvInstaller.installExistingSucceeded("Failure [NameNotFoundException]"))
    }

    /** Güncellemede TV'de çalışan eski uygulama önce kapatılır (am force-stop), sonra kurulur ve temiz açılır. */
    @Test
    fun updateStopsTheRunningAppBeforeInstalling() {
        val key = tempKey()
        var installed = false
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys(if (installed) "0.9.104" else "0.9.90")
                service.startsWith("exec:cmd package install") -> { installed = true; "Success\n" }
                else -> ""
            }
        }).start()
        val result = installer(adbd, key).ensureInstalled({ apk }, "0.9.104")
        assertEquals(AndroidTvInstaller.Result("0.9.104", true), result)
        val stop = adbd.opened.indexOf(AndroidTvInstaller.FORCE_STOP_COMMAND)
        val install = adbd.opened.indexOfFirst { it.startsWith("exec:cmd package install") }
        val open = adbd.opened.indexOfFirst { it.startsWith("shell:am start -n") }
        assertTrue(adbd.opened.joinToString(" | "), stop >= 0 && install > stop && open > install)
        adbd.join()
    }

    /**
     * Bekçinin "kapat ve aç" denemesi (uygulama çalışıyordu ama 10 sn'de bağlanmadı): önce kapanma isteği (#1221), uygulama
     * hâlâ çalışıyorsa ya da bilinemiyorsa am force-stop, sonra am start (Samsung'daki was_kill + was_execute ile aynı sıra).
     */
    @Test
    fun restartAsksTheAppToExitThenForceStopsThenStarts() {
        val key = tempKey()
        val adbd = FakeAdbd(authorized = mutableListOf(key.publicKey), services = { _, _ -> "Starting: Intent { cmp=com.couchsubs.tv/.MainActivity }\n" }).start()
        val output = AndroidTvInstaller("127.0.0.1", adbd.port, { key }).apply { lane = com.couchsubs.mobile.tv.TvLane(); exitWaitMs = 0 }
            .open(null, restart = true)
        assertTrue(output.startsWith("Starting"))
        assertEquals(listOf(AndroidTvInstaller.EXIT_COMMAND, AndroidTvInstaller.RUNNING_COMMAND, AndroidTvInstaller.FORCE_STOP_COMMAND,
            "shell:am start -n com.couchsubs.tv/.MainActivity"), adbd.opened)
        adbd.join()
    }

    /**
     * #1221: TV uygulaması kapanma isteğiyle kapandıysa (HDMI'yı kendisi bıraktı) am force-stop gönderilmez; MediaTek'li
     * Philips Google TV'de öldürülen işlem HDMI'yı bırakmıyor, giriş TV kapatılana kadar siyah kalıyordu.
     */
    @Test
    fun appThatExitsOnRequestIsNotForceStopped() {
        val key = tempKey()
        val adbd = FakeAdbd(authorized = mutableListOf(key.publicKey), services = { service, _ ->
            if (service == AndroidTvInstaller.RUNNING_COMMAND) "    * Hist #0: ActivityRecord{2a1d9e1 u0 com.google.android.tvlauncher/.MainActivity t1}\n"
            else "Starting: Intent { cmp=com.couchsubs.tv/.MainActivity }\n"
        }).start()
        AndroidTvInstaller("127.0.0.1", adbd.port, { key }).apply { lane = com.couchsubs.mobile.tv.TvLane(); exitWaitMs = 0 }
            .open(null, restart = true)
        assertEquals(listOf(AndroidTvInstaller.EXIT_COMMAND, AndroidTvInstaller.RUNNING_COMMAND,
            "shell:am start -n com.couchsubs.tv/.MainActivity"), adbd.opened)
        adbd.join()
    }

    @Test
    fun forceStopIsNeededOnlyWhileTheAppStillShowsOrTheListCannotBeRead() {
        val launcher = "    * Hist #0: ActivityRecord{2a1d9e1 u0 com.google.android.tvlauncher/.MainActivity t1}"
        val ours = "    * Hist #1: ActivityRecord{6c1b2f0 u0 com.couchsubs.tv/.MainActivity t42}"
        assertFalse(AndroidTvInstaller.needsForceStop(launcher))
        assertTrue(AndroidTvInstaller.needsForceStop("$ours\n$launcher"))
        assertTrue(AndroidTvInstaller.needsForceStop("$launcher\n    ServiceRecord{1f2e u0 com.couchsubs.tv/.OverlayService}"))
        assertTrue(AndroidTvInstaller.needsForceStop(""))
        assertTrue(AndroidTvInstaller.needsForceStop("/system/bin/sh: grep: not found"))
        assertEquals("shell:am start -n com.couchsubs.tv/.MainActivity --ez exit true", AndroidTvInstaller.EXIT_COMMAND)
    }

    /** Güncel uygulamayı açarken TV "zaten çalışıyor, öne getirildi" derse eski ekran kapatılıp temiz açılır. */
    @Test
    fun upToDateAppThatWasAlreadyRunningIsRestarted() {
        val key = tempKey()
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys("0.9.104")
                service.startsWith("shell:am start") ->
                    "Starting: Intent { cmp=com.couchsubs.tv/.MainActivity }\nWarning: Activity not started, its current task has been brought to the front\n"
                else -> ""
            }
        }).start()
        assertEquals(AndroidTvInstaller.Result("0.9.104", false), installer(adbd, key).ensureInstalled({ apk }, "0.9.104"))
        val start = "shell:am start -n com.couchsubs.tv/.MainActivity"
        assertEquals(listOf(start, AndroidTvInstaller.EXIT_COMMAND, AndroidTvInstaller.FORCE_STOP_COMMAND, start),
            adbd.opened.filter { it.startsWith("shell:am ") })
        adbd.join()
    }

    /**
     * #1223: aynı TV'ye kurulum sürerken gelen ikinci kurulum isteği (ikinci "güncelle") yeni ADB oturumu açmaz, sürenin
     * sonucunu alır.
     */
    @Test
    fun secondInstallOnTheSameTvJoinsTheRunningOne() {
        val key = tempKey()
        val release = java.util.concurrent.CountDownLatch(1)
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> { release.await(); dumpsys("0.9.104") }
                else -> ""
            }
        }).start()
        val lane = com.couchsubs.mobile.tv.TvLane()
        val logFile = java.io.File.createTempFile("tvinstall", ".log").apply { deleteOnExit() }
        fun make() = AndroidTvInstaller("127.0.0.1", adbd.port, { key }, log = com.couchsubs.mobile.tv.samsung.InstallLog(logFile))
            .apply { this.lane = lane }
        var first: AndroidTvInstaller.Result? = null
        val worker = thread { first = make().ensureInstalled({ apk }, "0.9.104") }
        Thread.sleep(150)
        assertTrue(lane.isInstalling("127.0.0.1"))
        val joiner = thread { Thread.sleep(100); release.countDown() }
        val second = make().ensureInstalled({ apk }, "0.9.104")
        worker.join()
        joiner.join()
        assertEquals(first, second)
        val text = logFile.readText()
        assertEquals(1, Regex("--- Android TV kurulumu").findAll(text).count())
        assertTrue(text.contains("yeni kurulum başlatılmadı"))
        adbd.join()
    }

    /**
     * TV kurulum akışına yanıt vermiyor: önceden 120 sn'lik okuma süresinden sonra "bağlantı koptu" deniyordu, yeniden
     * deneme yoktu. Bekçi adımın süresi dolunca bağlantıyı kapatır, yeni bağlantıyla bir kez daha dener.
     */
    @Test
    fun stalledInstallIsRetriedOnceOnAFreshConnection() {
        val key = tempKey()
        var installs = 0
        var installed = false
        val adbd = FakeAdbd(toleratesDrop = true, services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys(if (installed) "0.9.104" else "0.9.90")
                service.startsWith("exec:cmd package install") -> {
                    installs++
                    // İlk kurulumda TV takılıyor (kurmuyor, yanıt vermiyor); ikinci bağlantıda kuruyor.
                    if (installs == 1) Thread.sleep(1_500) else installed = true
                    "Success\n"
                }
                else -> ""
            }
        }).start(connections = 2)
        val logFile = java.io.File.createTempFile("tvinstall", ".log").apply { deleteOnExit() }
        val installer = AndroidTvInstaller("127.0.0.1", adbd.port, { key }, log = com.couchsubs.mobile.tv.samsung.InstallLog(logFile))
        installer.stallLimits = { if (it == "installing") 300L else 10_000L }
        installer.exitWaitMs = 0
        val result = installer.ensureInstalled({ apk }, "0.9.104")
        assertTrue(result.installed)
        assertEquals("0.9.104", result.version)
        assertTrue(logFile.readText().contains("bir kez daha deneniyor"))
        adbd.join()
    }

    /** İkinci denemede de takılırsa kullanıcıya "bağlantı koptu, tekrar dene" (CONNECTION_LOST) ve sebebi gösterilir. */
    @Test
    fun secondStallEndsWithConnectionLost() {
        val key = tempKey()
        val adbd = FakeAdbd(toleratesDrop = true, services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") -> dumpsys("0.9.90")
                service.startsWith("exec:cmd package install") -> { Thread.sleep(1_000); "Success\n" }
                else -> ""
            }
        }).start(connections = 2)
        val installer = installer(adbd, key)
        installer.stallLimits = { if (it == "installing") 300L else 10_000L }
        installer.exitWaitMs = 0
        val error = expect<AndroidInstallException> { installer.ensureInstalled({ apk }, "0.9.104") }
        assertEquals(AndroidInstallError.CONNECTION_LOST, error.error)
        assertTrue(error.detail!!.contains("bir kez daha denendi"))
        adbd.join()
    }

    @Test
    fun appRemovedOnlyFromMainUserIsBroughtBackWithoutApk() {
        val key = tempKey()
        var restored = false
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") ->
                    if (restored) multiProfile.replace("User 0: ceDataInode=0 installed=false", "User 0: ceDataInode=0 installed=true")
                    else multiProfile
                service == AndroidTvInstaller.INSTALL_EXISTING_COMMAND -> { restored = true; "Package com.couchsubs.tv installed for user: 0\n" }
                else -> ""
            }
        }).start()
        val result = installer(adbd, key, mutableListOf()).ensureInstalled({ apk }, "0.9.18")
        assertEquals(AndroidTvInstaller.Result("0.9.18", false), result)
        assertTrue(adbd.opened.contains(AndroidTvInstaller.INSTALL_EXISTING_COMMAND))
        assertFalse(adbd.opened.any { it.startsWith("exec:cmd package install ") })
        assertTrue(adbd.opened.any { it.startsWith("shell:am start -n") })
        adbd.join()
    }

    @Test
    fun appRemovedOnlyFromMainUserIsInstalledWhenInstallExistingFails() {
        val key = tempKey()
        var installed = false
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                service.startsWith("shell:dumpsys") ->
                    if (installed) multiProfile.replace("User 0: ceDataInode=0 installed=false", "User 0: ceDataInode=0 installed=true")
                    else multiProfile
                service == AndroidTvInstaller.INSTALL_EXISTING_COMMAND -> "Error: unknown command\n"
                service.startsWith("exec:cmd package install ") -> { installed = true; "Success\n" }
                else -> ""
            }
        }).start()
        val result = installer(adbd, key, mutableListOf()).ensureInstalled({ apk }, "0.9.18")
        assertEquals(AndroidTvInstaller.Result("0.9.18", true), result)
        assertTrue(adbd.opened.any { it.startsWith("exec:cmd package install ") })
        adbd.join()
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
    fun recognisesOurSignatureAndOtherApps() {
        val newFormat = "    signatures=PackageSignatures{a1b2c3 version:2, signatures:[32d37cf9], past signatures:[]}\n"
        val oldFormat = "    signatures=PackageSignatures{41ab21 [32d37cf9]}\n"
        val other = "    signatures=PackageSignatures{a1b2c3 version:3, signatures:[1f2e3d4c], past signatures:[]}\n"
        assertEquals(listOf("32d37cf9"), AndroidTvInstaller.signatureHashes(newFormat))
        assertEquals(listOf("32d37cf9"), AndroidTvInstaller.signatureHashes(oldFormat))
        assertFalse(AndroidTvInstaller.isForeign(dumpsys("0.9.74") + newFormat))
        assertFalse(AndroidTvInstaller.isForeign(dumpsys("0.9.74") + oldFormat.replace("32d37cf9", "32D37CF9")))
        assertTrue(AndroidTvInstaller.isOurs(dumpsys("0.9.74") + newFormat))
        assertTrue(AndroidTvInstaller.isForeign(dumpsys("2.0.0", signatureHash = null) + other))
        // İmza satırı yok ya da uygulama yok: bilinmiyor, başka uygulama sayılmaz.
        assertFalse(AndroidTvInstaller.isForeign(dumpsys("2.0.0", signatureHash = null)))
        assertFalse(AndroidTvInstaller.isForeign(dumpsys(null) + other))
    }

    @Test
    fun otherAppWithOurIdIsRemovedOnlyWithConsent() {
        val key = tempKey()
        var removed = false
        val other = "    signatures=PackageSignatures{a1b2c3 version:3, signatures:[1f2e3d4c], past signatures:[]}\n"
        val adbd = FakeAdbd(services = { service, _ ->
            when {
                // Sürümü bizimkinden yeni: eskiden "güncel" sayılıp o uygulama açılıyordu.
                service.startsWith("shell:dumpsys") -> if (removed) dumpsys(null) else dumpsys("9.9.9", signatureHash = null) + other
                service.startsWith("exec:cmd package install") -> "Success\n"
                service == "shell:pm uninstall com.couchsubs.tv" -> { removed = true; "Success\n" }
                else -> ""
            }
        }).start(connections = 2)
        val error = expect<AndroidInstallException> { installer(adbd, key).ensureInstalled({ apk }, "0.9.18") }
        assertEquals(AndroidInstallError.FOREIGN_APP, error.error)
        assertFalse(removed)
        assertFalse(adbd.opened.any { it.contains("uninstall") || it.startsWith("exec:") || it.contains("am start") })

        val result = installer(adbd, key).ensureInstalled({ apk }, "0.9.18", allowReplace = true)
        assertTrue(result.installed)
        assertTrue(removed)
        adbd.join()
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
        // İmza tutmuyor ve imza özeti okunamadı: başka bir uygulama olabilir, aynı onay sorulur.
        assertEquals(AndroidInstallError.FOREIGN_APP, error.error)
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

    @Test
    fun startCommandCarriesOnlySafeLaunchParams() {
        val plain = "shell:am start -n com.couchsubs.tv/.MainActivity"
        val params = AndroidTvInstaller.launchParams("http://192.168.1.124:8787")
        assertEquals("""{"server":"http://192.168.1.124:8787"}""", params)
        assertEquals("""$plain --es params '{"server":"http://192.168.1.124:8787"}'""", AndroidTvInstaller.startCommand(params))
        assertEquals(plain, AndroidTvInstaller.startCommand(null))
        assertEquals(plain, AndroidTvInstaller.startCommand(""))
        assertEquals(plain, AndroidTvInstaller.startCommand("""{"server":"x'; reboot; '"}"""))
        assertEquals(plain, AndroidTvInstaller.startCommand("{\"a\":\"b\"}\nreboot"))
        assertEquals(null, AndroidTvInstaller.launchParams("http://x\"y"))
    }

    /** Çalışan TV uygulamasına adres ekranı öne çekmeden yayınla bildirilir (Windows/Mac ve iPhone'la aynı komut). */
    @Test
    fun addressCommandCarriesOnlySafeLaunchParams() {
        val params = AndroidTvInstaller.launchParams("http://192.168.1.124:8787")
        assertEquals(
            """shell:am broadcast -a com.couchsubs.tv.action.ADDRESS -n com.couchsubs.tv/.AddressReceiver --es params '{"server":"http://192.168.1.124:8787"}'""",
            AndroidTvInstaller.addressCommand(params))
        assertEquals(null, AndroidTvInstaller.addressCommand(null))
        assertEquals(null, AndroidTvInstaller.addressCommand("""{"server":"x'; reboot; '"}"""))
    }
}
