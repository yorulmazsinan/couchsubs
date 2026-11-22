// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.samsung

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * 21:9 / 32:9 Samsung akıllı monitörler (Odyssey G9 49", #886) için paket, 0.9.27–0.9.54'teki gibi geniş uygulama
 * yüzeyiyle kurulur: config.xml'e `base_screen_resolution=fullscreen`, index.html'e `width=device-width` görünümü.
 * Samsung yüzeyi ancak ikisi birlikteyken ekranın tamamı yapar; platform.js geniş yüzeyi görünce HDMI görüntüsünü 16:9
 * sığdırır, Sarı ile ekranı doldurur. 0.9.55'te ayar her TV'den kaldırılmıştı (4K/8K TV'de yüzeyi panel pikselinde açıp
 * PS5 görüntüsünü sol üst köşede bırakıyordu, #799); o günden beri G9'da uygulama 16:9 kutuda, TVWindow da 3840x1080'i
 * NotSupportedError ile reddediyor. TV'lere (16:9) paket değişmeden gider. Windows'taki WideScreenPackage.cs ve
 * iPhone'daki WideScreenPackage.swift ile aynı.
 */
object WideScreenPackage {
    /** 16:9'dan (1,78) belirgin geniş (21:9 = 2,33; 32:9 = 3,56); platform.js'teki WIDE_RATIO. */
    private const val WIDE_RATIO = 1.9

    const val METADATA =
        """<tizen:metadata key="http://tizen.org/metadata/app_ui_type/base_screen_resolution" value="fullscreen"/>"""

    private val monitorModel = Regex("""^L?[SC](34|49|57)[A-Z]""", RegexOption.IGNORE_CASE)
    private val resolutionPattern = Regex("""^\s*(\d+)\s*[xX*]\s*(\d+)\s*$""")

    /**
     * TV'nin 8001 yanıtındaki model adı (`LS49…` 32:9, `LS34…` 21:9, `LS57…` 32:9 Samsung monitör) ya da çözünürlüğü
     * (`5120x1440`) ultra geniş bir ekran mı söylüyor?
     */
    fun applies(model: String?, resolution: String?): Boolean {
        if (model != null && monitorModel.containsMatchIn(model.trim())) return true
        val size = resolutionPattern.find(resolution ?: "") ?: return false
        val width = size.groupValues[1].toDouble()
        val height = size.groupValues[2].toDouble()
        return height > 0 && width / height >= WIDE_RATIO
    }

    fun adaptConfig(config: String): String {
        if (config.contains("app_ui_type/base_screen_resolution\"")) return config
        val end = config.lastIndexOf("</widget>")
        return if (end < 0) config else config.substring(0, end) + "    " + METADATA + "\n" + config.substring(end)
    }

    fun adaptPage(html: String): String =
        html.replace("""<meta name="viewport" content="width=1920">""", """<meta name="viewport" content="width=device-width">""")

    /** config.xml ve index.html geniş yüzeye göre yazılır; değişen bir şey yoksa paket olduğu gibi döner. */
    fun adapt(wgt: ByteArray): ByteArray {
        var changed = false
        val adapted = WgtSigner.readEntries(wgt).map { entry ->
            val adapt: ((String) -> String)? = when (entry.name) {
                "config.xml" -> ::adaptConfig
                "index.html" -> ::adaptPage
                else -> null
            }
            if (adapt == null) return@map entry
            val original = entry.data.toString(Charsets.UTF_8)
            val text = adapt(original)
            if (text == original) entry else {
                changed = true
                WgtSigner.Entry(entry.name, text.toByteArray(Charsets.UTF_8))
            }
        }
        if (!changed) return wgt
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for (entry in adapted) {
                zip.putNextEntry(ZipEntry(entry.name))
                zip.write(entry.data)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
