// SPDX-License-Identifier: AGPL-3.0-only
// PSN girişiyle Remote Play kaydı için gereken hesap kimliğini alır. Akış ve istemci bilgileri chiaki-ng'den
// (gui/src/psnaccountid.cpp); Windows'taki PsnAccount.cs ve Mac'teki PSNAccount ile aynı.
package com.couchsubs.mobile.remoteplay

import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder

/** PSN girişinin nerede ve neden bittiği; kullanıcıya ayrı ayrı anlatılır. */
enum class PsnLoginFailure { NO_CODE, REFUSED, RATE_LIMITED, HTTP, NETWORK, BAD_RESPONSE }

class PsnAccountException(val failure: PsnLoginFailure, val status: Int? = null, val detail: String? = null) :
    IOException("PSN sign-in failed: $failure${status?.let { " (HTTP $it)" } ?: ""}${detail?.let { " $it" } ?: ""}")

object PsnAccount {
    private const val CLIENT_ID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private const val CLIENT_SECRET = "mvaiZkRsAsI1IBkY"
    private const val TOKEN_URL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
    private const val SCOPE =
        "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

    const val REDIRECT_PREFIX = "https://remoteplay.dl.playstation.net/remoteplay/redirect"

    /** Uygulama içi tarayıcıda (WebView) açılacak Sony giriş sayfası. */
    val authorizeUrl: String = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?" + query(
        listOf(
            "service_entity" to "urn:service-entity:psn",
            "response_type" to "code",
            "client_id" to CLIENT_ID,
            "redirect_uri" to REDIRECT_PREFIX,
            "scope" to SCOPE,
            "request_locale" to "en_US",
            "ui" to "pr",
            "service_logo" to "ps",
            "layout_type" to "popup",
            "smcid" to "remoteplay",
            "prompt" to "always",
            "PlatformPrivacyWs1" to "minimal",
        )
    )

    fun isRedirect(url: String) = url.startsWith(REDIRECT_PREFIX)

    /** Giriş bitince tarayıcının gittiği yönlendirme adresinden tek kullanımlık kod. */
    fun codeFromRedirect(url: String): String? = if (isRedirect(url)) queryValue(url, "code") else null

    /** Sony girişi tamamlamadıysa yönlendirmedeki hata (ör. "access_denied: ..."); yoksa null. */
    fun errorFromRedirect(url: String): String? {
        if (!isRedirect(url)) return null
        val error = queryValue(url, "error")?.takeIf { it.isNotEmpty() } ?: return null
        val description = queryValue(url, "error_description")?.replace('+', ' ')
        val code = queryValue(url, "error_code")
        return error + (if (description.isNullOrEmpty()) "" else ": $description") + (if (code.isNullOrEmpty()) "" else " ($code)")
    }

    private fun looksRateLimited(text: String?) = text != null &&
        listOf("too many", "too_many", "rate limit").any { text.contains(it, ignoreCase = true) }

    /** Yönlendirmeden hesap kimliği (8 bayt). Bloklar; arka planda çağrılır. Token saklanmaz. */
    fun accountIdFromRedirect(redirect: String): ByteArray {
        codeFromRedirect(redirect)?.takeIf { it.isNotEmpty() }?.let { return accountId(it) }
        val error = errorFromRedirect(redirect) ?: throw PsnAccountException(PsnLoginFailure.NO_CODE)
        throw PsnAccountException(if (looksRateLimited(error)) PsnLoginFailure.RATE_LIMITED else PsnLoginFailure.REFUSED, detail = error)
    }

    fun accountId(code: String): ByteArray {
        try {
            val token = json(
                "POST", TOKEN_URL,
                query(listOf("grant_type" to "authorization_code", "code" to code, "scope" to SCOPE, "redirect_uri" to REDIRECT_PREFIX)),
            )
            val accessToken = token.opt("access_token") as? String ?: run {
                val error = sonyError(token)
                throw if (error == null) PsnAccountException(PsnLoginFailure.BAD_RESPONSE)
                else PsnAccountException(if (looksRateLimited(error)) PsnLoginFailure.RATE_LIMITED else PsnLoginFailure.REFUSED, detail = error)
            }
            val info = json("GET", "$TOKEN_URL/${encode(accessToken)}", null)
            val text = when (val userId = info.opt("user_id")) {
                is String -> userId
                is Number -> userId.toString()
                else -> null
            }
            return text?.let(::accountIdBytes) ?: throw PsnAccountException(PsnLoginFailure.BAD_RESPONSE)
        } catch (error: PsnAccountException) {
            throw error
        } catch (error: IOException) {
            throw PsnAccountException(PsnLoginFailure.NETWORK, detail = error.message)
        }
    }

    /** Ondalık user_id'yi 8 baytlık little-endian dizisine çevirir. */
    fun accountIdBytes(userId: String): ByteArray? {
        if (userId.isEmpty() || !userId.all { it in '0'..'9' }) return null
        val value = try {
            java.lang.Long.parseUnsignedLong(userId)
        } catch (error: NumberFormatException) {
            return null
        }
        return ByteArray(8) { index -> (value ushr (8 * index)).toByte() }
    }

    /** Kayıtta ve günlükte görünen biçim (masaüstüyle aynı): base64. */
    fun accountIdText(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)

    private val basicAuth: String
        get() = "Basic " + java.util.Base64.getEncoder().encodeToString("$CLIENT_ID:$CLIENT_SECRET".toByteArray(Charsets.UTF_8))

    private fun json(method: String, url: String, form: String?): JSONObject {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 30_000
            connection.readTimeout = 30_000
            // Çerezsiz: eski oturumun çerezleri gönderilmesin.
            connection.useCaches = false
            connection.setRequestProperty("Authorization", basicAuth)
            if (form != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                connection.outputStream.use { it.write(form.toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val body = (if (status >= 400) connection.errorStream else connection.inputStream)?.use { String(it.readBytes(), Charsets.UTF_8) } ?: ""
            if (status !in 200..299) {
                val error = errorBody(body)
                val failure = when {
                    status == 429 || looksRateLimited(error) -> PsnLoginFailure.RATE_LIMITED
                    status == 400 || status == 401 || status == 403 -> PsnLoginFailure.REFUSED
                    else -> PsnLoginFailure.HTTP
                }
                throw PsnAccountException(failure, status, error)
            }
            return try {
                JSONObject(body)
            } catch (error: JSONException) {
                throw PsnAccountException(PsnLoginFailure.BAD_RESPONSE)
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun errorBody(text: String): String? {
        if (text.isBlank()) return null
        try {
            sonyError(JSONObject(text))?.let { return it }
        } catch (error: JSONException) {
        }
        val trimmed = text.trim()
        return if (trimmed.length > 200) trimmed.substring(0, 200) else trimmed
    }

    fun sonyError(root: JSONObject): String? {
        fun text(name: String): String? = when (val value = root.opt(name)) {
            is String -> value
            is Number -> value.toString()
            else -> null
        }
        val error = text("error")?.takeIf { it.isNotEmpty() } ?: return null
        val description = text("error_description")
        val code = text("error_code")
        return error + (if (description.isNullOrEmpty()) "" else ": $description") + (if (code.isNullOrEmpty()) "" else " ($code)")
    }

    private fun queryValue(url: String, wanted: String): String? {
        val raw = try {
            URI(url).rawQuery
        } catch (error: Exception) {
            url.substringAfter('?', "")
        } ?: return null
        for (pair in raw.split('&').filter { it.isNotEmpty() }) {
            val separator = pair.indexOf('=')
            val name = URLDecoder.decode(if (separator < 0) pair else pair.substring(0, separator), "UTF-8")
            if (name == wanted) return if (separator < 0) "" else URLDecoder.decode(pair.substring(separator + 1).replace("+", "%2B"), "UTF-8")
        }
        return null
    }

    /** Mac'teki URLComponents gibi kodlar: sorguda izinli karakterler (":" ve "/" dahil) olduğu gibi kalır. */
    fun query(items: List<Pair<String, String>>) = items.joinToString("&") { encode(it.first) + "=" + encode(it.second) }

    private fun encode(text: String): String {
        val result = StringBuilder(text.length)
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val c = (byte.toInt() and 0xff).toChar()
            if (c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in "-._~:/?@!$'()*,;") result.append(c)
            else result.append('%').append("%02X".format(byte.toInt() and 0xff))
        }
        return result.toString()
    }
}
