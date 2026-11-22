// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * GTA 6 menü/görev ekranı (#856, #859, #860): menü şeridinin sekmeleri ayrı, yalnız özel addan oluşan sekme çevrilmez,
 * satır ucundaki tuş simgesi kutunun dışında, saat çevrilmez. Ortak deneme dosyası fixtures/screen-menu.json
 * (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac ScreenMenuBarTests.swift ve Windows ScreenMenuBarTests.cs aynı dosyayı okur).
 */
class ScreenMenuBarTest {
    private val root = JSONObject(Fixtures.text("screen-menu.json"))

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    private fun words(array: JSONArray?): List<TextWord>? = array?.let {
        (0 until it.length()).map { i -> it.getJSONObject(i).let { w -> TextWord(w.getString("text"), box(w.getJSONArray("box"))) } }
    }

    private fun objects(name: String) = root.getJSONArray(name).let { array -> (0 until array.length()).map { array.getJSONObject(it) } }

    @Test
    fun namesOnlyAreKept() {
        for (name in objects("names")) {
            val text = name.getString("text")
            val keep = name.getBoolean("keep")
            assertEquals(text, keep, ScreenTranslation.keepsNames(text))
            if (keep) assertEquals(text, text, ScreenTranslation.known(text))
        }
    }

    @Test
    fun clocksAreNotTranslated() {
        for (clock in objects("clocks")) {
            assertEquals(clock.getString("text"), clock.getBoolean("clock"), ScreenTranslation.isClock(clock.getString("text")))
        }
    }

    @Test
    fun menuBarSplitsIntoTabs() {
        for (menu in objects("menuLines")) {
            val name = menu.getString("name")
            val line = TextLine(menu.getString("text"), box(menu.getJSONArray("box")), words(menu.getJSONArray("words")))
            val pieces = ScreenTranslation.menuPieces(line)
            val expected = menu.getJSONArray("pieces").let { a -> (0 until a.length()).map { a.getString(it) } }
            assertEquals(name, expected, pieces.map { it.text })
            for (piece in pieces) assertEquals(name, line.box!!.top, piece.box!!.top, 0.0)
        }
    }

    @Test
    fun edgeButtonsStayOutsideTheBox() {
        for (edge in objects("edgeIcons")) {
            val name = edge.getString("name")
            val icons = edge.optJSONArray("icons")?.let { a -> (0 until a.length()).map { IconSlot(box(a.getJSONArray(it)), "") } }
            val line = TextLine(edge.getString("text"), box(edge.getJSONArray("box")), words(edge.optJSONArray("words")), icons)
            val trimmed = ScreenTranslation.withoutEdgeIcons(line)
            assertEquals(name, edge.getString("expected"), trimmed.text)
            assertEquals(name, edge.getDouble("left"), trimmed.box!!.left, 1e-9)
            assertEquals(name, edge.getDouble("right"), trimmed.box!!.right, 1e-9)
            if (trimmed.text != line.text) assertNull(name, trimmed.icons)
        }
    }

    /** Menü şeridi sözcük yerleri olmadan da görüntüdeki boşluklardan bölünür. */
    @Test
    fun menuBarSplitsFromThePixels() {
        val width = 960
        val height = 60
        val luma = ByteArray(width * height) { 30 }
        // Üç sekme: harf benzeri dikey çizgiler, sekme içinde dar, sekmeler arasında geniş boşluk (harf başına ~14 nokta).
        for ((start, end) in listOf(40 to 222, 300 to 342, 420 to 532)) {
            for (x in start until end) if ((x - start) % 12 < 6) for (y in 15 until 45) luma[y * width + x] = 230.toByte()
        }
        val frame = GrayFrame(luma, width, height)
        val line = TextLine("JASON & LUCIA MAP PROGRESS", TextBox(40.0 / 960, 0.25, 532.0 / 960, 0.75))
        val pieces = ScreenTranslation.menuPieces(line, 16.0, frame)
        assertEquals(listOf("JASON & LUCIA", "MAP", "PROGRESS"), pieces.map { it.text })
        assertEquals(300.0 / 960, pieces[1].box!!.left, 0.003)
        assertEquals(342.0 / 960, pieces[1].box!!.right, 0.01)
    }

    /** Görev kartı: başlığın solunda portre var, açıklama portrenin altından başlar. */
    @Test
    fun cardWithPortrait() {
        val portrait = listOf(
            TextLine("ISLAND DREAMS", TextBox(0.187, 0.193, 0.350, 0.244)),
            TextLine("Keep an eye on the bachelor party", TextBox(0.147, 0.276, 0.429, 0.310)),
            TextLine("while searching Kenton's dive spot for", TextBox(0.146, 0.326, 0.462, 0.363)),
            TextLine("treasure.", TextBox(0.145, 0.382, 0.222, 0.409)),
        )
        val cards = MissionCard.find(portrait)
        assertEquals(1, cards.size)
        assertEquals(
            listOf(listOf("ISLAND DREAMS"), listOf("Keep an eye on the bachelor party while searching Kenton's dive spot for treasure.")),
            MissionCard.groups(cards[0], portrait).map { it.paragraphs },
        )
    }
}
