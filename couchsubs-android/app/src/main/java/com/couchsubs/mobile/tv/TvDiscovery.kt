// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.URL

enum class TvBrand { LG, SAMSUNG, ANDROID_TV }

data class FoundTv(val name: String, val host: String, val brand: TvBrand)

/**
 * Ev ağındaki TV'leri SSDP ile bulur (Windows: LgDiscovery / SamsungTv, aynı arama hedefleri). Telefon TV'yi denetlemez:
 * CouchSubs TV uygulaması açılınca ağı tarar ve telefondaki altyazı sunucusunu kendisi bulur (`/hello`). Bu liste
 * kullanıcıya hangi TV'nin görüldüğünü gösterir; Android TV'ler DIAL üzerinden görünür.
 */
object TvDiscovery {
    private val targets = mapOf(
        "urn:lge-com:service:webos-second-screen:1" to TvBrand.LG,
        "urn:samsung.com:device:RemoteControlReceiver:1" to TvBrand.SAMSUNG,
        "urn:dial-multiscreen-org:service:dial:1" to TvBrand.ANDROID_TV,
    )

    /** SSDP yanıtından (adres, marka); hedeflerden biri değilse null. */
    fun parse(response: String): Pair<String, TvBrand>? {
        var location: String? = null
        var brand: TvBrand? = null
        for (line in response.split("\r\n")) {
            val colon = line.indexOf(':')
            if (colon < 0) continue
            val name = line.substring(0, colon).trim().uppercase()
            val value = line.substring(colon + 1).trim()
            if (name == "LOCATION") location = value
            else if (name == "ST" || name == "NT") targets[value]?.let { brand = it }
        }
        val host = location?.let { runCatching { URL(it).host }.getOrNull() } ?: return null
        return brand?.let { host to it }
    }

    /** Ağda arar (bloklar, ~[timeoutMs]); aynı adreste LG/Samsung, DIAL'dan önce gelir. */
    fun search(timeoutMs: Int = 3000): List<FoundTv> {
        val found = linkedMapOf<String, Pair<TvBrand, String?>>()
        DatagramSocket().use { socket ->
            socket.soTimeout = 300
            val group = InetAddress.getByName("239.255.255.250")
            repeat(2) {
                for (target in targets.keys) {
                    val request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: $target\r\n\r\n"
                    val bytes = request.toByteArray(Charsets.US_ASCII)
                    socket.send(DatagramPacket(bytes, bytes.size, group, 1900))
                }
            }
            val deadline = System.currentTimeMillis() + timeoutMs
            val buffer = ByteArray(4096)
            while (System.currentTimeMillis() < deadline) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    socket.receive(packet)
                } catch (error: SocketTimeoutException) {
                    continue
                }
                val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
                val (host, brand) = parse(text) ?: continue
                val location = text.split("\r\n").firstOrNull { it.startsWith("LOCATION:", ignoreCase = true) }?.substringAfter(':')?.trim()
                val existing = found[host]
                if (existing == null || existing.first == TvBrand.ANDROID_TV) found[host] = brand to location
            }
        }
        return found.map { (host, value) -> FoundTv(friendlyName(value.second) ?: defaultName(value.first), host, value.first) }
    }

    private fun defaultName(brand: TvBrand) = when (brand) {
        TvBrand.LG -> "LG TV"
        TvBrand.SAMSUNG -> "Samsung TV"
        TvBrand.ANDROID_TV -> "Android TV"
    }

    /** Cihaz tanımındaki ad ("[LG] webOS TV UK7550"); okunamazsa null. */
    private fun friendlyName(location: String?): String? {
        location ?: return null
        return try {
            val connection = URL(location).openConnection() as HttpURLConnection
            connection.connectTimeout = 1500
            connection.readTimeout = 1500
            val xml = connection.inputStream.use { String(it.readBytes(), Charsets.UTF_8) }
            connection.disconnect()
            xml.substringAfter("<friendlyName>", "").substringBefore("</friendlyName>").takeIf { it.isNotBlank() }
        } catch (error: Exception) {
            null
        }
    }
}
