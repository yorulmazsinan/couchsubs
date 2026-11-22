// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Görüntü kaynağı OBS'in Program projektörü: karede CouchSubs'ın OBS katmanındaki Türkçe altyazı da var (X bildirimi,
 * capture card + OBS). Telefonda OBS yolu yok; ortak süzgeç aynı kurallarla çalışır ve OBS'siz okumada hiçbir şey atmaz.
 * Mac/iPhone OwnSubtitleTests.swift ve Windows OwnSubtitleTests.cs ile aynı senaryolar.
 */
class OwnSubtitlesTest {
    private val english = "You shouldn't have done that, Lucia."
    private val turkish = "Bunu yapmamalıydın, Lucia. Çok üzgünüm."
    private val next = "Get in the car, now."
    private val nextTurkish = "Hemen arabaya bin."

    private val direct = object : java.util.concurrent.AbstractExecutorService() {
        override fun execute(command: Runnable) = command.run()
        override fun shutdown() {}
        override fun shutdownNow() = mutableListOf<Runnable>()
        override fun isShutdown() = false
        override fun isTerminated() = false
        override fun awaitTermination(timeout: Long, unit: java.util.concurrent.TimeUnit) = true
    }

    /** OBS projektörü: gönderilen çeviri ekrandayken okuyucu onu da (Türkçe harfleri bozulmuş) okur. */
    private inner class ProjectorScreen(private val covers: Boolean) : SubtitleSender {
        var english = this@OwnSubtitlesTest.english
        var shown: String? = null
        val sent = mutableListOf<String>()
        var clears = 0
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text); shown = text }
        override fun clear() { clears++; shown = null }

        val frame: Reading
            get() {
                val line = TextLine(english, TextBox(0.2, 0.40, 0.8, 0.60))
                val text = shown ?: return Reading(listOf(line))
                val own = TextLine(ocr(text), TextBox(0.18, if (covers) 0.38 else 0.70, 0.82, if (covers) 0.62 else 0.92))
                return Reading(if (covers) listOf(own) else listOf(line, own))
            }
    }

    private fun ocr(text: String) = text.map {
        mapOf('ı' to 'i', 'ş' to 's', 'ğ' to 'g', 'ç' to 'c', 'ö' to 'o', 'ü' to 'u',
            'İ' to 'I', 'Ş' to 'S', 'Ç' to 'C', 'Ö' to 'O', 'Ü' to 'U', 'Ğ' to 'G')[it] ?: it
    }.joinToString("")

    private class Result(val sent: List<String>, val clears: Int, val requested: List<String>, val log: List<String>)

    private fun run(covers: Boolean, frames: Int = 60, script: (Int) -> String? = { null }): Result {
        var now = 0L
        val screen = ProjectorScreen(covers)
        val requested = mutableListOf<String>()
        val translator = TextTranslator { text ->
            requested.add(text)
            when (text) { english -> turkish; next -> nextTurkish; else -> "Çeviri: $text" }
        }
        val log = mutableListOf<String>()
        val pipeline = SubtitlePipeline(translator, screen, { now }, direct).apply {
            packWait = 0; cleanWait = 0; onLog = { log.add(it) }
        }
        for (index in 0 until frames) {
            script(index)?.let { screen.english = it }
            // Karenin izi satırla değişir (kararlayıcı aynı izli boş okumayı "satır duruyor" sayar).
            pipeline.process(screen.frame, CropRegion().box, ByteArray(1) { (screen.english.length % 7 * 36).toByte() })
            now += 100
        }
        return Result(screen.sent, screen.clears, requested, log)
    }

    @Test
    fun ownSubtitleCoveringTheLineIsNotReadAsANewLine() {
        val result = run(covers = true)
        assertEquals(listOf(english), result.requested)
        assertEquals(listOf(turkish), result.sent)
        assertEquals(0, result.clears)
        assertTrue(result.log.joinToString("\n"), result.log.any { it.contains("kendi altyazısı") })
    }

    @Test
    fun ownSubtitleBelowTheLineIsIgnored() {
        val result = run(covers = false)
        assertEquals(listOf(english), result.requested)
        assertEquals(listOf(turkish), result.sent)
        assertEquals(0, result.clears)
    }

    @Test
    fun lineLeavingAndNextLineStillWorkBesideOwnSubtitle() {
        val result = run(covers = false, frames = 90) { if (it == 30) "" else if (it == 45) next else null }
        assertEquals(listOf(english, next), result.requested)
        assertEquals(listOf(turkish, nextTurkish), result.sent)
        assertEquals(1, result.clears)
    }

    @Test
    fun englishLineIsNeverTakenForOwnSubtitle() {
        var time = 0L
        val own = OwnSubtitles { time }
        val lucia = Reading(listOf(TextLine("Lucia, Jason!", TextBox(0.3, 0.8, 0.7, 0.9))))
        assertSame(lucia, own.split(lucia).first)
        own.record("Lucia, Jason! Buraya gelin.", "Lucia, Jason! Come here.", 15000)
        time += 500
        assertTrue(own.split(lucia).second.isEmpty())
        assertFalse(own.isOwn("Lucia, Jason! Come here."))
        assertFalse(own.isOwn("Come here, Lucia."))
        assertTrue(own.isOwn("Lucia, Jason! Buraya gelin."))
        time += 15000 + OwnSubtitles.TEXT_GRACE_MS + 1
        assertFalse(own.isOwn("Lucia, Jason! Buraya gelin."))
    }

    @Test
    fun wrappedAndGarbledOwnRowsAreDropped() {
        var time = 0L
        val own = OwnSubtitles { time }
        own.record("Bunu yapmamalıydın Lucia, şimdi hepimiz büyük bir belanın içindeyiz.",
            "You shouldn't have done that, Lucia. Now we're all in big trouble.", 15000)
        time += 300
        val first = TextLine("Bunu yapmamaliydin Lucia, simdi", TextBox(0.3, 0.80, 0.7, 0.85))
        val hint = TextLine("Press X to skip", TextBox(0.02, 0.94, 0.15, 0.97))
        val clean = own.split(Reading(listOf(first, TextLine("hepimiz buyuk bir belanin icindeyiz.", TextBox(0.31, 0.86, 0.69, 0.91)), hint)))
        assertEquals(listOf("Press X to skip"), clean.first.lines.map { it.text })
        val reading = Reading(listOf(first, TextLine("h3p!miz bvyvk b1r be!anin", TextBox(0.32, 0.86, 0.68, 0.91)), hint))
        val (kept, dropped) = own.split(reading)
        assertEquals(listOf("Press X to skip"), kept.lines.map { it.text })
        assertEquals(2, dropped.size)
        assertTrue(own.isOwn("hepimiz büyük bir belanın içindeyiz."))
        assertTrue(OwnSubtitles.coversLine(dropped, TextBox(0.3, 0.81, 0.7, 0.9)))
        assertFalse(OwnSubtitles.coversLine(dropped, TextBox(0.3, 0.4, 0.7, 0.5)))
        own.cleared()
        time += OwnSubtitles.PLACE_GRACE_MS + 1
        assertEquals(2, own.split(reading).first.lines.size)
    }

    @Test
    fun screenTextReadersSkipOwnSubtitle() {
        val echo = SubtitleEcho { 0L }
        val own = OwnSubtitles { 0L }
        echo.own = own
        own.record(turkish, english, 15000)
        val reading = Reading(listOf(TextLine(ocr(turkish)), TextLine("Vice City Beach")))
        assertEquals(listOf("Vice City Beach"), echo.filter(reading, geometry = false).lines.map { it.text })
    }
}
