// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * Yazı tanımanın bozduğu satır çeviri motoruna gitmez (GitHub #1293). Ortak deneme dosyası fixtures/read-plausibility.json
 * (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac ReadPlausibilityTests.swift ve Windows ReadPlausibilityTests.cs
 * aynı dosyayı okur).
 */
class ReadPlausibilityTest {
    @Test fun sharedVectors() {
        val vectors = JSONObject(Fixtures.text("read-plausibility.json"))
        val garbled = vectors.getJSONArray("garbled")
        for (i in 0 until garbled.length()) assertNotNull(garbled.getString(i), ReadPlausibility.reason(garbled.getString(i)))
        val kept = vectors.getJSONArray("kept")
        for (i in 0 until kept.length()) {
            val text = kept.getString(i)
            assertNull("$text: ${ReadPlausibility.reason(text)}", ReadPlausibility.reason(text))
        }
    }

    /** Var olan sahne yazısı, altyazı ve telefon fixture'larındaki satırların hiçbiri bozuk sayılmaz. */
    @Test fun existingSubtitleFixturesAreKept() {
        for (name in listOf("scene-text.json", "growing-lines.json", "settled-text.json", "phone-chat.json")) {
            val texts = mutableListOf<String>()
            fun walk(value: Any?, key: String?) {
                when (value) {
                    is String -> if (key == "text") texts.add(value)
                    is JSONArray -> for (i in 0 until value.length()) walk(value.get(i), key)
                    is JSONObject -> for (k in value.keys()) walk(value.get(k), k)
                }
            }
            walk(JSONObject(Fixtures.text(name)), null)
            assertTrue(name, texts.isNotEmpty())
            for (text in texts) assertNull("$name: $text: ${ReadPlausibility.reason(text)}", ReadPlausibility.reason(text))
        }
    }

    @Test fun logIsRateLimited() {
        var time = 0L
        val log = ReadPlausibility.Log { time }
        assertEquals("okuma bozuk görünüyor, çeviriye gönderilmedi: «es aepressea / arter» (r)", log.line("es aepressea\narter", "r"))
        assertNull(log.line("es aepressea\narter", "r"))
        repeat(ReadPlausibility.Log.PER_MINUTE - 1) { assertNotNull(log.line("satır $it", "r")) }
        assertNull(log.line("bir satır daha", "r"))
        time += ReadPlausibility.Log.REPEAT_MS
        assertEquals("okuma bozuk görünüyor, çeviriye gönderilmedi: «es aepressea / arter» (r) (+1 satır sınır yüzünden yazılmadı)",
            log.line("es aepressea\narter", "r"))
    }

    /** Bozuk okuma motora gitmez, önceki altyazı ekranda kalır; aynı satır düzgün okununca çevrilir. Günlüğe bir kez yazılır. */
    @Test fun garbledReadIsNotTranslatedAndThePreviousSubtitleStays() {
        val clean = "Get in the car, now."
        val garbled = "es aepressea arter Donnıas aeatIT"
        val fixedRead = "He's depressed after Donna's death."
        val executor = Executors.newSingleThreadExecutor()
        val requested = Collections.synchronizedList(mutableListOf<String>())
        val log = Collections.synchronizedList(mutableListOf<String>())
        var clears = 0
        val translator = object : TextTranslator {
            override fun translate(text: String): String {
                requested.add(text)
                return "TR: $text"
            }
        }
        val sender = object : SubtitleSender {
            override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {}
            override fun clear() { clears++ }
        }
        var time = 0L
        val pipeline = SubtitlePipeline(translator, sender, { time }, executor).apply { onLog = { log.add(it) } }
        fun run(text: String, frames: Int) = repeat(frames) {
            pipeline.process(Reading.fromText(text), CropRegion().box)
            executor.submit {}.get(5, TimeUnit.SECONDS)
            time += 250
        }
        try {
            run(clean, 4)
            assertEquals(listOf(clean), requested.toList())
            run(garbled, 16)
            val trace = log.joinToString("\n")
            assertEquals(trace, listOf(clean), requested.toList())
            assertEquals(trace, 0, clears)
            assertEquals(trace, 1, log.count { it.startsWith("okuma bozuk görünüyor, çeviriye gönderilmedi: «$garbled»") })
            run(fixedRead, 4)
            assertEquals(log.joinToString("\n"), listOf(clean, fixedRead), requested.toList())
        } finally {
            executor.shutdownNow()
        }
    }
}
