// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.Executors
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kullanıcı bildirimi (GTA 6): oyun altta "x yere git" gibi bir görev yazısı gösterirken o sırada gelen altyazıların hiçbiri
 * çevrilmiyordu. Görev satırı sabit dururken üstünde ya da altında değişen altyazıların hepsi çevrilmeli, görev hiçbir
 * altyazıya karışmamalı (Windows: ObjectiveWithDialogueTests.cs, Mac: ObjectiveWithDialogueTests.swift).
 */
class ObjectiveWithDialogueTest {
    private val objective = "Go to the bank."
    private val dialogue = listOf(
        listOf("We have to move before the cops show up."),
        listOf("I told you this was a bad idea,", "but you never listen to me."),
        listOf("Lucia: Just drive the car and stay calm."),
        listOf("Where did they take all the money?"),
        listOf("Nobody saw us leave the place.", "Keep your head down for a while."),
    )
    private val line = 0.08

    private fun row(text: String, top: Double, width: Double = 0.6) =
        TextLine(text, TextBox(0.5 - width / 2, top, 0.5 + width / 2, top + line))

    /** Görev önce tek başına ([objectiveFirst] kare), sonra her altyazı 4 kare (2 sn) görevle birlikte. */
    private fun frames(below: Boolean, gap: Double, objectiveFirst: Int): List<Reading> {
        val alone = Reading(listOf(row(objective, if (below) 0.8 else 0.2, 0.3)))
        val frames = MutableList(objectiveFirst) { alone }
        for (lines in dialogue) {
            val height = lines.size * line
            val rows = mutableListOf<TextLine>()
            if (below) {
                val top = 0.8 - gap * line - height
                lines.forEachIndexed { i, text -> rows.add(row(text, top + i * line)) }
                rows.add(row(objective, 0.8, 0.3))
            } else {
                rows.add(row(objective, 0.2, 0.3))
                val top = 0.2 + line + gap * line
                lines.forEachIndexed { i, text -> rows.add(row(text, top + i * line)) }
            }
            repeat(4) { frames.add(Reading(rows)) }
        }
        repeat(4) { frames.add(alone) }
        return frames
    }

    private class Silent : SubtitleSender {
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {}
        override fun clear() {}
    }

    private class Recording : TextTranslator {
        val requested = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun translate(text: String): String {
            requested.add(text)
            return "TR: $text"
        }
    }

    private fun run(below: Boolean, gap: Double, objectiveFirst: Int) {
        val executor = Executors.newSingleThreadExecutor { Thread(it, "test translate").apply { isDaemon = true } }
        try {
            var now = 0L
            val translator = Recording()
            val pipeline = SubtitlePipeline(translator, Silent(), { now }, executor).apply { packWait = 0; cleanWait = 0 }
            val area = TextBox(0.0, 0.0, 1.0, 1.0)
            for (reading in frames(below, gap, objectiveFirst)) {
                pipeline.process(reading, area)
                executor.submit {}.get()
                now += 500
            }
            val requested = translator.requested.toList()
            val label = "below: $below gap: $gap first: $objectiveFirst — istekler: $requested"
            // Görev ile aynı anda beliren ilk altyazı hangisinin görev olduğu bilinemediği için şart değil.
            val expected = if (objectiveFirst == 0) dialogue.drop(1) else dialogue
            val missing = expected.flatten().map { it.removePrefix("Lucia: ") }.filter { text -> requested.none { it.contains(text) } }
            assertEquals("çevrilmedi — $label", emptyList<String>(), missing)
            val mixed = requested.filter { it.contains("Go to the bank") && it.trim() != objective }
                .filter { objectiveFirst != 0 || !it.contains(dialogue[0][0]) }
            assertEquals("görev karıştı — $label", emptyList<String>(), mixed)
        } finally {
            executor.shutdownNow()
        }
    }

    @Test fun everyDialogueIsTranslatedWhileObjectiveStays() {
        for ((below, gap, first) in listOf(Triple(true, 0.1, 4), Triple(true, 1.5, 4), Triple(false, 0.1, 4),
            Triple(false, 1.5, 4), Triple(true, 0.1, 20), Triple(true, 1.5, 20), Triple(false, 0.1, 20),
            Triple(true, 0.1, 0), Triple(true, 1.5, 0))) {
            run(below, gap, first)
        }
    }
}
