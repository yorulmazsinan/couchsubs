// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.translation

import org.junit.Assert.assertEquals
import org.junit.Test

/** Ayarlar'daki "Bu ay: … karakterin … kadarı kullanıldı." satırının kaynağı (Mac/iPhone: DeepLTranslator.check). */
class DeepLUsageTest {
    private class Scripted(private val status: Int, private val body: String) : Http {
        var url: String? = null
        var headers: Map<String, String> = emptyMap()
        override fun send(method: String, url: String, headers: Map<String, String>, body: String?, timeoutMs: Int): Pair<Int, String> {
            this.url = url
            this.headers = headers
            return status to this.body
        }
    }

    @Test
    fun usageIsReadFromTheUsageEndpoint() {
        val http = Scripted(200, """{"character_count":12345,"character_limit":500000}""")
        val usage = KeyCheck.deepLUsage(" abc:fx ", http)
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.VALID, 12_345, 500_000), usage)
        assertEquals("https://api-free.deepl.com/v2/usage", http.url)
        assertEquals("DeepL-Auth-Key abc:fx", http.headers["Authorization"])
    }

    @Test
    fun usedUpLimitIsQuotaExceededWithTheNumbers() {
        val usage = KeyCheck.deepLUsage("abc", Scripted(200, """{"character_count":500000,"character_limit":500000}"""))
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.QUOTA_EXCEEDED, 500_000, 500_000), usage)
        assertEquals(OnlineKeyState.QUOTA_EXCEEDED, KeyCheck.deepL("abc", Scripted(200, """{"character_count":500000,"character_limit":500000}""")))
    }

    @Test
    fun rejectedOrMissingKeyAndBrokenReply() {
        assertEquals(OnlineKeyState.INVALID, KeyCheck.deepLUsage("abc", Scripted(403, "")).state)
        assertEquals(OnlineKeyState.INVALID, KeyCheck.deepLUsage("  ", Scripted(200, "{}")).state)
        // JSON olmayan 200 yanıtı (otel/kafe ağının giriş sayfası gibi) DeepL'in yanıtı değildir: ağ hatası.
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.UNREACHABLE, reason = KeyCheck.Reason.NETWORK),
            KeyCheck.deepLUsage("abc", Scripted(200, "not json")))
        val offline = Http { _, _, _, _, _ -> throw java.net.UnknownHostException("api.deepl.com") }
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.UNREACHABLE, reason = KeyCheck.Reason.NETWORK), KeyCheck.deepLUsage("abc", offline))
    }

    private val key = "0f3c1a2b-1111-2222-3333-444455556666:fx"

    /** Yapıştırırken araya giren görünmez karakterler her yerden silinir (Mac/iPhone ve Windows ile aynı). */
    @Test
    fun invisibleCharactersAreRemovedEverywhere() {
        val pasted = "﻿ 0f3c1a2b-1111 -2222-​3333-4444\n55556666­:fx\t\r\n"
        assertEquals(key, DeepLKey.clean(pasted))
        val http = Scripted(200, """{"character_count":1,"character_limit":500000}""")
        assertEquals(OnlineKeyState.VALID, KeyCheck.deepLUsage(pasted, http).state)
        assertEquals("DeepL-Auth-Key $key", http.headers["Authorization"])
        assertEquals("https://api-free.deepl.com/v2/usage", http.url)
    }

    @Test
    fun nonAsciiKeyIsMalformedWithoutRequest() {
        val http = Scripted(200, "{}")
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.INVALID, reason = KeyCheck.Reason.MALFORMED_KEY),
            KeyCheck.deepLUsage("0f3c1a2b-1111-2222-ş333-444455556666:fx", http))
        assertEquals(null, http.url)
    }

    /** Her hata kendi nedeniyle döner; 429 ağ hatası değildir (anahtar reddedilmedi, kaydedilir). */
    @Test
    fun eachFailureKeepsItsReason() {
        val limited = KeyCheck.deepLUsage(key, Scripted(429, ""))
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.BUSY, reason = KeyCheck.Reason.RATE_LIMITED, code = 429), limited)
        assertEquals(true, KeyCheck.accepted(limited.state))
        assertEquals("BUSY (HTTP 429 (çok sık istek))", limited.logDescription)
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.UNREACHABLE, reason = KeyCheck.Reason.HTTP_STATUS, code = 503),
            KeyCheck.deepLUsage(key, Scripted(503, "")))
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.INVALID, reason = KeyCheck.Reason.HTTP_STATUS, code = 403),
            KeyCheck.deepLUsage(key, Scripted(403, "")))
        assertEquals(OnlineKeyState.QUOTA_EXCEEDED, KeyCheck.deepLUsage(key, Scripted(456, "")).state)
    }

    /** Pro/sınırsız hesap ve eksik ya da beklenmedik alanlar: anahtar geçerli kalır, değerler esnek çözümlenir. */
    @Test
    fun usageIsParsedFlexibly() {
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.VALID, 5_947_223, KeyCheck.UNLIMITED), KeyCheck.deepLUsage(key, Scripted(200,
            """{"character_count":5947223,"character_limit":1000000000000,"products":[{"product_type":"translate"}],"start_time":"2025-05-13T09:18:42Z"}""")))
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.VALID, 12, 0), KeyCheck.deepLUsage(key, Scripted(200, """{"character_count":12.0}""")))
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.VALID, 7, Long.MAX_VALUE),
            KeyCheck.deepLUsage(key, Scripted(200, """{"character_count":"7","character_limit":1e30}""")))
        assertEquals(KeyCheck.DeepLUsage(OnlineKeyState.VALID, Long.MAX_VALUE, 0),
            KeyCheck.deepLUsage(key, Scripted(200, """{"character_count":99999999999999999999999,"character_limit":true}""")))
    }
}
