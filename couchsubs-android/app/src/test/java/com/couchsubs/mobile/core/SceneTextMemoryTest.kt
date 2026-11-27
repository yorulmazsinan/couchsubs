// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Az önce sahne yazısı sayılıp atılan satırın (plaka, tabela, telefon mesajı) başka okunuşu altyazı olmaz (#1411).
 * Örnekler ortak deneme dosyasından (fixtures/scene-text-memory.json, core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac
 * SceneTextMemoryTests.swift ve Windows SceneTextMemoryTests.cs aynı dosyayı okur).
 */
class SceneTextMemoryTest {
    private fun texts(array: JSONArray) = (0 until array.length()).map { array.getString(it) }

    @Test
    fun sharedVectors() {
        val cases = JSONObject(Fixtures.text("scene-text-memory.json")).getJSONArray("cases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val memory = SceneTextMemory()
            val steps = case.getJSONArray("steps")
            for (j in 0 until steps.length()) {
                val step = steps.getJSONObject(j)
                val at = step.getLong("at")
                step.optJSONArray("dropped")?.let { memory.remember(texts(it), step.getString("reason"), at) }
                if (step.has("forget")) memory.forget(step.getString("forget"))
                step.optJSONArray("read")?.let { read ->
                    val kept = memory.filter(Reading(texts(read).map { TextLine(it) }), at)
                    assertEquals(case.getString("name"), texts(step.getJSONArray("kept")), kept.lines.map { it.text })
                }
            }
        }
    }

    /** Ortak dosyadaki nedenler çekirdeğin nedenleriyle aynı yazılır (biri değişirse dosya da değişmeli). */
    @Test
    fun rememberedReasonsMatchTheGate() {
        for (reason in listOf(SceneText.SIGN_REASON, SceneText.NUMBER_REASON, SceneText.PLATE_NUMBER_REASON,
            SceneText.MENU_ITEM_REASON, SceneText.TILTED_REASON, InkTone.REASON, Reading.OFF_BAND_REASON,
            SceneTextMemory.PHONE_REASON)) {
            assertTrue(reason, SceneTextMemory.remembers(reason))
        }
        for (reason in listOf(SceneMotion.REASON, PackageText.REASON, Reading.LIST_REASON, "karenin ortasında kısa satır")) {
            assertFalse(reason, SceneTextMemory.remembers(reason))
        }
    }

    @Test
    fun resetForgetsEverything() {
        val memory = SceneTextMemory()
        memory.remember(listOf("ALL GUN SALES ARE FINAL"), SceneText.SIGN_REASON, 0)
        memory.reset()
        val kept = memory.filter(Reading(listOf(TextLine("ALL GUN SALES ARE FINAL"))), 10)
        assertEquals(listOf("ALL GUN SALES ARE FINAL"), kept.lines.map { it.text })
        assertTrue(memory.removed.isEmpty())
    }

    private class Sender : SubtitleSender {
        val sent: MutableList<String> = Collections.synchronizedList(mutableListOf())
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text) }
        override fun clear() {}
    }

    /** Okumaları sırayla (her biri 12 kare) tam ekran alanda hattan geçirir; çevirmene gidenler ve günlük. */
    private fun run(vararg readings: Reading): Pair<List<String>, List<String>> {
        val requested = Collections.synchronizedList(mutableListOf<String>())
        val log = Collections.synchronizedList(mutableListOf<String>())
        val executor = Executors.newSingleThreadExecutor()
        var now = 1_000_000L
        val pipeline = SubtitlePipeline({ requested.add(it); "TR: $it" }, Sender(), { now }, executor)
        pipeline.onLog = { log.add(it) }
        for (reading in readings) {
            repeat(12) {
                pipeline.process(reading, CropRegion().box)
                now += 100
            }
        }
        executor.shutdown()
        assertTrue(executor.awaitTermination(30, TimeUnit.SECONDS))
        return requested.toList() to log.toList()
    }

    /**
     * #1411 (GTA 6, beta-105): plakanın "GOOD TIME STATE" yazısı bir karede plaka sayılıp atılıyor, bir sonraki karede tek
     * satır ve noktalı ("& COCOTIME STATE O.") okununca altyazı sanılıp çevriliyordu. Aynı okuma önceden plaka görülmeden
     * gelirse altyazı kuralı onu geçirir (denemenin kendisi bunu da doğrular).
     */
    @Test
    fun plateRereadAfterBeingDroppedIsNotTranslated() {
        val plate = Reading(listOf(
            TextLine("NIC", TextBox(0.47, 0.82, 0.53, 0.85), confidence = 1f),
            TextLine("COCOTIME STATE A", TextBox(0.42, 0.86, 0.58, 0.89), confidence = 1f),
        ))
        val reread = Reading(listOf(TextLine("& COCOTIME STATE O.", TextBox(0.42, 0.86, 0.58, 0.89), confidence = 1f)))
        val (alone, aloneLog) = run(reread)
        assertEquals(aloneLog.joinToString("\n"), 1, alone.size)
        val (after, afterLog) = run(plate, reread)
        assertEquals(afterLog.joinToString("\n"), emptyList<String>(), after)
        assertTrue(afterLog.joinToString("\n"), afterLog.any { it.contains(SceneTextMemory.REASON) && it.contains("plaka/tabela") })
    }
}
