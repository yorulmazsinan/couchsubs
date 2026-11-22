// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GitHub #933 (GTA 6): karakter TV izlerken haber bandı konuşmanın altında hiç değişmeden duruyor; uzun süredir değişmeyen
 * ortalı blok, yanında yeni beliren ortalı blok varken seçilmez. Tek sabit blok seçilmeye devam eder (Mac:
 * SubtitleBlockTests.testStaleCenteredBlockLosesToNewOne, Windows: SubtitleBlockTests.StaleCenteredBlockLosesToNewOne).
 */
class StaleBlockTest {
    private val area = TextBox(0.0, 0.6, 1.0, 1.0)

    private fun line(text: String, left: Double, top: Double, right: Double, height: Double = 0.07) =
        TextLine(text, TextBox(left, top, right, top + height))

    @Test fun staleCenteredBlockLosesToNewOne() {
        val speech = line("We are live from the scene where it all happened.", 0.25, 0.3, 0.75)
        val ticker = line("STORM HITS VICE CITY COAST - LIVE COVERAGE", 0.3, 0.8, 0.7)
        val ages = mapOf(speech.text to 1200L, ticker.text to 9000L)
        val skipped = mutableListOf<String>()
        val both = Reading(listOf(speech, ticker))
        assertEquals(ticker.text, both.subtitleBlock(area).text)
        assertEquals(speech.text, both.subtitleBlock(area, age = { ages[it] }, stale = { skipped.add(it.text) }).text)
        assertEquals(listOf(ticker.text), skipped)
        // Tek sabit blok (değişmeyen uzun cümle) altyazıdır.
        skipped.clear()
        assertEquals(ticker.text, Reading(listOf(ticker)).subtitleBlock(area, age = { ages[it] }, stale = { skipped.add(it.text) }).text)
        assertTrue(skipped.isEmpty())
        // İkisi de aynı anda belirip sabit kaldıysa (hangisinin yeni olduğu bilinmiyor) eski kural geçerli.
        assertEquals(ticker.text, both.subtitleBlock(area, age = { 9000L }).text)
        // Bant konuşan adı gibi başlıyor ("EXCLUSIVE: …"): sabitse yine atlanır, yeni konuşma seçilir.
        val headline = line("EXCLUSIVE: LEONIDA'S TOP SPOTS FOR A DECENT CATCH", 0.25, 0.8, 0.75)
        val news = Reading(listOf(speech, headline))
        assertEquals(headline.text, news.subtitleBlock(area).text)
        assertEquals(speech.text, news.subtitleBlock(area, age = { if (it == headline.text) 9000L else 1000L }).text)
        // Konuşan adlı blok yeniyse ya da yanındaki yeni yazı kısa (görev/HUD) ise seçilmeye devam eder.
        val named = line("ANCHOR: Stay with us for more.", 0.3, 0.3, 0.7)
        assertEquals(named.text, Reading(listOf(named, ticker)).subtitleBlock(area, age = { if (it == named.text) 1000L else 9000L }).text)
        val short = line("Follow John", 0.4, 0.8, 0.6)
        assertEquals(named.text, Reading(listOf(named, short)).subtitleBlock(area, age = { if (it == named.text) 9000L else 1000L }).text)
    }

    @Test fun stickyRowsReportsHowLongALineIsUnchanged() {
        val rows = StickyRows()
        rows.filter(Reading.fromText("STORM HITS VICE CITY COAST"), 0)
        rows.filter(Reading.fromText("STORM HITS VICE CITY COAST"), 1000)
        assertEquals(1000L, rows.unchangedMs("STORM HITS VICE CITY COAST", 1000))
        assertNull(rows.unchangedMs("Something else entirely here", 1000))
    }
}
