// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Telefon açıkken, oyun dururken balon çevirileri kendi kendine değişmesin (X, 28 Kas, beta.107): aynı mesajın OCR
 * okunuşları ilk çeviriyi kullanır, eksik okuma gösterilen balonların yerine geçmez, ayrı balonlar birleşmez, seçeneğin
 * kendi rengi kalır, balonlar yuvarlak köşeli gönderilir. Windows ve Mac aynı denemeler.
 */
class PhoneChatStabilityTest {
    private val a = "Whatever the next stunt is, maybe add wearing underwear to the plan."
    private val b = "You still have that jumpsuit? I kinda wanna see Jay in it. You'll like it, Jay. Really breathable."

    private fun row(text: String, y: Double, role: ScreenPhoneCard.Role = ScreenPhoneCard.Role.OUTGOING) =
        PhoneRegionSession.Companion.ChatRow(text, TextBox(0.4, y, 0.95, y + 0.08), role, 0.025, ScreenPhoneCard.Handset.SCREEN_SHAPE)

    @Test
    fun worseChatReadKeepsTheShownBubbles() {
        val shown = listOf(row("New message", 0.20, ScreenPhoneCard.Role.NOTE), row("Jason", 0.25, ScreenPhoneCard.Role.INCOMING),
            row(a, 0.55), row(b, 0.66))
        assertTrue(PhoneRegionSession.worseChatRead(shown.take(3), shown))
        assertTrue(PhoneRegionSession.worseChatRead(shown.take(3) + row("You still have that", 0.66), shown))
        assertTrue(PhoneRegionSession.worseChatRead(shown.take(2) + row("$a $b", 0.55), shown))
        assertTrue(PhoneRegionSession.worseChatRead(shown.take(2) + row("$a You still have that", 0.55), shown))
        // Üst satırları okunmayan balon (üstü aşağı kayar, altı yerinde) ve ortası düşüp ikiye bölünen balon.
        val tail = row("I kinda wanna see Jay in it. You'll like it, Jay. Really breathable.", 0.69).let { it.copy(spot = it.spot.copy(bottom = 0.74)) }
        assertTrue(PhoneRegionSession.worseChatRead(shown.take(3) + tail, shown))
        val head = row("You still have that jumpsuit?", 0.66).let { it.copy(spot = it.spot.copy(bottom = 0.68)) }
        assertTrue(PhoneRegionSession.worseChatRead(shown.take(3) + head + tail, shown))
        // Aynı okuma, OCR varyantı, alta eklenen yeni mesaj ve kaydırma eksik okuma değildir.
        assertFalse(PhoneRegionSession.worseChatRead(shown, shown))
        assertFalse(PhoneRegionSession.worseChatRead(shown.take(3) + row(b.replace("You'll", "Youll"), 0.66), shown))
        assertFalse(PhoneRegionSession.worseChatRead(shown + row("See you there.", 0.77), shown))
        assertFalse(PhoneRegionSession.worseChatRead(shown.map { row(it.text, it.spot.top - 0.1, it.role!!) }, shown))
    }

    @Test
    fun phoneMemoryKeepsTheFirstTranslationAcrossReplyOcrVariants() {
        val translation = "Tulum hâlâ sende mi? Jay'i onunla görmek isterim. Beğenirsin Jay, hava alıyor."
        val variants = listOf(b, b.replace("You'll", "Youll"), b.replace("You'll", "You'l"), b.replace("it, Jay", "it,t Jay"),
            b.replace("breathable", "breathabie"))
        val memory = PhoneMemory()
        memory.remember(b, translation)
        for (variant in variants) {
            assertTrue(variant, PhoneSteady.sameReading(b, variant))
            assertEquals(translation, memory.remember(variant, "Motorun sonraki çevirisi."))
            assertEquals(translation, memory.translation(variant))
        }
        assertTrue(PhoneSteady.sameReading("Thx amigo! U find", "Thx amigo! U flnd"))
        assertTrue(PhoneSteady.sameReading("Balsero IS SOMETHING good tonight", "Balsero IS SOMETHINnG good tonight"))
        assertFalse(PhoneSteady.sameReading("It is so cold outside tonight.", "It is so bold outside tonight."))
        assertFalse(PhoneSteady.sameReading("I'm here waiting for you at the station.", "I'm there waiting for you at the station."))
        assertFalse(PhoneSteady.sameReading(b, b.replace("breathable", "breathahle").replace("jumpsuit", "jumpsuil")
            .replace("Really", "Reaxly")))
        assertNull(memory.translation("Meet me at exit 16."))
    }

    @Test
    fun selectedReplyKeepsItsOwnColour() {
        val handset = ScreenPhoneCard.Handset(GamePhoneGeometry.Pose(0.6087, 0.1026, 0.5528, 0.8395), 16.0 / 9)
        fun item(text: String, top: Double, surface: TextSurface) =
            ScreenTranslation.Item(text, "$text (tr)", TextBox(0.5, top, 0.62, top + 0.03), 0.016, surface = surface,
                phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.OPTION, TextBox(0.2, top, 0.8, top + 0.03)))
        val blue = TextSurface("#3058D0", "#FFFFFF")
        val selected = TextSurface("#F5B83D", "#17181B")
        for (styles in listOf(listOf(selected, blue), listOf(blue, selected))) {
            val panel = ScreenPhoneCard.layout(listOf(item("First reply.", 0.65, styles[0]), item("Second reply.", 0.72, styles[1])), handset)
            assertEquals(styles, panel.filter { it.panel == ScreenPhoneCard.PanelPart.MINE }.map { it.surface })
        }
    }
}
