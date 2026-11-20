// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.samsung

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** 2016 Samsung TV'lerde (Tizen 2.x) config.xml #71'de çalışan pakete döner (#621); yeni TV'lerde paket değişmez. */
class LegacyTizenPackageTest {
    /** Depodaki gerçek config.xml (testler couchsubs-android/app'te çalışır). */
    private val config: String = listOf("../../tv-tizen/config.xml", "../tv-tizen/config.xml", "tv-tizen/config.xml")
        .map(::File).first { it.exists() }.readText()

    private fun wgt(config: String): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, data) in listOf("config.xml" to config.toByteArray(), "index.html" to "<p>x</p>".toByteArray())) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(data)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun configOf(wgt: ByteArray) =
        WgtSigner.readEntries(wgt).first { it.name == "config.xml" }.data.toString(Charsets.UTF_8)

    @Test
    fun yalnizTizen2deUygulanir() {
        assertTrue(LegacyTizenPackage.applies("2.4.0"))
        assertTrue(LegacyTizenPackage.applies("2.4"))
        assertFalse(LegacyTizenPackage.applies("3.0"))
        assertFalse(LegacyTizenPackage.applies("4.0"))
        assertFalse(LegacyTizenPackage.applies("6.5"))
        assertFalse(LegacyTizenPackage.applies(""))
    }

    @Test
    fun networkPublicVeEkranAyariCikar_digerIzinlerKalir() {
        assertTrue(config.contains("privilege/network.public\""))
        assertTrue(config.contains("base_screen_resolution"))
        val adapted = configOf(LegacyTizenPackage.adapt(wgt(config)))
        val withoutComments = adapted.replace(Regex("<!--[\\s\\S]*?-->"), "")
        assertFalse(withoutComments.contains("network.public"))
        assertFalse(withoutComments.contains("<tizen:metadata"))
        for (kept in listOf("tv.window", "tv.inputdevice", "application.launch", "privilege/internet", "network.get"))
            assertTrue(kept, withoutComments.contains("http://tizen.org/privilege/$kept\""))
        assertTrue(withoutComments.contains("required_version=\"2.4\""))
        // Satır silinince boş satır kalmaz, XML hâlâ ayrışır.
        javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(adapted.byteInputStream())
    }

    @Test
    fun digerDosyalarAyniKalir() {
        val files = WgtSigner.readEntries(LegacyTizenPackage.adapt(wgt(config)))
        assertEquals(listOf("config.xml", "index.html"), files.map { it.name })
        assertArrayEquals("<p>x</p>".toByteArray(), files[1].data)
    }

    @Test
    fun cikarilacakSatirYoksaPaketDegismez() {
        val plain = wgt("<widget><tizen:privilege name=\"http://tizen.org/privilege/internet\"/></widget>")
        assertArrayEquals(plain, LegacyTizenPackage.adapt(plain))
    }
}
