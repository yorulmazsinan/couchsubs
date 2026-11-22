// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mac (beta.80, PS5, GTA 6): ekranda diyalog varken altyazı günlüğüne dakikalarca hiçbir satır düşmüyordu; altyazının
 * okunmadığı mı (menü), boş mu okunduğu mu, süzgeçte mi kaldığı mı, okumanın hata mı verdiği mi anlaşılmıyordu. Sessizlik
 * sürerse nedeni dakikada bir günlüğe yazılır. Mac/iPhone QuietReadsTests.swift ve Windows QuietReadsTests.cs ile aynı.
 */
class QuietReadsTest {
    private val direct = object : java.util.concurrent.AbstractExecutorService() {
        override fun execute(command: Runnable) = command.run()
        override fun shutdown() {}
        override fun shutdownNow() = mutableListOf<Runnable>()
        override fun isShutdown() = false
        override fun isTerminated() = false
        override fun awaitTermination(timeout: Long, unit: java.util.concurrent.TimeUnit) = true
    }

    private val silent = object : SubtitleSender {
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {}
        override fun clear() {}
    }

    /** `step`: kare numarasına göre okuma; null dönerse kare okunmaz (menü), hata atarsa okuma hata verir. */
    private fun run(frames: Int, step: (SubtitlePipeline, Int) -> Reading?): List<String> {
        var now = 0L
        val log = mutableListOf<String>()
        val pipeline = SubtitlePipeline(TextTranslator { "Çeviri: $it" }, silent, { now }, direct).apply {
            packWait = 0; cleanWait = 0; onLog = { log.add(it) }
        }
        for (index in 0 until frames) {
            val reading = try {
                step(pipeline, index)
            } catch (error: IllegalStateException) {
                pipeline.noteReadFailure(error)
                null
            }
            if (reading != null) pipeline.process(reading, CropRegion().box, ByteArray(1) { (index % 7 * 36).toByte() })
            now += 1000
        }
        return log
    }

    @Test
    fun emptyReadsAreReportedOncePerMinute() {
        val log = run(130) { _, _ -> Reading(emptyList()) }
        val quiet = log.filter { it.startsWith("altyazı alanında") }
        assertEquals(log.joinToString("\n"), 2, quiet.size)
        assertTrue(quiet[0], quiet[0].contains("60 sn'dir yazı yok"))
        assertFalse(quiet[0], quiet[0].contains(" 0 boş"))
    }

    @Test
    fun readErrorsAreReportedWithTheError() {
        val log = run(61) { _, _ -> throw IllegalStateException("bozuk kare") }
        val quiet = log.firstOrNull { it.startsWith("altyazı alanında") }
        assertNotNull(log.joinToString("\n"), quiet)
        assertTrue(quiet!!, quiet.contains("son hata: bozuk kare"))
    }

    @Test
    fun textKeepsTheReportQuiet() {
        val line = Reading(listOf(TextLine("Get in the car, now.", TextBox(0.2, 0.4, 0.8, 0.6))))
        val log = run(130) { _, _ -> line }
        assertFalse(log.joinToString("\n"), log.any { it.startsWith("altyazı alanında") })
    }

    /** Menü yüzünden okunmayan kareler sessizlik özetinde sayılır (geçişi hizmet yazar). */
    @Test
    fun menuSkipIsLogged() {
        val log = run(70) { pipeline, index ->
            if (index in 5 until 66) {
                pipeline.skipForMenu()
                null
            } else Reading(emptyList())
        }
        val quiet = log.firstOrNull { it.startsWith("altyazı alanında") }
        assertNotNull(log.joinToString("\n"), quiet)
        assertTrue(quiet!!, quiet.contains("kare menü yüzünden okunmadı"))
        assertFalse(quiet, quiet.contains(" 0 kare menü"))
    }
}
