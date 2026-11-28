package com.couchsubs.mobile.translation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Yapay zekâ anahtarı yapıştırılırken araya giren görünmez karakterler (Mac/iPhone: AITranslationCore.test, Windows:
 * AiTranslator.TestAsync ile aynı kural): anahtar her yerden temizlenip gönderilir; temizlendikten sonra görünür ASCII
 * dışında karakter kalırsa istek hiç gönderilmez.
 */
class AiKeyCheckTest {
    // Sahte anahtar (gerçek değil); biçimi Google AI Studio anahtarına benzer.
    private val key = "AIzaSyFAKE-test_key_0123456789abcdefghij"
    private val model = AiModel("gemini-3.5-flash-lite", "Fast")
    private val ok = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"[\\\"KRATOS: Şimdi gidiyoruz.\\\"]\"}]}}]}"

    @Test
    fun invisibleCharactersAreRemovedBeforeSending() {
        val sent = mutableListOf<String?>()
        val http = Http { _, _, headers, _, _ -> sent.add(headers["x-goog-api-key"]); 200 to ok }
        val pasted = listOf(
            "﻿$key\n", "${key.take(20)}​${key.drop(20)}", "${key.take(10)} ${key.drop(10)}",
            "${key.take(10)}\n${key.drop(10)}", " $key‎", "${key.take(5)}­${key.drop(5)}",
        )
        for (typed in pasted) assertEquals(OnlineKeyState.VALID, KeyCheck.ai(AiProvider.GEMINI, typed, model, http))
        assertEquals(List(pasted.size) { key }, sent)
    }

    @Test
    fun keyWithCharacterNoServiceUsesIsNotSent() {
        var calls = 0
        val http = Http { _, _, _, _, _ -> calls++; 200 to ok }
        assertEquals(OnlineKeyState.INVALID, KeyCheck.ai(AiProvider.GEMINI, key.replace('a', 'á'), model, http))
        assertEquals(OnlineKeyState.INVALID, KeyCheck.ai(AiProvider.GEMINI, "​ \n", model, http))
        assertEquals(0, calls)
    }

    @Test
    fun translationRequestUsesCleanedKey() {
        val request = AiRequest.build(AiProvider.GEMINI, "​$key\r\n", model, listOf("Hi"), emptyList())
        assertEquals(key, request.headers["x-goog-api-key"])
        assertNull(request.headers["Authorization"])
    }
}
