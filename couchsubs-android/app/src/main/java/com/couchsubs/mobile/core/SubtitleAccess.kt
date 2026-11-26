// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.net.InetAddress
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** Windows ve Swift ile aynı TV/OBS erişim politikası. Anahtarlar günlüklenmez. */
object SubtitleAccess {
    // Yalnız geçiş sürümü: sonraki sürümde false yapılmalı.
    const val ALLOW_LEGACY_CLIENTS = true
    fun createKey(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(16).also { SecureRandom().nextBytes(it) })
    fun isLocalPeer(address: InetAddress): Boolean {
        val b = address.address.map { it.toInt() and 255 }
        if (address.isLoopbackAddress) return true
        if (b.size == 16) {
            if (b.take(10).all { it == 0 } && b[10] == 255 && b[11] == 255) return localIPv4(b.takeLast(4))
            return (b[0] and 254) == 252 || b[0] == 254 && (b[1] and 192) == 128
        }
        return localIPv4(b)
    }
    /**
     * Eşleştirme isteği gönderen TV'nin geri bağlanılacak adresi: IPv4'e eşlenmiş IPv6 düz IPv4 olur, bağlantı arayüzü
     * atılır. Bu cihazın kendisi (loopback; ikinci ekran sayfası) ve yerel olmayan adres TV sayılmaz: boş döner
     * (Mac/iPhone `SubtitleAccess.tvHost`, Windows `SubtitleAccess.TvHost` ile aynı kural).
     */
    fun tvHost(address: InetAddress?): String {
        address ?: return ""
        if (address.isLoopbackAddress || !isLocalPeer(address)) return ""
        val b = address.address
        if (b.size == 16 && b.take(10).all { it.toInt() == 0 } && b[10].toInt() and 255 == 255 && b[11].toInt() and 255 == 255)
            return InetAddress.getByAddress(b.copyOfRange(12, 16)).hostAddress ?: ""
        if (b.size == 16) return InetAddress.getByAddress(b).hostAddress?.substringBefore('%') ?: ""
        return address.hostAddress ?: ""
    }
    private fun localIPv4(b: List<Int>): Boolean = b[0] == 127 || b[0] == 10 || b[0] == 172 && b[1] in 16..31 ||
        b[0] == 192 && b[1] == 168 || b[0] == 169 && b[1] == 254 || b[0] == 100 && b[1] in 64..127

    data class Request(val method: String, val target: String, val origin: String?, val host: String) {
        val path get() = target.substringBefore('?')
        fun parameter(name: String): String? {
            if (!target.contains('?')) return null
            var result: String? = null
            for (pair in target.substringAfter('?').split('&')) {
                val parts = pair.split('=', limit = 2)
                if (decode(parts[0]) != name) continue
                if (result != null) return ""
                result = if (parts.size == 2) decode(parts[1]) else ""
            }
            return result
        }
        private fun decode(value: String): String = try { URLDecoder.decode(value.replace("+", "%2B"), "UTF-8") } catch (_: IllegalArgumentException) { "" }
    }
    fun parse(head: String): Request? {
        val lines = head.split("\r\n")
        val first = lines[0].split(' ')
        if (first.size != 3 || !first[1].startsWith('/')) return null
        var origin: String? = null
        var host: String? = null
        for (line in lines.drop(1)) {
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon <= 0 || line[0].isWhitespace()) return null
            val name = line.substring(0, colon)
            val value = line.substring(colon + 1).trim()
            if (value.any { it.code !in 32..126 }) return null
            if (name.equals("Origin", ignoreCase = true)) { if (origin != null) return null; origin = value }
            if (name.equals("Host", ignoreCase = true)) { if (host != null) return null; host = value }
        }
        return Request(first[0], first[1], origin, host ?: "")
    }
    private fun uri(value: String): URI? = try { URI(value) } catch (_: Exception) { null }
    private fun packagedOrigin(origin: String): Boolean {
        // Paketli TV uygulamaları: webOS/Android TV "null", Samsung Tizen ise (en az 5.0'da, POST isteklerinde) "file://" gönderir.
        // Eski webOS (4.x) "file:///" ya da yol ekli "file:///..." gönderebilir (GitHub #1132): ana makinesi boş, sorgu/parça/kullanıcı
        // içermeyen her file: değeri kabul edilir. Web sayfaları file: Origin'i üretemez; "file://evil.example" gibi ana makineli değerler reddedilir.
        if (origin == "null" || isFileOrigin(origin)) return true
        val url = uri(origin) ?: return false
        return url.scheme == "app" && !url.host.isNullOrEmpty() && url.rawUserInfo == null && url.rawPath in listOf("", "/") && url.rawQuery == null && url.rawFragment == null
    }
    /** Ana makinesiz file: Origin'i: "file://", "file:///" ya da "file:///yol". Sorgu, parça, kullanıcı ve ters bölü yok. */
    fun isFileOrigin(origin: String): Boolean {
        if (!origin.startsWith("file://")) return false
        val rest = origin.substring(7)
        return rest.isEmpty() || rest.startsWith("/") && rest.none { it in "?#@\\" }
    }
    /** 403 alan isteğin günlük satırı (GitHub #1132): reddedilen Origin değeri olduğu gibi (en çok 120 karakter) yazılır. */
    fun rejectedOriginLine(request: Request): String =
        "altyazı sunucusu isteği reddetti (403): Origin \"${(request.origin ?: "").take(120)}\" kabul edilmedi (yol ${request.path}, Host ${request.host.take(80)})"
    /** Reddedilen Origin değerlerini günlüğe bir kez yazdırır: aynı değer tekrar yazılmaz, en çok 16 farklı değer. */
    class RejectedOrigins {
        private val seen = HashSet<String>()
        /** Yazılacak satır; bu Origin daha önce yazıldıysa ya da sınır dolduysa null. */
        fun line(request: Request): String? {
            val fresh = synchronized(seen) { seen.size < 16 && seen.add(request.origin ?: "") }
            return if (fresh) rejectedOriginLine(request) else null
        }
    }
    fun originAllowed(request: Request): Boolean {
        val value = request.origin ?: return true
        if (packagedOrigin(value)) return true
        val origin = uri(value) ?: return false
        val local = uri("http://" + request.host) ?: return false
        fun clean(url: URI) = url.scheme == "http" && url.host != null && url.rawUserInfo == null && url.rawPath in listOf("", "/") && url.rawQuery == null && url.rawFragment == null
        return clean(origin) && clean(local) && origin.host.equals(local.host, ignoreCase = true) &&
            (if (origin.port == -1) 80 else origin.port) == (if (local.port == -1) 80 else local.port)
    }
    fun cors(request: Request): String = request.origin?.takeIf { packagedOrigin(it) }?.let { "Access-Control-Allow-Origin: $it\r\nVary: Origin\r\n" } ?: ""
    data class Decision(val status: Int, val legacy: Boolean = false)
    fun authorize(request: Request, key: String, allowLegacy: Boolean): Decision {
        if (!originAllowed(request)) return Decision(403)
        if (request.path == "/hello" || request.path == "/obs" || request.path == "/pair") return Decision(200)
        val supplied = request.parameter("k")
        // İkinci ekran (sayfası ve akışı) eski TV'lere tanınan anahtarsız geçişten yararlanmaz: aynı ağdaki herkes açamaz.
        if (supplied == null && allowLegacy && !isSecondScreen(request) && (request.origin == null || packagedOrigin(request.origin))) return Decision(200, true)
        return Decision(if (supplied != null && MessageDigest.isEqual(key.toByteArray(Charsets.UTF_8), supplied.toByteArray(Charsets.UTF_8))) 200 else 401)
    }

    /** Başka bir cihazın tarayıcısında açılan altyazı sayfası (`/view`) ya da onun akışı (`/events?viewer=second`). */
    fun isSecondScreen(request: Request): Boolean =
        request.path == SecondScreen.PATH || request.path == "/events" && request.parameter("viewer") == SecondScreen.VIEWER
}
