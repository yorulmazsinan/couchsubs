// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GitHub #893: gelişmiş (yapay zekâ) çeviri açıkken bazı satırlar TV'ye hiç gitmiyordu. Çeviri satır başına bir iki
 * saniye sürüyor; ilk satırın çevirisi yenisi geldikten 2,5 sn sonra bitince atılıyor ya da yarıda bırakılıyordu.
 * Windows (SlowTranslationOrderTests.cs) ve Mac/iPhone (SlowTranslationOrderTests.swift) aynı senaryoları sınar.
 */
class SlowTranslationOrderTest {
    private val first = "Hold the gate."
    private val second = "Run to the boat!"
    private val area = CropRegion().box

    private class Recorder : SubtitleSender {
        val sent = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text) }
        override fun clear() {}
    }

    /** Kaynağa benzemeyen sahte çeviri (benzer çeviri "zaten hedef dilde" sayılıp gösterilmez). */
    private fun tr(text: String) = "<" + text.reversed() + ">"

    /** Yavaş yapay zekâ çevirisi: ilk satır [release] çağrılana kadar bekler, diğerleri hemen döner. */
    private inner class Slow : TextTranslator {
        private val gate = CountDownLatch(1)
        val requested = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun translate(text: String): String {
            requested.add(text)
            if (text == first) gate.await()
            return tr(text)
        }
        fun release() = gate.countDown()
    }

    private val executor = Executors.newSingleThreadExecutor { Thread(it, "test translate").apply { isDaemon = true } }
    private val sender = Recorder()
    @Volatile private var now = 0L

    @After fun tearDown() { executor.shutdownNow() }

    private fun pipeline(translator: TextTranslator) = SubtitlePipeline(translator, sender, { now }, executor)

    private fun SubtitlePipeline.frame(text: String, at: Long) {
        now = at
        process(Reading.fromText(text), area)
    }

    private fun waitFor(what: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 30_000
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(5)
        assertTrue(what, condition())
    }

    @Test fun slowFirstLineIsStillShownBeforeTheFasterNextOne() {
        val translator = Slow()
        val pipeline = pipeline(translator)
        pipeline.frame(first, 0)
        waitFor("ilk satırın çevirisi başladı") { translator.requested.size == 1 }
        pipeline.frame(second, 1500)
        // İlk satır yenisi geldikten 2,6 sn sonra hâlâ çevriliyor: eskiden yarıda bırakılıyordu.
        pipeline.frame(second, 1500L + SubtitlePipeline.LATE_RESULT_MS + 100)
        now = 4500
        translator.release()
        waitFor("iki satır gösterildi") { sender.sent.size == 2 }
        assertEquals(listOf(first, second), translator.requested)
        assertEquals(listOf(tr(first), tr(second)), sender.sent)
    }

    @Test fun queuedLastLineIsNotDroppedForTimeSpentWaiting() {
        val translator = Slow()
        val pipeline = pipeline(translator)
        pipeline.frame(first, 0)
        waitFor("ilk satırın çevirisi başladı") { translator.requested.size == 1 }
        pipeline.frame(second, 500)
        var time = 600L
        while (time <= 2000L) { pipeline.frame("", time); time += 100 }
        // Son satır kalktıktan 3 sn sonra sırası geldi; çevirisi hemen bitti, yine gösterilir.
        now = 5000
        translator.release()
        waitFor("iki satır gösterildi") { sender.sent.size == 2 }
        assertEquals(listOf(tr(first), tr(second)), sender.sent)
    }

    @Test fun firstLineIsGivenUpOnlyAfterTheQueuedLimit() {
        val translator = Slow()
        val pipeline = pipeline(translator)
        pipeline.frame(first, 0)
        waitFor("ilk satırın çevirisi başladı") { translator.requested.size == 1 }
        pipeline.frame(second, 100)
        pipeline.frame(second, 100L + SubtitlePipeline.QUEUED_LATE_RESULT_MS + 1)
        waitFor("yeni satır gösterildi") { sender.sent.isNotEmpty() }
        assertEquals(listOf(tr(second)), sender.sent)
    }

    @Test fun loneLineArrivingLongAfterItLeftIsStillDropped() {
        val translator = Slow()
        val pipeline = pipeline(translator)
        pipeline.frame(first, 0)
        waitFor("ilk satırın çevirisi başladı") { translator.requested.size == 1 }
        var time = 100L
        while (time <= 1500L) { pipeline.frame("", time); time += 100 }
        now = 1500L + SubtitlePipeline.LATE_RESULT_MS + 600
        translator.release()
        pipeline.frame("", now)
        Thread.sleep(200)
        assertTrue(sender.sent.isEmpty())
    }
}
