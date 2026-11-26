// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Harita görev/konum kartı: kartın tanınması, parçalarının ayrı çevrilmesi ve otomatik ekran yazısında türü. Kurallar
 * ortak deneme dosyasından (fixtures/mission-card.json, core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac
 * MissionCardTests.swift ve Windows MissionCardTests.cs aynı dosyayı okur).
 */
class MissionCardTest {
    /** [place]: konum kartı (#1391), başlık yer adı, çevrilmez (grubu yok). */
    private data class Expected(
        val title: String,
        val subtitles: List<String>,
        val body: List<String>,
        val details: List<String>,
        val helpCorner: Boolean,
        val place: Boolean,
    )
    private data class Case(val name: String, val lines: List<TextLine>, val cards: List<Expected>)

    private fun strings(array: org.json.JSONArray) = (0 until array.length()).map { array.getString(it) }

    private fun cases(): List<Case> {
        val root = JSONObject(Fixtures.text("mission-card.json")).getJSONArray("cases")
        return (0 until root.length()).map { i ->
            val case = root.getJSONObject(i)
            val lines = case.getJSONArray("lines").let { array ->
                (0 until array.length()).map { j ->
                    val line = array.getJSONObject(j)
                    val box = line.getJSONArray("box")
                    TextLine(line.getString("text"), TextBox(box.getDouble(0), box.getDouble(1), box.getDouble(2), box.getDouble(3)))
                }
            }
            val cards = case.getJSONArray("cards").let { array ->
                (0 until array.length()).map { j ->
                    val card = array.getJSONObject(j)
                    Expected(card.getString("title"), strings(card.getJSONArray("subtitles")), strings(card.getJSONArray("body")),
                        strings(card.getJSONArray("details")), card.getBoolean("helpCorner"), card.optBoolean("place", false))
                }
            }
            Case(case.getString("name"), lines, cards)
        }
    }

    @Test
    fun sharedVectors() {
        for (vector in cases()) {
            val cards = MissionCard.find(vector.lines)
            assertEquals(vector.name, vector.cards.size, cards.size)
            for ((card, expected) in cards.zip(vector.cards)) {
                val groups = MissionCard.groups(card, vector.lines)
                assertEquals(vector.name, expected.place, card.place)
                assertEquals(vector.name, expected.title, card.title.joinToString(" ") { vector.lines[it].text })
                val head = if (expected.place) 0 else 1
                if (!expected.place) assertEquals(vector.name, listOf(expected.title), groups.first().paragraphs)
                assertEquals(vector.name, expected.subtitles, groups.drop(head).take(expected.subtitles.size).flatMap { it.paragraphs })
                assertEquals(vector.name, expected.body, groups[head + expected.subtitles.size].paragraphs)
                assertEquals(vector.name, expected.details, groups.takeLast(expected.details.size).flatMap { it.paragraphs })
                assertEquals(vector.name, head + 1 + expected.subtitles.size + expected.details.size, groups.size)
                val box = card.all.map { vector.lines[it].box!! }.reduce { a, b -> a.union(b) }
                assertEquals(vector.name, expected.helpCorner, MissionCard.inHelpCorner(box))
            }
        }
    }

    /** "Ekranı çevir": başlık açıklamanın ilk cümlesine katılmaz; haritanın başka yazıları ayrı kalır. */
    @Test
    fun wholeScreenSplitsTheCardIntoItsParts() {
        val all = cases()
        val groups = ScreenTranslation.groups(Reading(all[0].lines), wholeScreen = true)
        assertTrue(groups.any { it.paragraphs == listOf("THE MARINA JOB") })
        assertTrue(groups.any {
            it.paragraphs == listOf("Brian wants the boat moved before the harbor patrol makes its rounds.", "Bring Lucia along for backup.")
        })
        assertTrue(groups.any { it.paragraphs == listOf("VICE CITY") })
        // Kartın uzun başlığı eskiden ilk cümleye katılıyordu.
        assertEquals(listOf("ESCAPE FROM THE PORT OF LEONIDA"),
            ScreenTranslation.groups(Reading(all[1].lines), wholeScreen = true).first().paragraphs)
    }

    /** Otomatik ekran yazısında kartın bulunduğu alan "Görev ve hedef yazısı"dır; yardım köşesindeki başlıklı kutu değil. */
    @Test
    fun autoAreaWithACardIsAMission() {
        val all = cases()
        val region = CropRegion(top = 0.35, bottom = 0.65, left = 0.55, right = 0.95)
        val place = region.box
        val local = Reading(all[0].lines.map { line ->
            val b = line.box!!
            val w = place.right - place.left
            val h = place.bottom - place.top
            line.copy(box = TextBox((b.left - place.left) / w, (b.top - place.top) / h, (b.right - place.left) / w, (b.bottom - place.top) / h))
        })
        val area = ExtraArea(id = "auto-1", name = "Screen text", region = region, auto = true)
        val card = RegionWatcher.candidate(local, region, auto = true)
        assertTrue(card.missionCard)
        assertEquals(ScreenTextKind.MISSION, RegionWatcher.kind(area, card))
        assertTrue(card.blocks!!.any { card.paragraphs.subList(it.start, it.start + it.count) == listOf("THE MARINA JOB") })
        val corner = CropRegion(top = 0.0, bottom = 0.3, left = 0.0, right = 0.4)
        val help = RegionWatcher.candidate(Reading(all[3].lines.map { line ->
            val b = line.box!!
            line.copy(box = TextBox(b.left / 0.4, b.top / 0.3, b.right / 0.4, b.bottom / 0.3))
        }), corner, auto = true)
        assertFalse(help.missionCard)
        assertEquals(ScreenTextKind.HELP, RegionWatcher.kind(ExtraArea(id = "auto-2", name = "Screen text", region = corner, auto = true), help))
    }

    /** Menüler kapalıyken kart boyundaki menü alanı "Görev ve hedef yazısı" açıksa okunur; ekranı kaplayan menü okunmaz. */
    @Test
    fun menuAreaIsReadForMapCardsOnlyWhenMissionsAreOn() {
        val small = ExtraArea(id = "auto-1", name = "Screen text", region = CropRegion(top = 0.3, bottom = 0.6, left = 0.55, right = 0.9),
            auto = true, menu = true)
        val wide = small.copy(region = CropRegion(top = 0.1, bottom = 0.9, left = 0.05, right = 0.95))
        val kinds = ScreenTextKinds()
        assertTrue(ScreenTextKind.reads(small) { kinds.allows(true, it) })
        assertFalse(ScreenTextKind.reads(wide) { kinds.allows(true, it) })
        val noMission = kinds.copy(mission = false)
        assertFalse(ScreenTextKind.reads(small) { noMission.allows(true, it) })
        // Ana anahtar kapalıyken türler uygulanmaz.
        assertTrue(ScreenTextKind.reads(wide) { kinds.allows(false, it) })
    }
}
