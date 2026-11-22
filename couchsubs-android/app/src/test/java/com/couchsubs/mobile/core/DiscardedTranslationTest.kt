// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Yalnız zaten gösterilemeyecek üretim bırakılır; okunabilir satırların sırası korunur (Windows: DiscardedTranslationTests.cs,
 * Mac/iPhone: SubtitlePipelineTests.swift ile aynı senaryolar).
 */
class DiscardedTranslationTest {
    private val old = "Hold the gate."
    private val next = "Run!"
    private val area = CropRegion().box

    private class Recorder : SubtitleSender {
        val sent = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text) }
        override fun clear() {}
    }

    /** Kaynağa benzemeyen sahte çeviri (benzer çeviri "zaten hedef dilde" sayılıp gösterilmez). */
    private fun tr(text: String) = "<" + text.reversed() + ">"

    /** Çeviriler [open] çağrılana kadar bekler. [honorsInterrupt] kapalıysa kesmeyi yok sayar (iptali dinlemeyen motor). */
    private inner class Gated(private val honorsInterrupt: Boolean) : TextTranslator {
        private val gate = CountDownLatch(1)
        val requested = java.util.Collections.synchronizedList(mutableListOf<String>())
        val cancelled = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun translate(text: String): String {
            requested.add(text)
            while (true) {
                try {
                    gate.await()
                    return tr(text)
                } catch (e: InterruptedException) {
                    cancelled.add(text)
                    if (honorsInterrupt) throw e
                }
            }
        }
        fun open() = gate.countDown()
    }

    private val executor = Executors.newSingleThreadExecutor { Thread(it, "test translate").apply { isDaemon = true } }
    private val sender = Recorder()
    private var now = 0L

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

    @Test fun expiredTranslationReleasesWaitingLineWithoutWaitingForItsResult() {
        val translator = Gated(honorsInterrupt = true)
        val pipeline = pipeline(translator)
        pipeline.frame(old, 0)
        waitFor("eski üretim başladı") { translator.requested.size == 1 }
        pipeline.frame(next, 100)
        pipeline.frame(next, 100 + SubtitlePipeline.QUEUED_LATE_RESULT_MS + 1L)
        waitFor("yeni replik bekliyor") { translator.requested.size == 2 }
        assertEquals(listOf(old), translator.cancelled)
        translator.open()
        waitFor("yeni satır gösterildi") { sender.sent.isNotEmpty() }
        assertEquals(listOf(tr(next)), sender.sent)
    }

    @Test fun gracePeriodPreservesBothLines() {
        for (elapsed in listOf(2000L, SubtitlePipeline.LATE_RESULT_MS.toLong())) {
            sender.sent.clear()
            val translator = Gated(honorsInterrupt = true)
            val pipeline = pipeline(translator)
            pipeline.frame(old, 0)
            waitFor("eski üretim başladı") { translator.requested.size == 1 }
            pipeline.frame(next, 100)
            pipeline.frame(next, 100 + elapsed)
            assertTrue("$elapsed ms", translator.cancelled.isEmpty())
            translator.open()
            waitFor("iki satır da gösterildi") { sender.sent.size == 2 }
            assertEquals(listOf(tr(old), tr(next)), sender.sent)
        }
    }

    @Test fun stillVisibleLineIsNotCancelledHoweverLongItsProductionTakes() {
        val translator = Gated(honorsInterrupt = true)
        val pipeline = pipeline(translator)
        pipeline.frame(old, 0)
        waitFor("eski üretim başladı") { translator.requested.size == 1 }
        pipeline.frame(old, 10000)
        assertTrue(translator.cancelled.isEmpty())
        translator.open()
    }

    @Test fun noNewWaitingLineDoesNotCancelExpiredWork() {
        val translator = Gated(honorsInterrupt = true)
        val pipeline = pipeline(translator)
        pipeline.frame(old, 0)
        waitFor("eski üretim başladı") { translator.requested.size == 1 }
        var time = 100L
        while (time <= 2000L) { pipeline.frame("", time); time += 100 }
        pipeline.frame("", 10000)
        assertTrue(translator.cancelled.isEmpty())
        translator.open()
    }

    @Test fun ignoredCancellationDoesNotStartConcurrentWorkOrPublishOldResult() {
        val translator = Gated(honorsInterrupt = false)
        val pipeline = pipeline(translator)
        pipeline.frame(old, 0)
        waitFor("eski üretim başladı") { translator.requested.size == 1 }
        pipeline.frame(next, 100)
        pipeline.frame(next, 100 + SubtitlePipeline.QUEUED_LATE_RESULT_MS + 1L)
        waitFor("kesme gönderildi") { translator.cancelled.size == 1 }
        assertEquals(listOf(old), translator.requested)
        translator.open()
        waitFor("yeni satır gösterildi") { sender.sent.isNotEmpty() }
        assertEquals(listOf(old, next), translator.requested)
        assertEquals(listOf(tr(next)), sender.sent)
    }

    @Test fun newerDisplayedPackLineCancelsUndisplayableProduction() {
        val translator = Gated(honorsInterrupt = true)
        val pipeline = pipeline(translator)
        pipeline.packLookup = { text -> if (text == next) PackMatch("Koş!") else null }
        pipeline.frame(old, 0)
        waitFor("eski üretim başladı") { translator.requested.size == 1 }
        pipeline.frame(next, 100)
        waitFor("eski üretim bırakıldı") { translator.cancelled == listOf(old) }
        translator.open()
        waitFor("paket satırı gösterildi") { sender.sent.isNotEmpty() }
        assertEquals(listOf("Koş!"), sender.sent)
    }

    @Test fun packResultThatWasNotDisplayedDoesNotCancelOldLine() {
        val translator = Gated(honorsInterrupt = true)
        val pipeline = pipeline(translator)
        pipeline.packLookup = { text -> if (text == next) PackMatch(next) else null }
        pipeline.frame(old, 0)
        waitFor("eski üretim başladı") { translator.requested.size == 1 }
        pipeline.frame(next, 100)
        assertTrue(sender.sent.isEmpty())
        assertTrue(translator.cancelled.isEmpty())
        translator.open()
        waitFor("eski satır gösterildi") { sender.sent.isNotEmpty() }
        assertEquals(listOf(tr(old)), sender.sent)
    }

    @Test fun abandonedSourceCanReturnAndBeTranslatedAgain() {
        for (honors in listOf(true, false)) {
            sender.sent.clear()
            val translator = Gated(honors)
            val pipeline = pipeline(translator)
            pipeline.frame(old, 0)
            waitFor("eski üretim başladı") { translator.requested.size == 1 }
            pipeline.frame(next, 100)
            pipeline.frame(next, 100 + SubtitlePipeline.QUEUED_LATE_RESULT_MS + 1L)
            waitFor("kesme gönderildi") { translator.cancelled.size == 1 }
            pipeline.frame(old, 200 + SubtitlePipeline.QUEUED_LATE_RESULT_MS + 1L)
            translator.open()
            waitFor("iki satır gösterildi") { sender.sent.size == 2 }
            assertEquals("honors=$honors", listOf(old, next, old), translator.requested)
            assertEquals("honors=$honors", listOf(tr(next), tr(old)), sender.sent)
        }
    }

    @Test fun packCancellationDoesNotTrapRestoredSource() {
        for (honors in listOf(true, false)) {
            sender.sent.clear()
            val translator = Gated(honors)
            val pipeline = pipeline(translator)
            pipeline.packLookup = { text -> if (text == next) PackMatch("Koş!") else null }
            pipeline.frame(old, 0)
            waitFor("eski üretim başladı") { translator.requested.size == 1 }
            pipeline.frame(next, 100)
            pipeline.frame(old, 200) // Kararlayıcının geri yükleme yolu (1500 ms içinde).
            translator.open()
            waitFor("iki satır gösterildi") { sender.sent.size == 2 }
            assertEquals("honors=$honors", listOf(old, old), translator.requested)
            assertEquals("honors=$honors", listOf("Koş!", tr(old)), sender.sent)
        }
    }
}
