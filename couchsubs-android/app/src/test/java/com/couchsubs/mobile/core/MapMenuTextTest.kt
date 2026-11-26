// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Harita ekranının görev listesi ve kartı (#1365): arayüz etiketleri ("GOAL" → "Hedef"), görev başlığında özel ad
 * ("Kingpin Bowling'i Soy"), satır başındaki görev simgesi ("KM") ve güveni düşük okuma. Ortak deneme dosyası
 * fixtures/map-menu-text.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac MapMenuTextTests.swift ve Windows
 * MapMenuTextTests.cs aynı dosyayı okur).
 */
class MapMenuTextTest {
    private val root = JSONObject(Fixtures.text("map-menu-text.json"))

    private fun objects(name: String) = root.getJSONArray(name).let { array -> (0 until array.length()).map { array.getJSONObject(it) } }

    @Test
    fun labelsAndMissionTitles() {
        for (item in objects("labels")) {
            assertEquals(item.getString("text"), item.getString("expected"), UiCommands.translateLabel(item.getString("text")))
        }
        for (item in objects("missionTitles")) {
            val expected = if (item.isNull("expected")) null else item.getString("expected")
            assertEquals(item.getString("text"), expected, UiCommands.missionTitle(item.getString("text")))
        }
    }

    @Test
    fun badgesAreNotText() {
        for (item in objects("badges")) {
            val text = item.getString("text")
            val b = item.getJSONArray("box")
            val box = TextBox(b.getDouble(0), b.getDouble(1), b.getDouble(2), b.getDouble(3))
            val line = ScreenTranslation.withoutBadge(TextLine(text, box, confidence = 1f))
            assertEquals(text, item.getString("expected"), line.text)
            assertEquals(text, item.getDouble("left"), line.box?.left ?: -1.0, 1e-3)
            assertEquals(text, b.getDouble(2), line.box?.right ?: -1.0, 1e-9)
        }
    }

    @Test
    fun unsureReadsAreHeld() {
        for (item in objects("unsure")) {
            val confidence = if (item.isNull("confidence")) null else item.getDouble("confidence").toFloat()
            assertEquals(item.getString("text"), item.getBoolean("expected"),
                ScreenTextNoise.isUnsure(TextLine(item.getString("text"), confidence = confidence)))
        }
    }

    /** Menüdeki alanda güvensiz satır adaydan çıkar (çeviriye gitmez), simge satırın başından atılır; menü dışında dokunulmaz. */
    @Test
    fun menuCandidateDropsUnsureRowsAndBadges() {
        val region = CropRegion(top = 0.0, bottom = 0.6, left = 0.0, right = 0.4)
        val reading = Reading(listOf(
            TextLine("KM Collect Chemicals for Kyle", TextBox(0.1, 0.30, 0.8, 0.36), confidence = 1f),
            TextLine("scarch rol the onuin Ape", TextBox(0.1, 0.40, 0.8, 0.46), confidence = 0.5f),
            TextLine("Check out the Mud Club", TextBox(0.1, 0.50, 0.8, 0.56), confidence = 1f),
        ))
        val menu = RegionWatcher.candidate(reading, region, auto = true, menu = true)
        assertEquals(listOf("scarch rol the onuin Ape"), menu.unsure)
        val joined = menu.paragraphs.joinToString(" ")
        assertFalse(joined, joined.contains("scarch"))
        assertFalse(joined, joined.contains("KM"))
        assertTrue(joined, joined.contains("Collect Chemicals for Kyle"))
        val outside = RegionWatcher.candidate(reading, region, auto = true, menu = false)
        assertTrue(outside.unsure.isEmpty())
    }
}
