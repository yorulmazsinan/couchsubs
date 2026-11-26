// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * Uzun altyazı satırları: aşama aşama beliren satır tek altyazıdır ve yerinde güncellenir, yazı tanıma farkıyla okunan
 * uzun satır motora bir kez gider, art arda iki farklı uzun satırın ikisi de gösterilir (beta-104, Mafia: The Old
 * Country). Ortak deneme dosyası fixtures/growing-lines.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac
 * GrowingLinesTests.swift ve Windows GrowingLinesTests.cs aynı dosyayı okur).
 */
class GrowingLinesTest {
    companion object {
        /** Harfleri ROT13 ile kaydırır (çeviri kaynağa benzemesin); iki kez uygulanınca kaynak geri gelir. */
        fun rot13(text: String) = text.map { c ->
            when (c) {
                in 'a'..'z' -> 'a' + (c - 'a' + 13) % 26
                in 'A'..'Z' -> 'A' + (c - 'A' + 13) % 26
                else -> c
            }
        }.joinToString("")
    }

    @Test fun fixture() {
        val cases = JSONObject(Fixtures.text("growing-lines.json")).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val item = cases.getJSONObject(i)
            val name = item.getString("name")
            val reads = mutableListOf<String>()
            val parts = item.getJSONArray("reads")
            for (j in 0 until parts.length()) {
                val read = parts.getJSONObject(j)
                repeat(read.getInt("times")) { reads.add(read.getString("text")) }
            }
            val frameMs = item.getLong("frameMs")
            val blocked = item.getString("translator") == "blocked"
            val executor = Executors.newSingleThreadExecutor()
            val release = CountDownLatch(if (blocked) 1 else 0)
            val requested = Collections.synchronizedList(mutableListOf<String>())
            val sent = Collections.synchronizedList(mutableListOf<String>())
            val replaced = Collections.synchronizedList(mutableListOf<Boolean>())
            val log = Collections.synchronizedList(mutableListOf<String>())
            val translator = object : TextTranslator {
                override fun translate(text: String): String {
                    requested.add(text)
                    check(release.await(5, TimeUnit.SECONDS))
                    return "TR: " + rot13(text)
                }
            }
            val sender = object : SubtitleSender {
                override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
                    sent.add(text); replaced.add(replaces)
                }
                override fun clear() {}
            }
            var time = 0L
            val pipeline = SubtitlePipeline(translator, sender, { time }, executor).apply {
                holdReadings = true
                onLog = { log.add(it) }
            }
            try {
                for (text in reads) {
                    pipeline.process(Reading.fromText(text), CropRegion().box)
                    if (!blocked) executor.submit {}.get(5, TimeUnit.SECONDS)
                    time += frameMs
                }
                release.countDown()
                executor.submit {}.get(5, TimeUnit.SECONDS)
            } finally {
                release.countDown()
                executor.shutdownNow()
            }
            val shown = sent.map { if (it.startsWith("TR: ")) rot13(it.removePrefix("TR: ")) else it }
            val trace = "$name\nmotor: $requested\ngösterilen: $shown\nyerine: $replaced\n" + log.joinToString("\n")
            val expect = item.getJSONObject("expect")
            expect.optJSONArray("engineCalls")?.let { calls ->
                assertEquals(trace, (0 until calls.length()).map { calls.getString(it) }, requested.toList())
            }
            if (expect.has("maxEngineCalls")) assertTrue(trace, requested.size <= expect.getInt("maxEngineCalls"))
            expect.optJSONArray("shown")?.let { expected ->
                assertEquals(trace, (0 until expected.length()).map { expected.getString(it) }, shown)
            }
            assertEquals(trace, expect.getInt("fresh"), replaced.count { !it })
            assertEquals(trace, expect.getString("last"), shown.lastOrNull())
        }
    }

    @Test fun looseGrowth() {
        assertTrue(TextMatch.isLooseGrowth("Listen to me, Enz0. The Don wants you down at the docks", "Listen to me, Enzo. The Don wants you down"))
        assertTrue(TextMatch.isLooseGrowth("You think the farnily forgets what you did for us\nback in Sicily?",
            "You think the family forgets what you did for us"))
        assertFalse(TextMatch.isLooseGrowth("the docks before the sun comes up, Enzo.", "Listen to me, Enz0. The docks before the sun"))
        assertFalse(TextMatch.isLooseGrowth("Listen to me, Enzo. The Don wants you down", "Listen to me, Enzo. The Don wants you down"))
        assertFalse(TextMatch.isLooseGrowth("I don't know what you're talking about.", "I don't know what you want"))
    }

    @Test fun jitter() {
        val long = "Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done quietly."
        assertTrue(TextMatch.isJitterOf("$long Il", long))
        assertTrue(TextMatch.isJitterOf("Listen to me, Enz0. The Don wants y0u down at the docks before\nthe sun comes up, and he wants it done quietly.", long))
        assertTrue(TextMatch.isJitterOf("Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done", long))
        assertFalse(TextMatch.isJitterOf("$long Go.", long))
        assertFalse(TextMatch.isJitterOf("$long Then come home.", long))
        assertFalse(TextMatch.isJitterOf("Listen to me, Enzo. The Don doesn't want you down at the docks before\nthe sun comes up, and he wants it done quietly.", long))
        assertFalse(TextMatch.isJitterOf("Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done in 5.", long))
        assertFalse(TextMatch.isJitterOf("Listen to me, Enzo.", long))
    }

    /** Gecikme dökümü 30 sn'de bir tek satır: her aşama adıyla (#1349 biçimi). */
    @Test fun timingLineNamesEveryStage() {
        val executor = Executors.newSingleThreadExecutor()
        val translator = object : TextTranslator {
            override fun translate(text: String) = "TR: " + rot13(text)
        }
        val sender = object : SubtitleSender {
            override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {}
            override fun clear() {}
        }
        var time = 0L
        val lines = Collections.synchronizedList(mutableListOf<String>())
        val pipeline = SubtitlePipeline(translator, sender, { time }, executor).apply {
            holdReadings = true
            onTiming = { lines.add(it) }
        }
        val reads = List(6) { "Get in the car, Jason" } + listOf("", "")
        try {
            reads.forEachIndexed { index, text ->
                pipeline.process(Reading.fromText(text), CropRegion().box, capturedAt = time, ocrMs = 40)
                executor.submit {}.get(5, TimeUnit.SECONDS)
                time += if (index == reads.size - 2) StageTiming.PERIOD_MS else 200
            }
        } finally { executor.shutdownNow() }
        assertEquals(lines.toString(), 1, lines.size)
        val line = lines[0]
        assertTrue(line, line.startsWith("altyazı aşama süreleri"))
        for (stage in listOf(SubtitlePipeline.STAGE_FRAME_GAP, SubtitlePipeline.STAGE_OCR, SubtitlePipeline.STAGE_SETTLE,
            SubtitlePipeline.STAGE_HOLD, SubtitlePipeline.STAGE_QUEUE, SubtitlePipeline.STAGE_ENGINE, SubtitlePipeline.STAGE_TOTAL)) {
            assertTrue("$stage: $line", line.contains("$stage "))
        }
        // Satır 2. karede doğrulandı (ilk okumadan 200 ms sonra).
        assertTrue(line, line.contains("${SubtitlePipeline.STAGE_SETTLE} 1× ort 200,0"))
    }
}
