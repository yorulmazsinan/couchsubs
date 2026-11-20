// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.samsung

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Samsung TV'nin `http://TV:8001/api/v2/` yanıtı: adı, modeli ve geliştirici modu (açık mı, Host PC IP'si ne). Kurulum
 * ekranı buna bakarak TV'de neyin eksik olduğunu söyler; yanıt yoksa yine kurulum denenebilir.
 */
data class SamsungTvInfo(val name: String?, val model: String?, val developerMode: Boolean?, val developerIp: String?) {
    /**
     * sdb (26101) bağlantısı reddedilince TV'nin kendi söylediğine göre neden (Mac/iPhone'daki SamsungDeveloperInfo.refusal):
     * geliştirici modu kapalı, Host PC IP başka cihazın ya da ayar doğru ama TV o zamandan beri tam yeniden başlamamış.
     * sdb sunucusu yalnız açılışta başlar; TV kapanınca güç tuşunu bırakmak yalnız bekleme moduna geçirir (#524, #484).
     */
    fun refusal(phoneIp: String?): SamsungRefusal {
        val ip = developerIp?.trim()?.takeIf { it.isNotEmpty() }
        val phone = phoneIp?.trim()?.takeIf { it.isNotEmpty() }
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
        fun parse(json: String): SamsungTvInfo? = try {
            val device = JSONObject(json).optJSONObject("device") ?: throw IllegalArgumentException()
            fun text(name: String) = device.optString(name, "").replace("&quot;", "\"").trim().takeIf { it.isNotEmpty() }
            SamsungTvInfo(
                name = text("name"),
                model = text("modelName"),
                developerMode = text("developerMode")?.let { it == "1" || it.equals("true", ignoreCase = true) },
                developerIp = text("developerIP")?.takeIf { it != "0.0.0.0" },
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
    data object DeveloperModeOff : SamsungRefusal
    data class OtherHostIp(val ip: String) : SamsungRefusal
    /** Geliştirici modu açık ve Host PC IP bu telefon; TV ayardan sonra tam yeniden başlamamış. */
    data object NotRestarted : SamsungRefusal
    data object Unknown : SamsungRefusal
}
