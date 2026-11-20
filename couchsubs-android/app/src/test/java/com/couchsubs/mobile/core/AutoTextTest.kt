// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** Gerçek GTA 6 karelerinden çıkan satır temizliği ve renkli stil örneklemesi (Windows ve Mac ile aynı kurallar). */
class AutoTextTest {
    private fun clean(menu: Boolean, vararg lines: Pair<String, Float>) =
        AutoText.clean(Reading(lines.mapIndexed { i, (text, confidence) ->
            TextLine(text, TextBox(0.1, 0.1 * i, 0.6, 0.1 * i + 0.05), confidence = confidence)
        }), menu).lines.map { it.text }

    @Test
    fun menuIconsAndOcrGlyphsAreNotTranslated() {
        assertEquals(listOf("Map", "Game", "Store", "Help", "Photo Studio", "Settings"),
            clean(true, "1 Мар" to 0.3f, "Game" to 1f, "• Store" to 1f, "? Help" to 1f, "• Photo Studio" to 1f, "pi Settings" to 1f))
        assertEquals(listOf("RADIO CONTROLS", "OBJECTIVE / MINIMAP", "RUN L3", "ADD MARKER", "CROUCH"),
            clean(true, "RADIO CONTROLS •" to 1f, "OBJECTIVE / MINIMAP DX" to 1f, "RUN L3" to 1f, "ADD MARKER O" to 1f, "O CROUCH" to 1f))
        // Güveni düşük ve sözlükte olmayan okuma atılır; Türkçe yayın arayüzü ("Canli") ve sayılar menüde de çevrilmez.
        assertEquals(listOf("Aiming"), clean(true, "Aiming" to 1f, "INTERACZZ" to 0.4f, "• Canli" to 1f, "40" to 1f))
    }

    @Test
    fun outsideMenusPlaceNamesAndLogosAreDropped() {
        assertEquals(listOf("ROB VICKI'S BOSS", "Vicki wants to rob her boss and split the"),
            clean(false, "KELI" to 1f, "ROB VICKI'S BOSS" to 1f, "Vicki wants to rob her boss and split the" to 1f))
        assertEquals(emptyList<String>(), clean(false, "GAMING" to 1f, "REPUBLIC OF" to 1f, "GAMERS" to 1f, "GEN.TR" to 1f))
    }

    @Test
    fun styleColorsComeFromTheColorPlane() {
        val width = 100
        val height = 20
        val luma = ByteArray(width * height) { i -> (if ((i / width) % 10 < 2) 200 else 40).toByte() }
        // Yazı pembe (#FF66AA'ya yakın), zemin lacivert.
        val color = { x: Int, y: Int -> if (luma[y * width + x].toInt() and 0xff > 100) 0xFF66AA else 0x1E2533 }
        val style = TextStyleSampler.sample(GrayFrame(luma, width, height), 0, 0, width, height, 10.0, "Go to the Saloon.", color = color)!!
        assertEquals("#FF66AA", style.surface.foreground)
        assertEquals("#1E2533", style.surface.background)
    }
}
