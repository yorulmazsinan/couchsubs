// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.lg

import com.couchsubs.mobile.core.Fixtures
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.util.Base64
import java.util.zip.GZIPInputStream

/**
 * #1098: LG 43LH590V (Full HD, webOS 3.x) sayfanın yalnız sol üst 1280x720'sini çiziyordu. Kurulumda Full HD webOS 3.x
 * TV'ye paket appinfo.json'da 1280x720 çözünürlükle gider. Ortak vakalar fixtures/lg-hd-package.json
 * (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac/iPhone LgHdPackageTests.swift, Windows LgHdPackageTests.cs aynı).
 */
class LgHdPackageTest {
    private val fixture = JSONObject(Fixtures.text("lg-hd-package.json"))
    private val ipk: ByteArray get() = Base64.getDecoder().decode(fixture.getString("package"))
    private val appInfo = "usr/palm/applications/com.couchsubs.tv/appinfo.json"

    /** tar'daki dosyalar (ad → içerik). */
    private fun files(ipk: ByteArray): Map<String, String> {
        val data = LgHdPackage.readAr(ipk)!!.single { it.name == "data.tar.gz" }
        val tar = GZIPInputStream(ByteArrayInputStream(data.body)).use { it.readBytes() }
        val out = mutableMapOf<String, String>()
        var offset = 0
        while (offset + 512 <= tar.size && (offset until offset + 512).any { tar[it] != 0.toByte() }) {
            val name = String(tar, offset, 100, Charsets.UTF_8).trimEnd('\u0000')
            val size = String(tar, offset + 124, 12, Charsets.US_ASCII).trim('\u0000', ' ').toInt(8)
            out[name] = String(tar, offset + 512, size, Charsets.UTF_8)
            offset += 512 + (size + 511) / 512 * 512
        }
        return out
    }

    @Test
    fun onlyFullHdWebOs3TvsGetThe720pPackage() {
        val cases = fixture.getJSONArray("systemInfo")
        for (i in 0 until cases.length()) {
            val item = cases.getJSONObject(i)
            val screen = LgHdPackage.screen(item.getString("reply"))
            assertEquals(item.getString("note"), item.getBoolean("hd"), screen.hd)
            assertEquals(item.getString("note"), if (item.isNull("model")) null else item.getString("model"), screen.model)
        }
        assertEquals("43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720",
            LgHdPackage.screen(cases.getJSONObject(0).getString("reply")).summary)
    }

    @Test
    fun appInfoResolutionBecomes720pAndNothingElseChanges() {
        val original = ipk
        val adapted = LgHdPackage.adapt(original)
        assertNotNull(adapted)
        val before = files(original)
        val after = files(adapted!!)
        assertEquals(fixture.getString("appInfo"), before[appInfo])
        assertEquals(fixture.getString("adaptedAppInfo"), after[appInfo])
        assertTrue(after[appInfo]!!.contains("\"resolution\": \"1280x720\" ,"))
        assertEquals("1280x720", JSONObject(after[appInfo]!!).getString("resolution"))
        assertEquals(fixture.getString("appJs"), after["usr/palm/applications/com.couchsubs.tv/app.js"])
        assertEquals(before.size, after.size)
        for ((name, text) in before) if (name != appInfo) assertEquals(name, text, after[name])
        val a = LgHdPackage.readAr(original)!!
        val b = LgHdPackage.readAr(adapted)!!
        assertEquals(listOf("debian-binary", "control.tar.gz", "data.tar.gz"), a.map { it.name })
        assertEquals(a.map { it.name }, b.map { it.name })
        assertArrayEquals(a[0].body, b[0].body)
        assertArrayEquals(a[1].body, b[1].body)
        // Zaten 1280x720 olan paket bir daha değişmez; bozuk paket değişmez.
        assertNull(LgHdPackage.adapt(adapted))
        assertNull(LgHdPackage.adapt("not an ipk".toByteArray()))
    }

    private class FakeTv(private val reply: String) : LgShell {
        val commands = mutableListOf<String>()
        var uploaded: ByteArray? = null
        private var installed = "0.9.120"
        override fun run(command: String, input: ByteArray?): CommandResult {
            commands += command
            return when {
                command == LgHdPackage.SYSTEM_INFO_COMMAND -> CommandResult(0, reply)
                command.startsWith("cat /media/developer/apps") -> CommandResult(0, """{"id":"com.couchsubs.tv","version":"$installed"}""")
                command.contains("cat > ") -> { uploaded = input; CommandResult(0, "") }
                command.startsWith("wc -c") -> CommandResult(0, "${uploaded?.size ?: 0}\n")
                command.contains("appInstallService") -> { installed = "0.9.122"; CommandResult(0, """{"returnValue":true,"details":{"state":"installed"}}""") }
                else -> CommandResult(0, "")
            }
        }
    }

    @Test
    fun fullHdWebOs3TvGetsTheAdaptedPackageUnderTheSameName() {
        val tv = FakeTv(fixture.getJSONArray("systemInfo").getJSONObject(0).getString("reply"))
        LgInstaller(tv, pollIntervalMs = 1).install(ipk, "com.couchsubs.tv_0.9.122_all.ipk", "0.9.122")
        assertEquals(LgHdPackage.SYSTEM_INFO_COMMAND, tv.commands[0])
        assertTrue(tv.commands[1].endsWith("cat > '/media/developer/temp/com.couchsubs.tv_0.9.122_all.ipk'"))
        assertEquals(fixture.getString("adaptedAppInfo"), files(tv.uploaded!!)[appInfo])
        assertFalse(tv.uploaded!!.contentEquals(ipk))
    }

    @Test
    fun otherTvsGetThePackageUnchanged() {
        val cases = fixture.getJSONArray("systemInfo")
        val oled = (0 until cases.length()).map { cases.getJSONObject(it) }
            .first { !it.isNull("model") && it.getString("model") == "OLED55C24LA" }.getString("reply")
        for (reply in listOf(oled, "")) {
            val tv = FakeTv(reply)
            LgInstaller(tv, pollIntervalMs = 1).install(ipk, "com.couchsubs.tv_0.9.122_all.ipk", "0.9.122")
            assertArrayEquals(ipk, tv.uploaded)
        }
    }
}
