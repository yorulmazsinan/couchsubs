// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.Executors
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Yarım ya da bozuk okuma hemen çevrilmez; aynı satırın daha iyi okuması kısa süre beklenir (Windows:
 * SubtitlePipeline.TranslateOrHold, Mac/iPhone: ReadingHoldTests.swift ile aynı senaryolar).
 */
class ReadingHoldTest {
    private val area = CropRegion().box

    private class Recorder : SubtitleSender {
        val sent = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text) }
        override fun clear() {}
    }

    private class Recording : TextTranslator {
        val requested = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun translate(text: String): String {
            requested.add(text)
            return "<" + text.reversed() + ">"
        }
    }

    private val executor = Executors.newSingleThreadExecutor { Thread(it, "test translate").apply { isDaemon = true } }
    private val sender = Recorder()
    private val translator = Recording()
    private var now = 0L
    private val pipeline = SubtitlePipeline(translator, sender, { now }, executor).apply { holdReadings = true }

    @After fun tearDown() { executor.shutdownNow() }

    private fun frame(text: String, at: Long) {
        now = at
        pipeline.process(Reading.fromText(text), area)
    }

    private fun settle() {
        executor.submit {}.get()
    }

    @Test fun halfReadLineWaitsForTheWholeLine() {
        frame("Get Franklin close to the", 0)
        frame("Get Franklin close to the", 100)
        frame("Get Franklin close to the house.", 200)
        frame("Get Franklin close to the house.", 300)
        frame("Get Franklin close to the house.", 600)
        settle()
        assertEquals(listOf("Get Franklin close to the house."), translator.requested)
    }

    @Test fun unfinishedLineIsTranslatedAfterShortWait() {
        frame("Get Franklin close to the", 0)
        frame("Get Franklin close to the", 100)
        frame("Get Franklin close to the", 200)
        settle()
        assertTrue(translator.requested.isEmpty())
        frame("Get Franklin close to the", 450)
        settle()
        assertEquals(listOf("Get Franklin close to the"), translator.requested)
    }

    @Test fun completeLineIsNotHeld() {
        frame("Hold the gate.", 0)
        settle()
        assertEquals(listOf("Hold the gate."), translator.requested)
    }

    @Test fun withoutHoldingUnfinishedLineGoesAtOnce() {
        pipeline.holdReadings = false
        frame("Get Franklin close to the", 0)
        frame("Get Franklin close to the", 100)
        settle()
        assertEquals(listOf("Get Franklin close to the"), translator.requested)
    }

    @Test fun rereadHelpers() {
        assertTrue(Rereads.isRereadOf("Get Franklin close to the", "Get Franklin close to the house."))
        assertFalse(Rereads.isRereadOf("You kill me!", "I swear to God, you kill me!"))
        assertTrue(Rereads.looksComplete("Hold the gate."))
        assertFalse(Rereads.looksComplete("hold the gate"))
    }
}
