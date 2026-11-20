// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.Executors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** GTA 6: görev yazısı konuşma altyazısının altında dakikalarca durur; altyazı onda takılı kalıyordu (Mac: StickyRowsTests.swift). */
class StickyRowsTest {
    private val objective = "Stash the acid in Brian's lockup"

    private fun StickyRows.text(text: String, time: Long) = filter(Reading.fromText(text), time).text

    @Test fun objectiveUnderChangingDialogueIsDropped() {
        val rows = StickyRows()
        assertEquals(objective, rows.text(objective, 0))
        // Görev konuşmadan 3 sn önce geldi: henüz sabit değil ama konuşmaya karışmaz (LINGER_MS).
        assertEquals("Yeah!", rows.text("Yeah!\n$objective", 3000))
        // Görev 6 sn'dir ekranda, konuşma ondan 3 sn sonra geldi: görev sabit sayılır.
        assertEquals("Yeah!", rows.text("Yeah!\n$objective", 6000))
        assertEquals(listOf(objective), rows.newlySticky)
        assertEquals("Okay.", rows.text("Okay.\n$objective", 7000))
        // Konuşma kalktı, görev tek başına kaldı: TV'de eski konuşma kalmasın diye görev de okunmaz.
        assertEquals("", rows.text(objective, 9000))
        assertEquals("Get in the sea plane", rows.text("Get in the sea plane", 9500))
    }

    @Test fun dialogueBoxWhoseRowsAppearTogetherIsKept() {
        val rows = StickyRows()
        val page = "You can stay here as long as you like.\nThe inn is always open for travelers."
        for (time in 0L..20_000L step 500) assertEquals(page, rows.text(page, time))
        // Yazı yazılır gibi beliren ikinci satır da birlikte gelmiş sayılır.
        val typed = StickyRows()
        assertEquals("Where are you going?", typed.text("Where are you going?", 0))
        assertEquals("Where are you going?\nIt is late.", typed.text("Where are you going?\nIt is late.", 1000))
        assertEquals("Where are you going?\nIt is late.", typed.text("Where are you going?\nIt is late.", 12_000))
    }

    @Test fun olderRowAtEdgeIsKeptOutOfNewDialogue() {
        val rows = StickyRows()
        assertEquals(objective, rows.text(objective, 0))
        // Görev üstte de olsa (altyazının üstünde duran görev) yeni konuşmaya karışmaz.
        assertEquals("We have to go.", rows.text("$objective\nWe have to go.", 1500))
        // Konuşan adlı satır eski olsa da çıkarılmaz.
        val named = StickyRows()
        named.text("Lucia: Wait for me.", 0)
        assertEquals("Lucia: Wait for me.\nOkay.", named.text("Lucia: Wait for me.\nOkay.", 2000))
        // Görev tek başına kalınca (henüz sabit değilken) okunur.
        val alone = StickyRows()
        alone.text(objective, 0)
        assertEquals(objective, alone.text(objective, 3000))
    }

    @Test fun rowThatLeftIsForgottenAndShownAgain() {
        val rows = StickyRows()
        rows.text(objective, 0)
        rows.text("Yeah!\n$objective", 3000)
        assertEquals("Yeah!", rows.text("Yeah!\n$objective", 6000))
        // Kısa okuma kaçağı sabitliği bozmaz.
        rows.filter(Reading.Empty, 6500)
        assertEquals("", rows.text(objective, 7000))
        // Görev ekrandan kalktı; yeniden belirince yeni yazıdır.
        rows.filter(Reading.Empty, 9000)
        assertEquals(objective, rows.text(objective, 9500))
    }

    private class Recorder : SubtitleSender {
        val sent = java.util.Collections.synchronizedList(mutableListOf<String>())
        @Volatile var clears = 0
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text) }
        override fun clear() { clears++ }
    }

    private class Recording : TextTranslator {
        val requested = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun translate(text: String): String {
            requested.add(text)
            return "<" + text.reversed() + ">"
        }
    }

    @Test fun dialogueIsNotStuckBehindObjective() {
        val executor = Executors.newSingleThreadExecutor { Thread(it, "test translate").apply { isDaemon = true } }
        try {
            val frames = List(8) { objective } + List(10) { "Yeah!\n$objective" } + List(6) { objective } +
                List(4) { "Okay.\n$objective" }
            var now = 0L
            val sender = Recorder()
            val translator = Recording()
            val pipeline = SubtitlePipeline(translator, sender, { now }, executor).apply { packWait = 0; cleanWait = 0 }
            val area = CropRegion().box
            var clearsWhileObjectiveAlone = 0
            frames.forEachIndexed { i, text ->
                pipeline.process(Reading.fromText(text), area)
                executor.submit {}.get()
                if (i == 23) clearsWhileObjectiveAlone = sender.clears
                now += 500
            }
            // Konuşma kalkıp görev tek başına kalınca eski konuşmanın çevirisi TV'den kalkar; yeni kısa konuşma çevrilir.
            assertTrue(clearsWhileObjectiveAlone > 0)
            assertEquals(listOf(objective, "Yeah!", "Okay."), translator.requested.toList())
        } finally {
            executor.shutdownNow()
        }
    }
}
