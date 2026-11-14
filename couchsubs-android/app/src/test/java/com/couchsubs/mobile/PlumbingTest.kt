// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile

import com.couchsubs.mobile.core.LinePool
import com.couchsubs.mobile.core.PackKey
import com.couchsubs.mobile.remoteplay.PsnAccount
import com.couchsubs.mobile.remoteplay.RegisteredConsole
import com.couchsubs.mobile.remoteplay.Registration
import com.couchsubs.mobile.remoteplay.RegistrationFailure
import com.couchsubs.mobile.translation.AiModel
import com.couchsubs.mobile.translation.AiProvider
import com.couchsubs.mobile.translation.AiRequest
import com.couchsubs.mobile.translation.AiTranslator
import com.couchsubs.mobile.translation.DeepLTranslator
import com.couchsubs.mobile.translation.Http
import com.couchsubs.mobile.translation.OnlineKeyState
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.URL
import java.nio.file.Files

class RemotePlayLogicTest {
    @Test
    fun pinIsParsedLikeTheDesktop() {
        assertEquals(12345678, Registration.parsePin("1234 5678"))
        assertEquals(12345678, Registration.parsePin("1234-5678"))
        assertEquals(1, Registration.parsePin("00000001"))
        assertNull(Registration.parsePin("1234567"))
        assertNull(Registration.parsePin("1234567a"))
        assertEquals(12345678, Registration.parsePin("١٢٣٤٥٦٧٨"))
    }

    @Test
    fun failuresAreExplained() {
        assertEquals(RegistrationFailure.WRONG_ACCOUNT, Registration.failureFrom(0x80108b02.toInt(), emptyList()))
        assertEquals(RegistrationFailure.WRONG_CODE, Registration.failureFrom(0x80108b09.toInt(), emptyList()))
        assertEquals(RegistrationFailure.NO_ANSWER, Registration.failureFrom(null, listOf("Regist search failed")))
        assertEquals(RegistrationFailure.FAILED, Registration.failureFrom(null, emptyList()))
        assertEquals("0x80108b09 (Regist failed)", Registration.detailFrom(listOf("x", "Reported Application Reason: 0x80108b09 (Regist failed)")))
    }

    @Test
    fun accountIdIsLittleEndian() {
        assertArrayEquals(byteArrayOf(1, 0, 0, 0, 0, 0, 0, 0), PsnAccount.accountIdBytes("1"))
        assertArrayEquals(ByteArray(8) { -1 }, PsnAccount.accountIdBytes("18446744073709551615"))
        assertNull(PsnAccount.accountIdBytes("-1"))
        assertNull(PsnAccount.accountIdBytes("abc"))
    }

    @Test
    fun redirectGivesCodeOrSonyError() {
        val base = PsnAccount.REDIRECT_PREFIX
        assertEquals("v3.abc", PsnAccount.codeFromRedirect("$base?code=v3.abc&cid=1"))
        assertNull(PsnAccount.codeFromRedirect("https://example.com/?code=x"))
        assertEquals("access_denied: User denied (4165)",
            PsnAccount.errorFromRedirect("$base?error=access_denied&error_description=User+denied&error_code=4165"))
        assertTrue(PsnAccount.authorizeUrl.contains("redirect_uri=https://remoteplay.dl.playstation.net/remoteplay/redirect"))
        assertTrue(PsnAccount.authorizeUrl.contains("scope=psn:clientapp%20referenceDataService"))
    }

    @Test
    fun wakeCredentialIsTheHexRegistKey() {
        val key = "0a1b2c3d".toByteArray() + ByteArray(8)
        assertEquals(0x0a1b2c3dL, RegisteredConsole("h", "PS5", key, ByteArray(16)).wakeCredential)
    }
}

class OnlineTranslationTest {
    private class FakeHttp(val status: Int, val body: String) : Http {
        val requests = mutableListOf<Triple<String, Map<String, String>, String?>>()
        override fun send(method: String, url: String, headers: Map<String, String>, body: String?, timeoutMs: Int): Pair<Int, String> {
            requests.add(Triple(url, headers, body))
            return status to this.body
        }
    }

    @Test
    fun deepLSendsSentencesAndKeepsSpeakerLabels() {
        val http = FakeHttp(200, "{\"translations\":[{\"text\":\"Şimdi gidiyoruz.\"},{\"text\":\"Yakın dur, evlat.\"}]}")
        val translator = DeepLTranslator("abc:fx", null, http)
        assertEquals("KRATOS: Şimdi gidiyoruz. Yakın dur, evlat.", translator.translate("KRATOS: We go now. Stay close, boy."))
        val (url, headers, body) = http.requests.single()
        assertEquals("https://api-free.deepl.com/v2/translate", url)
        assertEquals("DeepL-Auth-Key abc:fx", headers["Authorization"])
        val json = JSONObject(body!!)
        assertEquals(2, json.getJSONArray("text").length())
        assertEquals("prefer_less", json.getString("formality"))
        // Aynı satır ikinci kez sorulmaz.
        translator.translate("KRATOS: We go now. Stay close, boy.")
        assertEquals(1, http.requests.size)
    }

    @Test
    fun failureFallsBackToTheLocalEngine() {
        val translator = DeepLTranslator("bad", { "yerel: $it" }, FakeHttp(403, ""))
        assertEquals("yerel: Run!", translator.translate("Run!"))
        assertEquals(OnlineKeyState.INVALID, translator.lastError)
    }

    @Test
    fun claudeRequestShapeAndReply() {
        val http = FakeHttp(200, "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"…\"},{\"type\":\"text\",\"text\":\"[\\\"Koş!\\\"]\"}]}")
        val translator = AiTranslator(AiProvider.CLAUDE, "sk", AiModel("claude-x", "Hızlı", effort = "low"), null, http)
        assertEquals("Koş!", translator.translate("Run!"))
        val (url, headers, body) = http.requests.single()
        assertEquals("https://api.anthropic.com/v1/messages", url)
        assertEquals("2023-06-01", headers["anthropic-version"])
        val json = JSONObject(body!!)
        assertEquals("claude-x", json.getString("model"))
        assertEquals("low", json.getJSONObject("output_config").getString("effort"))
        assertTrue(json.getJSONArray("messages").getJSONObject(0).getString("content").endsWith("[\"Run!\"]"))
    }

    @Test
    fun translationsAcceptFencedArraysAndPlainText() {
        assertEquals(listOf("Bir", "İki"), AiRequest.translations("```json\n[\"Bir\", \"İki\"]\n```", 2))
        assertEquals(listOf("Koş!"), AiRequest.translations("\"Koş!\"", 1))
        assertEquals(OnlineKeyState.INVALID, AiRequest.failure(400, "API key not valid"))
        assertEquals(OnlineKeyState.MODEL_REJECTED, AiRequest.failure(404, ""))
    }

    @Test
    fun sharedModelListParses() {
        val file = File(System.getProperty("couchsubs.packs") ?: return, "../ai-models.json")
        val models = AiModel.parse(file.readText())
        assertTrue(models.keys.containsAll(listOf("gemini", "openai", "claude")))
        assertTrue(models.getValue("gemini").first().freeTier)
    }
}

class LinePoolTest {
    @Test
    fun acceptsOnlyRealLines() {
        assertTrue(LinePool.accepts("Get in the car, Enzo."))
        assertFalse(LinePool.accepts("Hello"))
        assertFalse(LinePool.accepts("100/100 HP 25%"))
        assertFalse(LinePool.accepts("Across ou$3e waters"))
        assertFalse(LinePool.accepts("x ".repeat(200)))
    }

    @Test
    fun queuedLinesAreSentOnceAndSurviveRestart() {
        val file = File(Files.createTempDirectory("pool").toFile(), "pool.json")
        val bodies = mutableListOf<String>()
        var status = 503
        val post = { _: URL, body: String -> bodies.add(body); status to null }
        val pool = LinePool(file, "test", post = post, clock = { 1_700_000_000_000 })
        pool.offer("Get in the car, Enzo.")
        pool.offer("Get in the car, Enzo.")
        pool.flush()
        assertEquals(1, pool.queued.size)
        val reopened = LinePool(file, "test", post = post, clock = { 1_700_000_000_000 })
        assertEquals(1, reopened.queued.size)
        assertEquals(pool.installId, reopened.installId)
        status = 200
        reopened.flush()
        assertEquals(0, reopened.queued.size)
        val sent = JSONObject(bodies.last())
        assertEquals("android", sent.getString("platform"))
        val line = sent.getJSONArray("lines").getJSONObject(0)
        assertEquals(PackKey.key("Get in the car, Enzo."), line.getString("key"))
        assertEquals("2023-11-14T22:13:20Z", line.getString("firstSeen"))
        // Gönderilen satır yeniden kuyruğa girmez.
        reopened.offer("Get in the car, Enzo.")
        assertEquals(0, reopened.queued.size)
    }

    @Test
    fun disablingDropsTheQueue() {
        val pool = LinePool(File(Files.createTempDirectory("pool").toFile(), "pool.json"), "test", post = { _, _ -> throw IOException() })
        pool.offer("Get in the car, Enzo.")
        pool.setEnabled(false)
        assertEquals(0, pool.queued.size)
        pool.offer("Who is that man?")
        assertEquals(0, pool.queued.size)
    }
}
