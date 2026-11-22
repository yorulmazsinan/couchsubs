// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.samsung

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * 2016 Samsung TV'ler (Tizen 2.x) için paketin config.xml'i, #71'de 40KU7000'de (Tizen 2.4) elle kurulup çalışan pakete
 * döndürülür. O paketten sonra eklenen iki satır çıkarılır:
 * - `network.public` izni (0.9.30): yalnız TV adresini bulmanın yedeği (webapis.network.getIp); platform.js hatayı yutar,
 *   adres bulunamazsa app.js ev ağını tarar.
 * - `base_screen_resolution` ayarı (0.9.30): yalnız 21:9 / 32:9 Samsung monitörler için (#304); 2016 TV'lerde yoktur.
 *
 * Tizen 2.4 tanımadığı satırı içeren paketi sebep yazmadan `install failed[118]` ile reddediyor; `power` izni
 * çıkarıldıktan sonra da (#497) 0.9.38 aynı hatayı verdi (#621). Yeni TV'lerde paket değişmez.
 *
 * Asıl eksik paket değil, cihaz profilinin yeriydi (#890): Tizen 2.x profili `/home/developer`'da arar (SamsungInstaller).
 * İlk deneme #71'deki gibi SHA-512 imzalıdır; TV yine yalın `install failed[118]` derse aynı kurulumda bir kez de
 * SHA-256 imzalı ([WgtSigner.Digest]) "yalın" paket denenir (#638): `tizen:profile` satırı ile `application.launch` ve
 * `network.get` izinleri de çıkar (uygulama bunlarsız da açılır; TV adresi ağ taramasıyla bulunur). Hangisinin tuttuğu
 * günlükten görülür.
 */
object LegacyTizenPackage {
    /** Bu sürümden eski TV'lerde (Tizen 2.x) paket sadeleştirilir. */
    private const val FIRST_MODERN = "3.0"

    fun applies(platform: String) = platform.isNotEmpty() && SamsungDiagnostics.isNewer(FIRST_MODERN, platform)

    private val removed = listOf(
        Regex("""[ \t]*<tizen:privilege name="http://developer\.samsung\.com/privilege/network\.public"\s*/>[ \t]*\r?\n?"""),
        Regex("""[ \t]*<tizen:metadata key="http://tizen\.org/metadata/app_ui_type/base_screen_resolution"[^>]*/>[ \t]*\r?\n?"""),
    )

    /** Yalın pakette ayrıca çıkarılanlar (günlük için). */
    const val LEAN_REMOVED = "tizen:profile, application.launch, network.get"

    private val leanRemoved = listOf(
        Regex("""[ \t]*<tizen:profile\s[^>]*/>[ \t]*\r?\n?"""),
        Regex("""[ \t]*<tizen:privilege name="http://tizen\.org/privilege/(application\.launch|network\.get)"\s*/>[ \t]*\r?\n?"""),
    )

    /** config.xml'den yukarıdaki satırlar ([lean] ise yalın paketinkiler de) çıkarılır; değişen bir şey yoksa paket olduğu gibi döner. */
    fun adapt(wgt: ByteArray, lean: Boolean = false): ByteArray {
        val files = WgtSigner.readEntries(wgt)
        var changed = false
        val adapted = files.map { entry ->
            if (entry.name != "config.xml") return@map entry
            val original = entry.data.toString(Charsets.UTF_8)
            val config = (if (lean) removed + leanRemoved else removed).fold(original) { text, pattern -> pattern.replace(text, "") }
            if (config == original) entry else {
                changed = true
                WgtSigner.Entry(entry.name, config.toByteArray(Charsets.UTF_8))
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
