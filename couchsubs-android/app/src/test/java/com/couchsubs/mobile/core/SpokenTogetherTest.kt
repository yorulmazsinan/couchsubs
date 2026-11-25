// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kalabalık sahnede aynı anda konuşan kişilerin alt alta duran ayrı blokları tek altyazıda, her biri kendi satırında ve
 * adıyla birleşir (X, beta.100). Ortalı, eşit aralıklı üç konuşma satırı menü listesi sayılmaz. Mac/iPhone
 * (SpokenTogetherTests) ve Windows (SpokenTogetherTests) aynı vakalar.
 */
class SpokenTogetherTest {
    private val area = TextBox(0.0, 0.0, 1.0, 1.0)

    private fun line(text: String, top: Double, height: Double = 0.04): TextLine {
        val half = text.length * 0.0065
        return TextLine(text, TextBox(0.5 - half, top, 0.5 + half, top + height))
    }

    private fun left(text: String, top: Double, height: Double = 0.04) =
        TextLine(text, TextBox(0.1, top, 0.1 + text.length * 0.012, top + height))

    @Test fun twoSpeakersAtOnceAreJoinedInOrder() {
        val block = Reading(listOf(line("Vendor: You want the usual today?", 0.74), line("Driver: Move your cart, man.", 0.82)))
            .subtitleBlock(area)
        assertEquals("Vendor: You want the usual today?\nDriver: Move your cart, man.", block.text)
        assertEquals(0.74, block.box!!.top, 1e-9)
        assertEquals(0.86, block.box!!.bottom, 1e-9)
    }

    @Test fun threeEvenlySpacedSpeakersAreJoinedNotAMenuList() {
        val reading = Reading(listOf(
            line("Tourist: Which way to the beach?", 0.66),
            line("Guard: Keep walking.", 0.74),
            line("Kid: Look at that car over there!", 0.82),
        ))
        assertFalse(reading.isHistoryList)
        assertEquals("Tourist: Which way to the beach?\nGuard: Keep walking.\nKid: Look at that car over there!",
            reading.subtitleBlock(area).text)
    }

    @Test fun wrappedSpeechStaysWithItsSpeaker() {
        val reading = Reading(listOf(
            line("Tourist: Excuse me, which way is", 0.62),
            line("the beach from here?", 0.665),
            line("Guard: Keep walking.", 0.74),
        ))
        assertEquals("Tourist: Excuse me, which way is\nthe beach from here?\nGuard: Keep walking.", reading.subtitleBlock(area).text)
    }

    @Test fun leftAlignedHistoryListIsStillAList() {
        val reading = Reading(listOf(
            left("Staff: Hi there.", 0.3),
            left("Customer: One coffee, please.", 0.38),
            left("Staff: Coming right up.", 0.46),
        ))
        assertTrue(reading.isHistoryList)
        assertTrue(reading.subtitleBlock(area).lines.isEmpty())
    }

    @Test fun farApartSpeakerIsNotJoined() {
        val reading = Reading(listOf(line("Vendor: Fresh fruit!", 0.5), line("Driver: Move it.", 0.82)))
        assertEquals("Vendor: Fresh fruit!", reading.subtitleBlock(area).text)
    }

    @Test fun objectiveBetweenSpeakersStopsTheJoin() {
        val reading = Reading(listOf(
            line("Vendor: You want the usual today?", 0.66),
            line("Go to the market.", 0.735, 0.02),
            line("Driver: Move your cart, man.", 0.8),
        ))
        assertEquals("Vendor: You want the usual today?", reading.subtitleBlock(area).text)
    }

    @Test fun differentTextSizeIsNotJoined() {
        val reading = Reading(listOf(line("Vendor: Fresh fruit!", 0.7), line("Driver: Move it.", 0.8, 0.07)))
        assertEquals("Vendor: Fresh fruit!", reading.subtitleBlock(area).text)
    }
}
