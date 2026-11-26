// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1391: haritanın konum kartı (dükkân, garaj açıklaması) tek paragraf olarak çevrilir, başlığı (yer adı) çevrilmez,
 * mesaj alanına taşan kart iki alana bölünmez, mesaj alanının kenarındaki kesik parça tek başına çevrilmez. Ortak deneme
 * dosyası fixtures/map-place-card.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac MapPlaceCardTests.swift ve
 * Windows MapPlaceCardTests.cs aynı dosyayı okur).
 */
class MapPlaceCardTest {
    private val root = JSONObject(Fixtures.text("map-place-card.json"))

    private fun strings(array: JSONArray) = (0 until array.length()).map { array.getString(it) }

    private fun objects(array: JSONArray) = (0 until array.length()).map { array.getJSONObject(it) }

    private fun line(item: JSONObject): TextLine {
        val b = item.getJSONArray("box")
        return TextLine(item.getString("text"), TextBox(b.getDouble(0), b.getDouble(1), b.getDouble(2), b.getDouble(3)))
    }

    @Test
    fun cardGroups() {
        for (vector in objects(root.getJSONArray("cards"))) {
            val name = vector.getString("name")
            val lines = objects(vector.getJSONArray("lines")).map(::line)
            val place = vector.getBoolean("place")
            val subtitles = strings(vector.getJSONArray("subtitles"))
            val body = strings(vector.getJSONArray("body"))
            val details = strings(vector.getJSONArray("details"))
            val cards = MissionCard.find(lines)
            assertEquals(name, 1, cards.size)
            val card = cards[0]
            assertEquals(name, place, card.place)
            val groups = MissionCard.groups(card, lines)
            val head = if (place) 0 else 1
            if (!place) assertEquals(name, listOf(lines[card.title[0]].text), groups.first().paragraphs)
            assertEquals(name, subtitles, groups.drop(head).take(subtitles.size).flatMap { it.paragraphs })
            assertEquals(name, body, groups[head + subtitles.size].paragraphs)
            assertEquals(name, head + 1 + subtitles.size + details.size, groups.size)
            // Açıklamanın bloğu sarılmış satırların hepsini kapsar (örtü İngilizcenin tamamına).
            assertEquals(name, card.body.map { lines[it].box!! }.reduce { a, b -> a.union(b) }, groups[head + subtitles.size].box)
        }
    }

    @Test
    fun placeTitles() {
        for (title in objects(root.getJSONArray("titles"))) {
            assertEquals(title.getString("text"), title.getBoolean("place"), MissionCard.isPlaceTitle(title.getString("text")))
        }
    }

    @Test
    fun presetsYieldToACrossingCard() {
        for (vector in objects(root.getJSONArray("areas"))) {
            val r = vector.getJSONArray("region")
            val auto = ExtraArea("auto-1", ScreenTextDetector.NAME,
                CropRegion(top = r.getDouble(1), bottom = r.getDouble(3), left = r.getDouble(0), right = r.getDouble(2)),
                auto = true, menu = vector.getBoolean("menu"))
            assertEquals(vector.getString("name"), strings(vector.getJSONArray("kept")),
                RegionWatcher.yieldingPresets(GameAreaPresets.areas("GTA 6") + auto).map { it.id })
        }
    }

    @Test
    fun fragmentsAtTheMessagesEdge() {
        val area = GameAreaPresets.areas("GTA 6").first { it.id == GameAreaPresets.PHONE_ID }
        val fragments = objects(root.getJSONArray("fragments"))
        for (fragment in fragments) {
            assertEquals(fragment.getString("text"), fragment.getBoolean("cut"), RegionWatcher.cutAtAreaLeftEdge(line(fragment), area.region))
        }
        // Hazır mesaj alanının okumasında kesik parçalar çeviriye girmez.
        val kept = RegionWatcher.withoutPresetFragments(Reading(fragments.map(::line)), area)
        val candidate = RegionWatcher.candidate(kept, area.region, styled = true)
        val joined = candidate.paragraphs.joinToString(" ")
        assertTrue(joined, joined.contains("Just saw Moses"))
        for (fragment in fragments.filter { it.getBoolean("cut") }) assertFalse(joined, joined.contains(fragment.getString("text")))
    }

    /** Otomatik alanda konum kartı: başlık çevrilmez, açıklama tek parça ve tek blok. */
    @Test
    fun autoAreaTranslatesTheCardAsOneParagraph() {
        val vector = objects(root.getJSONArray("cards"))[0]
        val region = CropRegion(top = 0.36, bottom = 0.66, left = 0.37, right = 0.78)
        val w = region.right - region.left
        val h = region.bottom - region.top
        val lines = objects(vector.getJSONArray("lines")).map(::line).filter { it.box!!.left >= region.left }.map { l ->
            val b = l.box!!
            l.copy(box = TextBox((b.left - region.left) / w, (b.top - region.top) / h, (b.right - region.left) / w, (b.bottom - region.top) / h))
        }
        val candidate = RegionWatcher.candidate(Reading(lines), region, auto = true)
        assertTrue(candidate.missionCard)
        assertEquals(strings(vector.getJSONArray("subtitles")) + strings(vector.getJSONArray("body")), candidate.paragraphs)
        assertEquals(2, candidate.blocks?.size)
    }
}
