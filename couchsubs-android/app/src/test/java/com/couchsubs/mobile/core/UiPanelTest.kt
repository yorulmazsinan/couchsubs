// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Hazır ek alanda arayüz kutusu kanıtı (Windows UiPanelTests.cs, Mac UiPanelTests.swift ile aynı kareler). */
class UiPanelTest {
    private fun texture(x: Int, y: Int) = 60 + ((x * 7 + y * 13) % 23) * 6 + ((x / 11 + y / 7) % 2) * 40

    private fun region(ground: ((Int, Int) -> Int)?, text: Int, withText: Boolean = true, width: Int = 400, height: Int = 200) =
        GrayFrame(ByteArray(width * height) { index ->
            val x = index % width
            val y = index / width
            var value = ground?.invoke(x, y) ?: texture(x, y)
            if (withText && x in 20 until 260 && (y in 30 until 52 || y in 70 until 92) && x % 9 < 3) value = text
            value.toByte()
        }, width, height)

    @Test fun darkPanelWithWhiteTextIsInterface() = assertTrue(UiPanel.hasText(region({ _, _ -> 28 }, 235)))
    @Test fun lightPanelWithDarkTextIsInterface() = assertTrue(UiPanel.hasText(region({ _, _ -> 225 }, 30)))
    @Test fun semiTransparentPanelOverTheWorldIsInterface() =
        assertTrue(UiPanel.hasText(region({ x, y -> 30 + (texture(x, y) - 60) / 30 }, 230)))
    @Test fun textOnTheGameWorldIsNotInterface() = assertFalse(UiPanel.hasText(region(null, 245)))
    @Test fun flatAreaWithoutTextIsNotInterface() = assertFalse(UiPanel.hasText(region({ _, _ -> 40 }, 40, withText = false)))
    @Test fun panelOnlyInOneCornerOfTheAreaStillCounts() =
        assertTrue(UiPanel.hasText(region({ x, y -> if (x < 280 && y < 110) 26 else texture(x, y) }, 235)))

    private class Recorder : RegionSender {
        val sent = mutableListOf<Pair<String, String>>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) { sent.add(id to text) }
        override fun clearRegions() {}
    }

    private val help = ExtraArea(GameAreaPresets.HELP_ID, "Help", CropRegion(top = 0.0, bottom = 1.0, left = 0.0, right = 1.0))
    private fun signature(value: Int) = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { value.toByte() }
    private fun crop(panel: Boolean, signature: Int) =
        RegionWatcher.Crop(Unit, signature(signature), region(if (panel) { _, _ -> 28 } else null, 240, width = 320, height = 180))

    @Test
    fun presetAreaWithoutAnInterfacePanelIsNeverRead() {
        // Oyun yanlış seçiliyse (PS5 ana ekranı, başka oyun) ya da bölgede yalnız dünya yazısı varsa hazır alan çevrilmez.
        var reads = 0
        val recorder = Recorder()
        val watcher = RegionWatcher({ reads++; Reading(listOf(TextLine("LIQUOR STORE OPEN 24 HOURS", TextBox(0.1, 0.2, 0.9, 0.3)))) },
            { "TR: $it" }, recorder)
        repeat(3) { watcher.pass(setOf(help.id), listOf(help to crop(panel = false, signature = 1 + it * 100))) }
        assertEquals(0, reads)
        assertTrue(recorder.sent.isEmpty())
    }

    @Test
    fun presetAreaOnAPanelIsTranslatedAndRemovedWhenThePanelGoes() {
        val recorder = Recorder()
        val watcher = RegionWatcher({ Reading(listOf(TextLine("Follow Vicki to the car.", TextBox(0.1, 0.2, 0.9, 0.3)))) },
            { "TR: $it" }, recorder)
        repeat(2) { watcher.pass(setOf(help.id), listOf(help to crop(panel = true, signature = 1))) }
        assertTrue(recorder.sent.toString(), recorder.sent.contains(GameAreaPresets.HELP_ID to "TR: Follow Vicki to the car."))
        watcher.pass(setOf(help.id), listOf(help to crop(panel = false, signature = 200)))
        assertEquals(GameAreaPresets.HELP_ID to "", recorder.sent.last())
    }

    @Test
    fun gameAreaPresetsAreRecognized() {
        assertTrue(GameAreaPresets.areas("GTA 6").all { GameAreaPresets.isPreset(it.id) })
        assertFalse(GameAreaPresets.isPreset("auto-1"))
    }
}
