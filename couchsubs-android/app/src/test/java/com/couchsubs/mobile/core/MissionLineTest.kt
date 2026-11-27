// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Görev satırı altyazıdan ayrı (spec bölüm 5; Windows ve Mac'teki MissionLine testleriyle aynı durumlar): alt ortada
 * görev satırı ile iki satırlı altyazı üst üste; altyazı beş kez değişir, görev sabit kalır.
 */
class MissionLineTest {
    private val area = TextBox(0.14, 0.62, 0.86, 0.97)

    private fun line(text: String, top: Double, height: Double = 0.10) = TextLine(text, TextBox(0.2, top, 0.8, top + height))

    @Test
    fun missionNeverEntersTheSubtitleAndIsSentOnce() {
        val sticky = StickyRows()
        val mission = MissionLine()
        val subtitles = listOf(
            "Lucia: We need the car." to "Before the cops show up.",
            "Jason: I know a guy." to "He owes me a favour.",
            "Lucia: Then call him." to "We are running out of time.",
            "Jason: Fine, fine." to "Give me a minute.",
            "Lucia: Hurry up." to "They are coming.",
        )
        val shown = mutableListOf<String>()
        var changes = 0
        var time = 0L
        for ((first, second) in subtitles) {
            repeat(10) {
                // Görev satırı altyazının hemen altında, biraz daha küçük yazıyla (alanın oranlarıyla).
                val reading = Reading(listOf(line(first, 0.05), line(second, 0.17), line("Go to the docks.", 0.30, 0.075)))
                val filtered = sticky.filter(reading, time)
                if (mission.observe(sticky.removed, area, time)) changes++
                val block = filtered.subtitleBlock(area)
                if (block.text.isNotEmpty() && shown.lastOrNull() != block.text) shown.add(block.text)
                time += 250
            }
        }
        // Görev hiç altyazı metnine girmiyor; altyazı her değişimde doğru.
        assertTrue(shown.toString(), shown.none { it.contains("docks") })
        assertEquals(subtitles.map { "${it.first} ${it.second}" }, shown.map { it.replace("\n", " ") })
        // Görev kutusu bir kez kuruluyor (altyazı değiştikçe bölge değişmiyor, yeniden gönderilmiyor).
        assertEquals(1, changes)
        assertNotNull(mission.region)
        assertTrue(mission.region!!.top > area.top + 0.2 * (area.bottom - area.top))
    }

    @Test
    fun missionGoesAwayWhenItLeavesTheScreen() {
        val mission = MissionLine()
        val removed = listOf(line("Go to the docks.", 0.30))
        assertFalse(mission.observe(removed, area, 0))
        assertTrue(mission.observe(removed, area, MissionLine.SETTLE_MS))
        assertNotNull(mission.region)
        assertTrue(mission.observe(emptyList(), area, MissionLine.SETTLE_MS + MissionLine.HOLD_MS + 1))
        assertNull(mission.region)
        // Konuşan adlı satır görev sayılmaz.
        assertFalse(mission.observe(listOf(line("Lucia: Go to the docks.", 0.30)), area, 0))
        assertFalse(mission.observe(listOf(line("Lucia: Go to the docks.", 0.30)), area, 10_000))
    }

    /**
     * X, beta.100–104 (GTA 6): altyazı kutusu alttaki görev satırını örtüyordu. Görev satırının yeri görev sayılmasını
     * beklemeden bilinir (TV altyazıyı onun üstüne taşır); küçük oynama değiştirmez, gerçek kayma değiştirir, görev kalkınca
     * null (Mac/iPhone ve Windows aynı).
     */
    @Test
    fun clearanceIgnoresSmallJitterAndFollowsRealMoves() {
        val mission = MissionLine()
        val whole = TextBox(0.0, 0.0, 1.0, 1.0)
        fun see(top: Double, time: Long) =
            mission.observe(listOf(TextLine("Get in the speedboat", TextBox(0.45, top, 0.62, top + 0.03))), whole, time)
        see(0.94, 0)
        val first = mission.clearance
        assertNotNull(first)
        see(0.945, 500)
        assertEquals(first, mission.clearance)
        see(0.80, 1000)
        assertEquals(0.80, mission.clearance!!.top, 1e-4)
        mission.observe(emptyList(), whole, 3000)
        assertNull(mission.clearance)
    }

    @Test
    fun simultaneousMissionAndSubtitleAreSplitByGapOrSize() {
        // Aynı anda belirdiler: aradaki boşluk satır yüksekliğinin 0,6'sından büyük → ayrı blok; konuşan adlı blok altyazı.
        val apart = Reading(listOf(line("Lucia: We need the car.", 0.05), line("Go to the docks.", 0.24)))
        assertEquals("Lucia: We need the car.", apart.subtitleBlock(area).text)
        // Bitişik ama yazı boyu 1,25 kattan çok farklı → ayrı blok.
        val smaller = Reading(listOf(line("Lucia: We need the car.", 0.05), line("Go to the docks.", 0.16, 0.06)))
        assertEquals("Lucia: We need the car.", smaller.subtitleBlock(area).text)
        // Aynı boy ve bitişik iki satır tek altyazı.
        val one = Reading(listOf(line("We need the car before", 0.05), line("the cops show up.", 0.16)))
        assertEquals(2, one.subtitleBlock(area).lines.size)
    }
}
