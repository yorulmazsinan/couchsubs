// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Menüde seçim/liste kaydında satır farkı (#1359, #1362) ve tuş çubuğunun dar yazısı (#1360). Ortak vakalar
 * fixtures/menu-rows.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac MenuRowsTests.swift ve Windows
 * MenuRowsTests.cs aynı dosyayı okur).
 */
class MenuRowsTest {
    private val root = JSONObject(Fixtures.text("menu-rows.json"))

    private fun box(b: JSONArray) = TextBox(b.getDouble(0), b.getDouble(1), b.getDouble(2), b.getDouble(3))

    @Test
    fun sharedCarriedRows() {
        val cases = root.getJSONArray("carriedRows")
        assertTrue(cases.length() >= 4)
        for (n in 0 until cases.length()) {
            val case = cases.getJSONObject(n)
            val id = case.getString("id")
            val renderedRows = case.getJSONArray("rendered")
            val rendered = (0 until renderedRows.length()).map { i ->
                val row = renderedRows.getJSONObject(i)
                ScreenTranslation.Item(row.getString("text"), "çeviri", box(row.getJSONArray("box")), 0.03)
            }
            val currentRows = case.getJSONArray("current")
            val current = (0 until currentRows.length()).map { i ->
                val row = currentRows.getJSONObject(i)
                box(row.getJSONArray("box")) to row.getString("text")
            }
            val diff = RegionWatcher.carriedRows(rendered, current, case.getBoolean("listMoved"))
            val keptRows = case.getJSONArray("kept")
            val kept = (0 until keptRows.length()).map { i ->
                val pair = keptRows.getJSONArray(i)
                pair.getInt(0) to (if (pair.isNull(1)) null else pair.getInt(1))
            }
            assertEquals(id, kept, diff.kept)
            val freshRows = case.getJSONArray("fresh")
            assertEquals(id, (0 until freshRows.length()).map { freshRows.getInt(it) }, diff.fresh)
        }
    }

    @Test
    fun sharedCondensedMeasure() {
        val characters = root.getJSONArray("characters")
        for (i in 0 until characters.length()) {
            val case = characters.getJSONObject(i)
            assertEquals(case.getString("text"), case.getInt("characters"), TextStyleSampler.characters(case.getString("text")))
        }
        val condensed = root.getJSONArray("condensed")
        for (i in 0 until condensed.length()) {
            val case = condensed.getJSONObject(i)
            assertEquals(case.toString(), case.getBoolean("condensed"),
                TextStyleSampler.isCondensed(case.getDouble("width"), case.getDouble("height"), case.getInt("characters")))
        }
    }

    /** Aynı gruptaki etiketlerden biri dar yazıysa hepsi dar (#1360); grupsuz etiket değişmez. */
    @Test
    fun groupSharesCondensedLook() {
        fun block(group: Int?): RegionWatcher.Block {
            val paint = TextPaint("#000000", 0.03, TextBox(0.0, 0.0, 0.1, 0.03), group = group)
            return RegionWatcher.Block(0, 1, paint.cover, 0.03, paint = paint)
        }
        fun style(condensed: Boolean) = TextStyleSampler.Style(TextSurface("#000000", "#FFFFFF"),
            TextLook(bold = true, condensed = condensed, align = "left", upper = true))
        val styles = RegionWatcher.condensedTogether(listOf(block(0), block(0), block(0), block(null)),
            listOf(style(true), style(false), style(false), style(false)))
        assertEquals(listOf(true, true, true, false), styles.map { it?.look?.condensed })
    }
}
