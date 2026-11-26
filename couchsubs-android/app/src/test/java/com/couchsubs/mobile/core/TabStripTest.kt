// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Menü sekme şeridi (#1372): aynı şerit her karede başka biçimde ve sırada okunsa da sekmeler ayrı etiket, soldan sağa
 * aynı sırada, aday anahtarı aynı; seçim kayınca bütün sekmelerin çevirisi yerinde kalır. Ortak vakalar
 * fixtures/tab-strip.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac TabStripTests.swift ve Windows
 * TabStripTests.cs aynı dosyayı okur).
 */
class TabStripTest {
    private val root = JSONObject(Fixtures.text("tab-strip.json"))

    private fun box(b: JSONArray) = TextBox(b.getDouble(0), b.getDouble(1), b.getDouble(2), b.getDouble(3))

    private fun line(l: JSONObject): TextLine {
        val words = l.optJSONArray("words")?.let { w ->
            (0 until w.length()).map { i -> w.getJSONObject(i).let { TextWord(it.getString("text"), box(it.getJSONArray("box"))) } }
        }
        val icons = l.optJSONArray("icons")?.let { a -> (0 until a.length()).map { i -> IconSlot(box(a.getJSONArray(i)), "") } }
        return TextLine(l.getString("text"), box(l.getJSONArray("box")), words, icons)
    }

    @Test
    fun tabsKeepTheirOrderEveryFrame() {
        val expectedRows = root.getJSONArray("expected")
        val expected = (0 until expectedRows.length()).map { expectedRows.getString(it) }
        val frames = root.getJSONArray("frames")
        assertTrue(frames.length() >= 3)
        val keys = mutableSetOf<String>()
        for (n in 0 until frames.length()) {
            val frame = frames.getJSONObject(n)
            val name = frame.getString("name")
            val lines = frame.getJSONArray("lines")
            val reading = Reading((0 until lines.length()).map { line(lines.getJSONObject(it)) })
            val candidate = RegionWatcher.candidate(reading, CropRegion(0.0, 1.0, 0.0, 1.0), auto = true, menu = true)
            assertEquals(name, expected, candidate.paragraphs)
            val blocks = candidate.blocks ?: emptyList()
            assertEquals(name, expected.size, blocks.size)
            // Her sekme kendi yerinde, soldan sağa.
            val tabs = blocks.take(4).map { it.box.left }
            assertEquals(name, tabs.sorted(), tabs)
            keys += candidate.key
        }
        assertEquals("aday anahtarı her karede aynı olmalı", 1, keys.size)
    }

    @Test
    fun selectionKeepsEveryTab() {
        val case = root.getJSONObject("carried")
        val id = case.getString("id")
        val renderedRows = case.getJSONArray("rendered")
        val rendered = (0 until renderedRows.length()).map { i ->
            val row = renderedRows.getJSONObject(i)
            ScreenTranslation.Item(row.getString("text"), "çeviri", box(row.getJSONArray("box")), 0.042)
        }
        val currentRows = case.getJSONArray("current")
        val current = (0 until currentRows.length()).map { i ->
            val row = currentRows.getJSONObject(i)
            box(row.getJSONArray("box")) to row.getString("text")
        }
        val diff = RegionWatcher.carriedRows(rendered, current, case.getBoolean("listMoved"))
        val keptRows = case.getJSONArray("kept")
        val kept = (0 until keptRows.length()).map { i -> keptRows.getJSONArray(i).let { it.getInt(0) to it.getInt(1) } }
        assertEquals(id, kept, diff.kept)
        val freshRows = case.getJSONArray("fresh")
        assertEquals(id, (0 until freshRows.length()).map { freshRows.getInt(it) }, diff.fresh)
    }

    /** Sekme etiketleri arayüz sözlüğünden; karakter adları olduğu gibi. */
    @Test
    fun tabLabels() {
        assertEquals("HARİTA", UiCommands.translateLabelLoosely("MAP"))
        assertEquals("GALERİ", UiCommands.translateLabelLoosely("GALLERY"))
        assertEquals("JASON LUCIA HARİTA ÖZET", UiCommands.translateLabelLoosely("JASON LUCIA MAP BRIEF"))
        assertTrue(ScreenTranslation.keepsNames("JASON LUCIA"))
        assertFalse(ScreenTranslation.keepsNames("MAP BRIEF"))
    }
}
