// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.samsung

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files

/** Samsung kurulum hatalarının ayrımı ve eski kopyayı kaldırıp yeniden kurma (masaüstündeki SamsungInstallTests'in örnekleri). */
class SamsungInstallerTest {
    private val success = "Push complete.\napp_id[CouchSubsT.CouchSubs] installing[100]\nspend time for pkgcmd is [1234]ms\ncmd_ret:0"
    private val mismatch = "app_id[CouchSubsT.CouchSubs] install failed[118, -12]\nreason: Check certificate error : :Package with the same id and different certificate has been already installed.:<-12>\ncmd_ret:0"
    private val authorMismatch = "app_id[CouchSubsT.CouchSubs] install failed[118, -11], reason: Author certificate not match :"
    private val invalidFormat = "app_id[CouchSubsT.CouchSubs] install failed[118, -12]\nreason: Check certificate error : :Invalid format of certificate in signature.:<-2>"
    private val notYetValid = "install failed[118, -12] Check certificate error : :Certificate in signature is not valid yet.:<-7>"
    private val blocked = "app_id[CouchSubsT.CouchSubs] install failed[118, -22]\nreason: Security error : :Invalid function parameter was given:<2>"

    @Test
    fun installOutputIsClassified() {
        val cases = listOf(
            success to InstallProblem.NONE,
            mismatch to InstallProblem.CERTIFICATE_MISMATCH,
            authorMismatch to InstallProblem.CERTIFICATE_MISMATCH,
            "install failed[118012]" to InstallProblem.CERTIFICATE_MISMATCH,
            invalidFormat to InstallProblem.CERTIFICATE_REJECTED,
            "install failed[118, -12] Check certificate error : :Certificate in signature is expired.:<-6>" to InstallProblem.CERTIFICATE_REJECTED,
            notYetValid to InstallProblem.CERTIFICATE_NOT_YET_VALID,
            blocked to InstallProblem.PACKAGE_BLOCKED,
            "install failed[118022]" to InstallProblem.PACKAGE_BLOCKED,
            "app_id[CouchSubsT.CouchSubs] download failed[116]" to InstallProblem.NOT_ENOUGH_SPACE,
            "install failed[118, -4] operation not allowed" to InstallProblem.INCOMPATIBLE,
            "error: transport connection closed" to InstallProblem.CONNECTION_LOST,
            "install failed: IOException: Remote closed channel before sending OKAY" to InstallProblem.OTHER,
            "app_id[CouchSubsT.CouchSubs] install failed[118]" to InstallProblem.OTHER,
            "install failed: SocketException: Broken pipe" to InstallProblem.CONNECTION_LOST,
        )
        for ((output, expected) in cases) assertEquals(output, expected, SamsungDiagnostics.classify(output))
    }

    @Test
    fun tizenVersionGate() {
        val cases = listOf("2.3.1" to (true to false), "2.4" to (false to true), "2.4.0" to (false to true), "3.0" to (false to true), "4.0" to (false to true),
            "4.0.0" to (false to true), "5.0" to (false to false), "6.5" to (false to false), "9.0" to (false to false), "" to (false to false))
        for ((platform, expected) in cases) {
            assertEquals(platform, expected.first, SamsungInstaller.isTooOld(platform))
            assertEquals(platform, expected.second, SamsungInstaller.needsDeviceProfile(platform))
        }
    }

    @Test
    fun installedVersionIsReadFromTheAppList() {
        val rule = "\t------------------------------------------------------------------------"
        val listing = listOf("\tApplication List for user 5001", "\tUser's Application ", "\t Name \t AppID ", rule,
            "\t-------------app_title  =  Jellyfin----------------------------",
            "\t-------------app_tizen_id  =  AprZAARz4r.Jellyfin-----------------",
            "\t-------------app_version  =  1.2.3-----------------------------", rule,
            "\t-------------app_title  =  CouchSubs----------------------------",
            "\t-------------app_tizen_id  =  CouchSubsT.CouchSubs----------------",
            "\t-------------app_version  =  0.9.7-----------------------------", rule,
            "\tapps count: 2").joinToString("\n")
        assertEquals("0.9.7", SamsungDiagnostics.installedVersion(listing))
        assertNull(SamsungDiagnostics.installedVersion(listing.replace("CouchSubsT.CouchSubs", "Baska.App")))
        assertNull(SamsungDiagnostics.installedVersion("closed"))
        assertNull(SamsungDiagnostics.installedVersion(null))
    }

    @Test
    fun versionsCompareNumerically() {
        assertTrue(SamsungDiagnostics.isNewer("0.10.0", "0.9.9"))
        assertFalse(SamsungDiagnostics.isNewer("0.9.18", "0.9.18"))
        assertTrue(SamsungDiagnostics.isNewer("1.0", "0.9.18"))
        assertFalse(SamsungDiagnostics.isNewer("3.0", "4.0.0"))
    }

    @Test
    fun duidAndFolderNames() {
        assertTrue(SamsungInstaller.isDuid("QJCDF4ABCDEFG"))
        assertFalse(SamsungInstaller.isDuid("closed"))
        assertFalse(SamsungInstaller.isDuid("error: not found"))
        assertEquals("AB_CD_", SamsungInstaller.safeName("AB/CD="))
    }

    @Test
    fun unrelatedFailedWordIsNotAFailure() {
        assertFalse(SamsungDiagnostics.failed("Pull skipped or failed: not found\ninstalling[100]"))
        assertEquals(InstallProblem.NONE, SamsungDiagnostics.classify(""))
    }

    @Test
    fun summaryKeepsTheTvsErrorLine() {
        val summary = SamsungDiagnostics.summary("Push complete.\n$blocked\ncmd_ret:0")
        assertTrue(summary.contains("install failed[118, -22]"))
        assertTrue(summary.contains("Security error"))
        assertFalse(summary.contains("Push complete"))
        assertEquals("TV yanıt vermedi", SamsungDiagnostics.summary(" "))
    }

    @Test
    fun errorsMapToSpecificCodes() {
        assertEquals(SamsungInstallError.CERTIFICATE_MISMATCH, SamsungDiagnostics.toError(InstallProblem.CERTIFICATE_MISMATCH))
        assertEquals(SamsungInstallError.CERTIFICATE_REJECTED, SamsungDiagnostics.toError(InstallProblem.CERTIFICATE_REJECTED))
        assertEquals(SamsungInstallError.TV_CLOCK_WRONG, SamsungDiagnostics.toError(InstallProblem.CERTIFICATE_NOT_YET_VALID))
        assertEquals(SamsungInstallError.PACKAGE_BLOCKED, SamsungDiagnostics.toError(InstallProblem.PACKAGE_BLOCKED))
        assertEquals(SamsungInstallError.NOT_ENOUGH_SPACE, SamsungDiagnostics.toError(InstallProblem.NOT_ENOUGH_SPACE))
        assertEquals(SamsungInstallError.CONNECTION_LOST, SamsungDiagnostics.toError(InstallProblem.CONNECTION_LOST))
        assertEquals(SamsungInstallError.INSTALL_FAILED, SamsungDiagnostics.toError(InstallProblem.INCOMPATIBLE))
    }

    private class FakeTv(vararg outputs: String) : SamsungTvShell {
        private val queue = ArrayDeque(outputs.toList())
        var installs = 0
        val commands = ArrayList<String>()
        var uninstallError: IOException? = null
        override fun install(): String {
            installs++
            return queue.removeFirst()
        }
        override fun shell(command: String): String {
            commands.add(command)
            uninstallError?.let { throw it }
            return "ok"
        }
    }

    private fun tempLog() = InstallLog(File(Files.createTempDirectory("log").toFile(), "tvinstall.log"))

    @Test
    fun oldCopyWithAnotherCertificateIsRemovedAndInstalledAgain() {
        val tv = FakeTv(mismatch, success)
        val log = tempLog()
        val steps = ArrayList<InstallStep>()
        SamsungInstaller.installWithRecovery(tv, { steps.add(it) }, log)
        assertEquals(2, tv.installs)
        assertEquals(listOf("0 vd_appuninstall CouchSubsT", "0 vd_appuninstall CouchSubsT.CouchSubs"), tv.commands)
        assertEquals(listOf(InstallStep.UNINSTALLING), steps)
        val text = log.file!!.readText()
        assertTrue(text.contains("install failed[118, -12]"))
        assertTrue(text.contains("installing[100]"))
    }

    @Test
    fun successfulInstallRemovesNothing() {
        val tv = FakeTv(success)
        SamsungInstaller.installWithRecovery(tv, {}, InstallLog(null))
        assertEquals(1, tv.installs)
        assertTrue(tv.commands.isEmpty())
    }

    @Test
    fun mismatchThatStaysAfterRemovalIsReportedWithTheTvsWords() {
        val error = expectFailure(FakeTv(authorMismatch, authorMismatch))
        assertEquals(SamsungInstallError.CERTIFICATE_MISMATCH, error.error)
        assertTrue(error.detail!!.contains("Author certificate not match"))
    }

    @Test
    fun blockedPackageIdIsReportedAfterOneRetry() {
        val tv = FakeTv(blocked, blocked)
        val error = expectFailure(tv)
        assertEquals(SamsungInstallError.PACKAGE_BLOCKED, error.error)
        assertTrue(error.detail!!.contains("118, -22"))
        assertEquals(2, tv.commands.size)
    }

    @Test
    fun removingTheOldCopyIsNotTriedWhenItCannotHelp() {
        val cases = listOf(invalidFormat to SamsungInstallError.CERTIFICATE_REJECTED, notYetValid to SamsungInstallError.TV_CLOCK_WRONG,
            "download failed[116]" to SamsungInstallError.NOT_ENOUGH_SPACE, "connection reset by peer" to SamsungInstallError.CONNECTION_LOST)
        for ((output, expected) in cases) {
            val tv = FakeTv(output)
            assertEquals(expected, expectFailure(tv).error)
            assertTrue(tv.commands.isEmpty())
            assertEquals(1, tv.installs)
        }
    }

    @Test
    fun failingUninstallStillRetriesAndIsLogged() {
        val tv = FakeTv(mismatch, success).apply { uninstallError = IOException("Remote closed channel") }
        val log = tempLog()
        SamsungInstaller.installWithRecovery(tv, {}, log)
        assertEquals(2, tv.installs)
        assertTrue(log.file!!.readText().contains("Remote closed channel"))
    }

    @Test
    fun unreachableTvIsReportedAsSuch() {
        val profiles = Files.createTempDirectory("profiles").toFile()
        val key = AdbKey.loadOrCreate(File(profiles, "adbkey"))
        // Kimse dinlemiyor: geliştirici modu kapalı ya da adres yanlış.
        val installer = SamsungInstaller("127.0.0.1", profiles, { key }, SamsungCertificates(), signIn = null)
        try {
            installer.ensureInstalled({ ByteArray(0) }, "0.9.18")
            fail()
        } catch (error: SamsungInstallException) {
            assertEquals(SamsungInstallError.UNREACHABLE, error.error)
        }
    }

    private fun expectFailure(tv: FakeTv): SamsungInstallException {
        try {
            SamsungInstaller.installWithRecovery(tv, {}, InstallLog(null))
        } catch (error: SamsungInstallException) {
            return error
        }
        fail("kurulum başarısız olmalıydı")
        throw IllegalStateException()
    }

    /** #524: TV "geliştirici modu açık, Host PC IP bu telefon" diyor ama 26101 reddediliyor: TV tam yeniden başlamamış. */
    @Test
    fun refusalCauseComesFromTheTvsOwnDeveloperState() {
        fun info(mode: Boolean?, ip: String?) = SamsungTvInfo(null, null, mode, ip)
        assertEquals(SamsungRefusal.NotRestarted, info(true, "192.168.1.6").refusal("192.168.1.6"))
        assertEquals(SamsungRefusal.OtherHostIp("192.168.0.26"), info(true, "192.168.0.26").refusal("192.168.1.103"))
        assertEquals(SamsungRefusal.DeveloperModeOff, info(false, null).refusal("192.168.1.6"))
        assertEquals(SamsungRefusal.Unknown, info(true, null).refusal("192.168.1.6"))
        assertEquals(SamsungRefusal.Unknown, info(true, "192.168.1.6").refusal(null))
        assertEquals(SamsungRefusal.Unknown, info(null, null).refusal("192.168.1.6"))
        // #484: TV 192.168.1.101, telefon başka ağda (Host PC IP de telefonun o adresi): neden ağ.
        assertEquals(SamsungRefusal.DifferentNetworks("192.168.1.101", "192.168.0.26"),
            info(true, "192.168.0.26").refusal("192.168.0.26", "192.168.1.101"))
        assertEquals(SamsungRefusal.NotRestarted, info(true, "192.168.1.103").refusal("192.168.1.103", "192.168.1.101"))
        assertEquals(false, SamsungTvInfo.differentNetworks("192.168.1.101", "tv.local"))
    }

    @Test
    fun tvInfoTellsDeveloperModeAndHostIp() {
        val json = """{"device":{"developerIP":"192.168.1.20","developerMode":"1","modelName":"QE65QN90F","name":"[TV] Salon &quot;Q&quot;","OS":"Tizen"},"type":"Samsung SmartTV"}"""
        val info = SamsungTvInfo.parse(json)!!
        assertEquals("[TV] Salon \"Q\"", info.name)
        assertEquals("QE65QN90F", info.model)
        assertEquals(true, info.developerMode)
        assertEquals("192.168.1.20", info.developerIp)
        val off = SamsungTvInfo.parse("""{"device":{"developerIP":"0.0.0.0","developerMode":"0","name":"TV"}}""")!!
        assertEquals(false, off.developerMode)
        assertNull(off.developerIp)
        assertNull(SamsungTvInfo.parse("<html>"))
        assertNull(SamsungTvInfo.parse("""{"device":{"name":"TV"}}""")!!.developerMode)
    }
}
