// SPDX-License-Identifier: AGPL-3.0-only
// Mac/iPhone'daki LgHdPackage.swift (core) ve Windows'taki LgHdPackage.cs ile aynı.
package com.couchsubs.mobile.tv.lg

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/**
 * LG Full HD webOS 3.x TV'lere (2016-2017; 43LH590V, #1098) 1280x720 paket.
 *
 * LG: Full HD modellerin grafik çözünürlüğü en çok 1280x720; uygulamanın çözünürlüğü appinfo.json'daki `resolution` ile
 * belirlenir (varsayılan 1920x1080) ve LG, Full HD modeller için ayrı bir 1280x720 paket önerir
 * (webostv.developer.lge.com, "Supported App Resolution"). 43LH590V'de 1920x1080 paket sayfayı 1920x1080 CSS pikselinde
 * düzenliyor ama yalnız sol üst 1280x720'sini çiziyordu; görünüm etiketi (0.9.113) de sayfa açılırken alınan görünüm
 * (0.9.117) de bunu değiştirmedi. Kurulumdan önce TV'nin modeli, UHD olup olmadığı ve webOS sürümü sorulur; Full HD
 * webOS 3.x TV'de paketteki appinfo.json'un `resolution` değeri 1280x720 yapılır. Sayfa 1280x720 görünümde açılır,
 * tv-webos/platform.js onu CSS zoom ile 1920x1080 uzayına sığdırır. Diğer bütün LG'lere paket değişmeden gider.
 */
object LgHdPackage {
    const val RESOLUTION = "1280x720"

    /** TV'nin modeli, UHD olup olmadığı ve SDK (webOS) sürümü. */
    const val SYSTEM_INFO_COMMAND =
        "/usr/bin/luna-send-pub -n 1 'luna://com.webos.service.tv.systemproperty/getSystemInfo' " +
            "'{\"keys\":[\"modelName\",\"UHD\",\"sdkVersion\"]}'"

    data class Screen(val model: String?, val uhd: Boolean?, val sdkVersion: String?, val hd: Boolean) {
        /** Günlük satırı: "43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720". */
        val summary: String
            get() = "${model ?: "?"}, UHD ${uhd?.toString() ?: "?"}, sdk ${sdkVersion ?: "?"} → ${if (hd) RESOLUTION else "1920x1080"}"
    }

    private val FHD_LINE = Regex("""^\d{2,3}L[HJ]\d""", RegexOption.IGNORE_CASE)

    /**
     * getSystemInfo yanıtı → karar. 2016 (LH) ve 2017 (LJ) Full HD serisi ya da UHD olmayan webOS 3.x TV 1280x720 alır;
     * TV UHD diyorsa ya da yanıt okunamazsa paket değişmez.
     */
    fun screen(reply: String): Screen {
        val model = field(reply, "modelName")?.takeIf { it.isNotEmpty() }
        val uhd = when (field(reply, "UHD")?.lowercase()) {
            "true" -> true
            "false" -> false
            else -> null
        }
        val sdk = field(reply, "sdkVersion")?.takeIf { it.isNotEmpty() }
        val major = sdk?.takeWhile { it in '0'..'9' }?.toIntOrNull()
        val fhdLine = model != null && FHD_LINE.containsMatchIn(model)
        val hd = uhd != true && (fhdLine || (uhd == false && major == 3))
        return Screen(model, uhd, sdk, hd)
    }

    internal fun field(text: String, key: String): String? {
        val match = Regex(""""${Regex.escape(key)}"\s*:\s*(?:"([^"]*)"|([A-Za-z0-9.]+))""").find(text) ?: return null
        return (match.groups[1]?.value ?: match.groups[2]?.value)?.trim()
    }

    // --- Paket ---

    /**
     * Paketteki appinfo.json'un `"resolution": "1920x1080"` değeri `"1280x720" ` olur (aynı uzunlukta; tar başlığı ve
     * sağlaması değişmez). data.tar.gz yeniden sıkıştırılır, ar başlığındaki boyut yazılır; başka hiçbir bayt değişmez.
     * Paket beklenen biçimde değilse ya da değer zaten değiştiyse null.
     */
    fun adapt(ipk: ByteArray): ByteArray? {
        val members = readAr(ipk) ?: return null
        val index = members.indexOfFirst { it.name == "data.tar.gz" }
        if (index < 0) return null
        val tar = try {
            GZIPInputStream(ByteArrayInputStream(members[index].body)).use { it.readBytes() }
        } catch (error: IOException) {
            return null
        }
        if (!adaptTar(tar)) return null
        val compressed = ByteArrayOutputStream()
        GZIPOutputStream(compressed).use { it.write(tar) }
        members[index] = members[index].copy(body = compressed.toByteArray())
        return writeAr(members)
    }

    internal class ArMember(val header: ByteArray, val body: ByteArray) {
        val name: String get() = String(header, 0, 16, Charsets.US_ASCII).trim().trim('/')
        fun copy(body: ByteArray) = ArMember(header, body)
    }

    private val AR_MAGIC = "!<arch>\n".toByteArray(Charsets.US_ASCII)

    internal fun readAr(data: ByteArray): MutableList<ArMember>? {
        if (data.size < AR_MAGIC.size || !data.copyOfRange(0, AR_MAGIC.size).contentEquals(AR_MAGIC)) return null
        val members = mutableListOf<ArMember>()
        var offset = AR_MAGIC.size
        while (offset < data.size) {
            if (offset + 60 > data.size || data[offset + 58] != 0x60.toByte() || data[offset + 59] != 0x0A.toByte()) return null
            val header = data.copyOfRange(offset, offset + 60)
            val size = String(header, 48, 10, Charsets.US_ASCII).trim().toIntOrNull() ?: return null
            if (size < 0 || offset + 60 + size > data.size) return null
            members += ArMember(header, data.copyOfRange(offset + 60, offset + 60 + size))
            offset += 60 + size + (size and 1)
        }
        return members
    }

    internal fun writeAr(members: List<ArMember>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(AR_MAGIC)
        for (member in members) {
            val header = member.header.copyOf()
            val size = member.body.size.toString().toByteArray(Charsets.US_ASCII)
            for (i in 0 until 10) header[48 + i] = if (i < size.size) size[i] else ' '.code.toByte()
            out.write(header)
            out.write(member.body)
            if (member.body.size and 1 == 1) out.write(0x0A)
        }
        return out.toByteArray()
    }

    /** tar'daki uygulama appinfo.json'unu bulur ve çözünürlüğü yazar. Değiştiyse true. */
    internal fun adaptTar(tar: ByteArray): Boolean {
        var offset = 0
        while (offset + 512 <= tar.size) {
            if ((offset until offset + 512).all { tar[it] == 0.toByte() }) return false
            fun text(from: Int, count: Int): String {
                var end = offset + from
                while (end < offset + from + count && tar[end] != 0.toByte()) end++
                return String(tar, offset + from, end - offset - from, Charsets.UTF_8)
            }
            val prefix = text(345, 155)
            val name = (if (prefix.isEmpty()) "" else "$prefix/") + text(0, 100)
            val octal = text(124, 12).trim()
            val size = (if (octal.isEmpty()) 0 else octal.toIntOrNull(8)) ?: return false
            val start = offset + 512
            if (size < 0 || start + size > tar.size) return false
            if (isAppInfo(name)) {
                val adapted = adaptAppInfo(String(tar, start, size, Charsets.UTF_8)) ?: return false
                val bytes = adapted.toByteArray(Charsets.UTF_8)
                if (bytes.size != size) return false
                bytes.copyInto(tar, start)
                return true
            }
            offset = start + (size + 511) / 512 * 512
        }
        return false
    }

    internal fun isAppInfo(name: String) = name.endsWith("/appinfo.json") && name.contains("palm/applications/")

    /** `"resolution": "1920x1080"` → `"resolution": "1280x720" ` (uzunluk aynı); değer yoksa null. */
    fun adaptAppInfo(text: String): String? {
        val match = Regex(""""resolution"\s*:\s*"1920x1080"""").find(text) ?: return null
        return text.replaceRange(match.range, match.value.replace("\"1920x1080\"", "\"$RESOLUTION\" "))
    }
}
