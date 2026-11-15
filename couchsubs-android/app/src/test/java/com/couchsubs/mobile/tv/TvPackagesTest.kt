// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.zip.ZipFile

/** Uygulamaya gömülen TV paketleri (build.gradle tvReleasePackages, son GitHub sürümünden). */
class TvPackagesTest {
    private val directory = File(System.getProperty("couchsubs.tvPackages") ?: "build/generated/couchsubs-tv-release/tv")
    private val required = System.getProperty("couchsubs.requireTvPackages") == "true"

    @Test
    fun parsesTheIndex() {
        val index = TvPackages.parse("release=v0.1.0-beta.39\n# not\ncouchsubs-androidtv.apk = CouchSubs-androidtv.apk\n\n")
        assertEquals(mapOf("release" to "v0.1.0-beta.39", "couchsubs-androidtv.apk" to "CouchSubs-androidtv.apk"), index)
    }

    @Test
    fun embeddedAndroidTvPackageIsTheReleasedApk() {
        val index = File(directory, "tv-packages.properties")
        // Çevrimdışı yerel derlemede paket indirilemeyebilir; CI indirmeyi şart koşar.
        if (!required) assumeTrue("TV paketleri indirilmemiş", index.exists())
        val entries = TvPackages.parse(index.readText())
        assertTrue(entries["release"]!!.startsWith("v"))
        assertEquals("CouchSubs-androidtv.apk", entries[TvPackages.ANDROID_TV_APK])
        ZipFile(File(directory, TvPackages.ANDROID_TV_APK)).use { apk ->
            assertTrue(apk.getEntry("AndroidManifest.xml") != null)
            assertTrue(apk.getEntry("classes.dex") != null)
        }
        // LG: ares-package'ın ipk'sı bir ar arşividir (debian-binary, control.tar.gz, data.tar.gz).
        val ipkName = entries[TvPackages.LG_IPK]!!
        assertTrue(com.couchsubs.mobile.tv.lg.LgInstaller.versionOfPackage(ipkName) != null)
        val ipk = File(directory, TvPackages.LG_IPK).readBytes()
        assertEquals("!<arch>\n", String(ipk, 0, 8, Charsets.US_ASCII))
        assertTrue(String(ipk, Charsets.ISO_8859_1).contains("debian-binary"))
    }
}
