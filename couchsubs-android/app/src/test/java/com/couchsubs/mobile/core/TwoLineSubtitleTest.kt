// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.Executors
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GitHub #715: iki satırlı altyazının (üst satır 6-7 sözcük, alttaki devamı 1-2 sözcük, ortalanmış) yalnız ALT satırı
 * çevriliyordu. Alt satır üstten sonra belirince üst satır "uçta bekleyen görev satırı" sanılıp atılıyordu
 * ([StickyRows.LINGER_MS]). İki satır hep tek altyazı olmalı; görev satırı varken de
 * (Windows: TwoLineSubtitleTests.cs, Mac: TwoLineSubtitleTests.swift).
 */
class TwoLineSubtitleTest {
    private val objectiveText = "Go to the bank."
    private val subtitles = listOf(
        listOf("Local junkies might find a car missing its", "catalytic converter."),
        listOf("I already told you we should leave right", "now."),
        listOf("You never listen to anything I say about", "money."),
        listOf("I already explained everything about the plan to", "Lucia."),
        listOf("We are going to need a much bigger", "boat, man."),
    )
    private val line = 0.08

    private fun row(text: String, top: Double, width: Double, height: Double = line) =
        TextLine(text, TextBox(0.5 - width / 2, top, 0.5 + width / 2, top + height))

    /**
     * 100 ms'de bir kare. Her altyazı 3 sn: üst satır hemen, alt satır [delay] ms sonra; alt satır dar ve kutusu daha alçak
     * (0,7 kat). [objective]: görev altta (true), üstte (false) ya da yok (null); görev altyazılardan 2 sn önce belirir.
     * [typing]: üst satır da yazılır gibi büyür.
     */
    private fun frames(delay: Int, objective: Boolean?, typing: Boolean): List<Reading> {
        val frames = mutableListOf<Reading>()
        if (objective != null) repeat(20) { frames.add(Reading(listOf(row(objectiveText, if (objective) 0.8 else 0.2, 0.3)))) }
        for (lines in subtitles) {
            val top = if (objective == false) 0.35 else 0.6
            for (t in 0 until 3000 step 100) {
                val rows = mutableListOf<TextLine>()
                if (objective == false) rows.add(row(objectiveText, 0.2, 0.3))
                var upper = lines[0]
                if (typing) upper = upper.take(minOf(upper.length, 4 + upper.length * t / maxOf(1, delay)))
                rows.add(row(upper, top, 0.6 * upper.length / lines[0].length))
                if (t >= delay) rows.add(row(lines[1], top + line, 0.12, line * 0.7))
                if (objective == true) rows.add(row(objectiveText, 0.8, 0.3))
                frames.add(Reading(rows))
            }
            val between = if (objective == null) Reading.Empty else Reading(listOf(row(objectiveText, if (objective) 0.8 else 0.2, 0.3)))
            repeat(3) { frames.add(between) }
        }
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

    private fun run(delay: Int, objective: Boolean?, typing: Boolean = false) {
        val executor = Executors.newSingleThreadExecutor { Thread(it, "test translate").apply { isDaemon = true } }
        try {
            var now = 0L
            val translator = Recording()
            val pipeline = SubtitlePipeline(translator, Silent(), { now }, executor).apply { packWait = 0; cleanWait = 0 }
            val area = TextBox(0.0, 0.0, 1.0, 1.0)
            for (reading in frames(delay, objective, typing)) {
                pipeline.process(reading, area)
                executor.submit {}.get()
                now += 100
            }
            val requested = translator.requested.toList()
            val label = "delay: $delay objective: $objective typing: $typing — istekler: $requested"
            for (lines in subtitles) {
                assertTrue("birlikte çevrilmedi: ${lines[0]} / ${lines[1]} — $label",
                    requested.any { it.contains(lines[0]) && it.contains(lines[1]) })
                assertFalse("alt satır tek başına çevrildi: ${lines[1]} — $label", requested.any { it.trim() == lines[1] })
            }
            assertFalse("görev karıştı — $label", requested.any { it.contains("Go to the bank") && it.trim() != objectiveText })
        } finally {
            executor.shutdownNow()
        }
    }

    @Test fun togetherNoObjective() = run(0, null)
    @Test fun late300NoObjective() = run(300, null)
    @Test fun late800NoObjective() = run(800, null)
    @Test fun late1500NoObjective() = run(1500, null)
    @Test fun typing1500NoObjective() = run(1500, null, typing = true)
    @Test fun togetherObjectiveBelow() = run(0, true)
    @Test fun late800ObjectiveBelow() = run(800, true)
    @Test fun late1500ObjectiveBelow() = run(1500, true)
    @Test fun typing1500ObjectiveBelow() = run(1500, true, typing = true)
    @Test fun late800ObjectiveAbove() = run(800, false)
    @Test fun late1500ObjectiveAbove() = run(1500, false)
}
