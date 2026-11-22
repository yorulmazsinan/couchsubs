// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.samsung

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Samsung TV'nin `http://TV:8001/api/v2/` yanıtı: adı, modeli ve geliştirici modu (açık mı, Host PC IP'si ne). Kurulum
 * ekranı buna bakarak TV'de neyin eksik olduğunu söyler; yanıt yoksa yine kurulum denenebilir.
 */
data class SamsungTvInfo(
    val name: String?,
    val model: String?,
    val developerMode: Boolean?,
    val developerIp: String?,
    /** Ekran çözünürlüğü ("3840x2160"; ultra geniş monitörde geniş yüzey için, #886). */
    val resolution: String? = null,
) {
    /**
     * sdb (26101) bağlantısı reddedilince TV'nin kendi söylediğine göre neden (Mac/iPhone'daki SamsungDeveloperInfo.refusal):
     * geliştirici modu kapalı, Host PC IP başka cihazın ya da ayar doğru ama TV o zamandan beri tam yeniden başlamamış.
     * sdb sunucusu yalnız açılışta başlar; TV kapanınca güç tuşunu bırakmak yalnız bekleme moduna geçirir (#524, #484).
     */
    fun refusal(phoneIp: String?, tvIp: String? = null): SamsungRefusal {
        val ip = developerIp?.trim()?.takeIf { it.isNotEmpty() }
        val phone = phoneIp?.trim()?.takeIf { it.isNotEmpty() }
        // #484: TV ile telefon farklı /24 ağında (ikinci modem, mesh, misafir ağı): Host PC IP doğru olsa da TV reddeder.
        if (tvIp != null && phone != null && differentNetworks(tvIp, phone)) return SamsungRefusal.DifferentNetworks(tvIp.trim(), phone)
        return when (developerMode) {
            false -> SamsungRefusal.DeveloperModeOff
            true -> when {
                ip != null && phone != null && ip != phone -> SamsungRefusal.OtherHostIp(ip)
                ip != null && ip == phone -> SamsungRefusal.NotRestarted
                else -> SamsungRefusal.Unknown
            }
            null -> SamsungRefusal.Unknown
        }
    }

    companion object {
        /** İki IPv4 adresi farklı /24 ağında mı? Biri IPv4 değilse farklı sayılmaz. */
        fun differentNetworks(a: String, b: String): Boolean {
            fun prefix(text: String): List<Int>? {
                val parts = text.trim().split(".").map { it.toIntOrNull() }
                if (parts.size != 4 || parts.any { it == null || it !in 0..255 }) return null
                return parts.take(3).filterNotNull()
            }
            val left = prefix(a) ?: return false
            val right = prefix(b) ?: return false
            return left != right
        }

        fun parse(json: String): SamsungTvInfo? = try {
            val device = JSONObject(json).optJSONObject("device") ?: throw IllegalArgumentException()
            fun text(name: String) = device.optString(name, "").replace("&quot;", "\"").trim().takeIf { it.isNotEmpty() }
            SamsungTvInfo(
                name = text("name"),
                model = text("modelName"),
                developerMode = text("developerMode")?.let { it == "1" || it.equals("true", ignoreCase = true) },
                developerIp = text("developerIP")?.takeIf { it != "0.0.0.0" },
                resolution = text("resolution"),
            )
        } catch (error: Exception) {
            null
        }

        /** TV'ye sorar (bloklar, en çok iki kez [timeoutMs]); yanıt yoksa null. */
        fun fetch(host: String, timeoutMs: Int = 1500): SamsungTvInfo? = try {
            val connection = URL("http://$host:8001/api/v2/").openConnection() as HttpURLConnection
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            try {
                parse(connection.inputStream.use { String(it.readBytes(), Charsets.UTF_8) })
            } finally {
                connection.disconnect()
            }
        } catch (error: Exception) {
            null
        }
    }
}

/** Samsung TV'nin sdb bağlantısını neden reddettiği (8001'deki geliştirici modu bilgisine göre). */
sealed interface SamsungRefusal {
    /** TV ile bu telefon farklı ağlarda (adresleri farklı /24'te). */
    data class DifferentNetworks(val tv: String, val phone: String) : SamsungRefusal
    data object DeveloperModeOff : SamsungRefusal
    data class OtherHostIp(val ip: String) : SamsungRefusal
    /** Geliştirici modu açık ve Host PC IP bu telefon; TV ayardan sonra tam yeniden başlamamış. */
    data object NotRestarted : SamsungRefusal
    data object Unknown : SamsungRefusal
}
