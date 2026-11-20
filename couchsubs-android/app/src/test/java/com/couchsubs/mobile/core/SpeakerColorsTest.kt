// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Konuşana göre renk: Mac/iPhone, Windows ve TV uygulamasıyla aynı palet ve aynı renkler. */
class SpeakerColorsTest {
    @Test
    fun colorsMatchOtherPlatforms() {
        assertEquals("#90CAF9", SpeakerColors.color("Mattia"))
        assertEquals("#90CAF9", SpeakerColors.color("MATTIA"))
        assertEquals("#90CAF9", SpeakerColors.color("  Mattia "))
        assertEquals("#F06292", SpeakerColors.color("Lucia"))
        assertEquals("#4DD0E1", SpeakerColors.color("Jason"))
        assertEquals("#4FC3F7", SpeakerColors.color("Cal"))
    }

    @Test
    fun speakersComeFromEachLineOnce() {
        val speakers = SpeakerColors.speakers("Lucia: Gidelim.\nJason: Tamam.\nLucia: Hemen.")
        assertEquals(listOf(SpeakerColors.Speaker("Lucia", "#F06292"), SpeakerColors.Speaker("Jason", "#4DD0E1")), speakers)
        assertTrue(SpeakerColors.speakers("Hedef: Arabaya bin.").isEmpty())
        assertTrue(SpeakerColors.speakers("Saat 10:30 oldu.").isEmpty())
    }

    @Test
    fun wrappedLinesKeepTheSpeakerColor() {
        val source = "Mattia: Bu çok uzun bir cümle ve bölünüyor. Lucia: Evet."
        val display = "Mattia: Bu çok uzun bir\ncümle ve bölünüyor."
        assertEquals(listOf(SpeakerColors.Segment(0, display.length, "#90CAF9")), SpeakerColors.segments(display, source))
        val two = "Lucia: Gidelim.\nJason: Tamam."
        assertEquals(
            listOf(SpeakerColors.Segment(0, 16, "#F06292"), SpeakerColors.Segment(16, two.length, "#4DD0E1")),
            SpeakerColors.segments(two),
        )
        assertTrue(SpeakerColors.segments("Sadece cümle.").isEmpty())
    }

    @Test
    fun subtitleFrameCarriesSpeakersOnlyWhenOn() {
        val on = SubtitleServer.subtitleFrame("Mattia: Merhaba", 4000, null, at = 1, speakerColors = true)
        assertEquals(
            "event: subtitle\ndata: {\"at\":1,\"duration\":4000,\"speakers\":[{\"color\":\"#90CAF9\",\"name\":\"Mattia\"}]," +
                "\"text\":\"Mattia: Merhaba\"}\n\n",
            on,
        )
        assertFalse(SubtitleServer.subtitleFrame("Mattia: Merhaba", 4000, null, at = 1).contains("speakers"))
        assertFalse(SubtitleServer.subtitleFrame("Merhaba", 4000, null, at = 1, speakerColors = true).contains("speakers"))
    }
}
