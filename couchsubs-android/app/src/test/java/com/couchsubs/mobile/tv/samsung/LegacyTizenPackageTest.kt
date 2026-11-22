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
        val adapted = configOf(LegacyTizenPackage.adapt(wgt(config)))
        val withoutComments = adapted.replace(Regex("<!--[\\s\\S]*?-->"), "")
        assertFalse(withoutComments.contains("network.public"))
        assertFalse(withoutComments.contains("<tizen:metadata"))
        for (kept in listOf("tv.window", "tv.inputdevice", "application.launch", "internet", "network.get"))
            assertTrue(kept, withoutComments.contains("http://tizen.org/privilege/$kept\""))
        assertTrue(withoutComments.contains("required_version=\"2.4\""))
        // Satır silinince boş satır kalmaz, XML hâlâ ayrışır.
        javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(adapted.byteInputStream())
    }

    /**
     * Tizen 2.x'e giden config.xml, #71'de 40KU7000'de çalışan paketinkiyle (testdata/tizen/config-71.xml) öğe öğe ve
     * öznitelik öznitelik aynıdır; yalnız widget sürümü farklıdır. Windows'taki LegacyTizenPackageTests ile aynı vaka.
     */
    @Test
    fun tizen2ConfigIssue71dekiyleAyni() {
        val working = listOf("../../testdata/tizen/config-71.xml", "../testdata/tizen/config-71.xml", "testdata/tizen/config-71.xml")
            .map(::File).first { it.exists() }.readText()
        assertEquals(shape(working), shape(configOf(LegacyTizenPackage.adapt(wgt(config)))))
    }

    /** config.xml'in öğeleri sırasıyla: ad, öznitelikler (widget sürümü hariç) ve metin; açıklamalar yok. */
    private fun shape(config: String): List<String> {
        val factory = javax.xml.parsers.DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val root = factory.newDocumentBuilder().parse(config.byteInputStream()).documentElement
        val out = mutableListOf<String>()
        fun walk(element: org.w3c.dom.Element) {
            val attributes = (0 until element.attributes.length).map { element.attributes.item(it) }
                .filter { !(element === root && it.nodeName == "version") && !it.nodeName.startsWith("xmlns") }
                .map { "${it.nodeName}=${it.nodeValue}" }.sorted()
            val children = (0 until element.childNodes.length).map { element.childNodes.item(it) }.filterIsInstance<org.w3c.dom.Element>()
            out += "${element.nodeName} ${attributes.joinToString(" ")}" + if (children.isEmpty()) " :" + element.textContent.trim() else ""
            children.forEach(::walk)
        }
        walk(root)
        return out
    }

    /** Yalın paket (#638): SHA-512 imzalı tam paket yalın [118] alırsa denenir. */
    @Test
    fun yalinPakettenProfilVeIkiIzinDeCikar() {
        val adapted = configOf(LegacyTizenPackage.adapt(wgt(config), lean = true))
        val withoutComments = adapted.replace(Regex("<!--[\\s\\S]*?-->"), "")
        for (removed in listOf("network.public", "<tizen:metadata", "<tizen:profile", "application.launch", "network.get"))
            assertFalse(removed, withoutComments.contains(removed))
        for (kept in listOf("tv.window", "tv.inputdevice", "internet"))
            assertTrue(kept, withoutComments.contains("http://tizen.org/privilege/$kept\""))
        assertTrue(withoutComments.contains("required_version=\"2.4\""))
        assertTrue(withoutComments.contains("<tizen:application id=\"CouchSubsT.CouchSubs\" package=\"CouchSubsT\""))
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
