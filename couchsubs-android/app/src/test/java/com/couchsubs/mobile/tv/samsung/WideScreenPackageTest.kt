// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.samsung

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * 21:9 / 32:9 Samsung monitörde paket geniş uygulama yüzeyiyle kurulur (#886); TV'lerde değişmez. Windows'taki
 * WideScreenPackageTests ve iPhone'daki WideScreenPackageTests ile aynı vakalar.
 */
class WideScreenPackageTest {
    private fun repoFile(path: String): String = listOf("../../$path", "../$path", path)
        .map(::File).first { it.exists() }.readText()

    private fun wgt(config: String, page: String): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, text) in listOf("config.xml" to config, "index.html" to page, "app.js" to "x")) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray())
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun read(wgt: ByteArray, name: String) =
        WgtSigner.readEntries(wgt).first { it.name == name }.data.toString(Charsets.UTF_8)

    @Test
    fun yalnizUltraGenisMonitordeUygulanir() {
        assertTrue(WideScreenPackage.applies("LS49CG954SUXEN", null))
        assertTrue(WideScreenPackage.applies("LS34BG850SUXEN", null))
        assertTrue(WideScreenPackage.applies("LS57CG952NUXEN", null))
        assertTrue(WideScreenPackage.applies(null, "5120x1440"))
        assertTrue(WideScreenPackage.applies(null, "3440x1440"))
        assertFalse(WideScreenPackage.applies("LS32BM801UUXEN", "3840x2160"))
        assertFalse(WideScreenPackage.applies("QE75QN900A", "7680x4320"))
        assertFalse(WideScreenPackage.applies("QE55LS03B", "3840x2160"))
        assertFalse(WideScreenPackage.applies("UE60KU7000", "1920x1080"))
        assertFalse(WideScreenPackage.applies(null, null))
        assertFalse(WideScreenPackage.applies("", "garbage"))
    }

    @Test
    fun cozunurluk8001YanitindanOkunur() {
        val info = SamsungTvInfo.parse("""{"device":{"modelName":"LS49CG95","resolution":"5120x1440"}}""")
        assertEquals("LS49CG95", info?.model)
        assertEquals("5120x1440", info?.resolution)
    }

    @Test
    fun gercekPaketGenisYuzeyAyariniVeGorunumuAlir() {
        val config = repoFile("tv-tizen/config.xml")
        assertFalse(config.contains("app_ui_type/base_screen_resolution\""))
        val original = wgt(config, repoFile("tv-webos/index.html"))
        val adapted = WideScreenPackage.adapt(original)
        val adaptedConfig = read(adapted, "config.xml")
        assertTrue(adaptedConfig.contains(WideScreenPackage.METADATA))
        assertTrue(adaptedConfig.startsWith("<?xml"))
        javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(adaptedConfig.byteInputStream())
        val html = read(adapted, "index.html")
        assertTrue(html.contains("""<meta name="viewport" content="width=device-width">"""))
        assertFalse(html.contains("""content="width=1920""""))
        assertEquals("x", read(adapted, "app.js"))
        // İkinci kez: değişen bir şey yok.
        assertSame(adapted, WideScreenPackage.adapt(adapted))
    }
}
