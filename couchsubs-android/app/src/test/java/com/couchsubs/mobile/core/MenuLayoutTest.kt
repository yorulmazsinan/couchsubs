// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Menüde çevirinin biçimi ayardan gelir (#1365, [MenuLayout]): B üstünü örter, A Türkçeyi yanına koyu etikete yazar
 * (yanına sığmazsa altına/üstüne, şerit bir bütün), görev kartının ikizi kartın altında. Ortak deneme dosyası
 * fixtures/menu-layout.json (Mac MenuLayoutTests.swift, Windows MenuLayoutTests.cs aynı vakalar).
 */
class MenuLayoutTest {
    private val fixture = JSONObject(Fixtures.text("menu-layout.json"))

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    private fun near(expected: TextBox, actual: TextBox?, what: String) {
        assertNotNull("$what: kutu yok", actual)
        val a = actual!!
        val ok = abs(a.left - expected.left) < 1e-6 && abs(a.top - expected.top) < 1e-6 &&
            abs(a.right - expected.right) < 1e-6 && abs(a.bottom - expected.bottom) < 1e-6
        assertTrue("$what: beklenen $expected, çıkan $a", ok)
    }

    @Test
    fun sharedCases() {
        assertEquals(MenuLayout.LABEL_COLOR, fixture.getString("labelColor"))
        val cases = fixture.getJSONArray("cases")
        for (n in 0 until cases.length()) {
            val c = cases.getJSONObject(n)
            val id = c.getString("id")
            val items = c.getJSONArray("items").let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            val paints = items.map { i ->
                val cover = box(i.getJSONArray("cover"))
                // Ölçümün seçtiği kip ne olursa olsun kilitlenir.
                TextPaint(i.getString("bg"), i.getDouble("line"), cover, iconSide = i.optString("icon").ifEmpty { null },
                    mode = TextPaint.MODE_TWIN, spot = cover, spotRoom = cover, twin = TextBox(0.0, 0.0, 1.0, 1.0))
            }
            val targets = items.map { i ->
                TextPainter.Target(box(i.getJSONArray("box")), i.getDouble("line"), 1, i.getString("bg"), "#F0F0F0", false,
                    i.getString("align"))
            }
            val cards = c.getJSONArray("cards").let { a ->
                (0 until a.length()).map { k -> a.getJSONArray(k).let { card -> (0 until card.length()).map { card.getInt(it) } } }
            }
            val result = MenuLayout.locked(paints, targets, cards, c.getBoolean("cover"), c.getDouble("aspect"))
            val expect = c.getJSONArray("expect")
            assertEquals(id, expect.length(), result.size)
            for (k in 0 until expect.length()) {
                val e = expect.getJSONObject(k)
                val p = result[k]
                val what = "$id / ${items[k].getString("name")}"
                assertEquals("$what: kip", e.getString("mode"), p.mode)
                near(paints[k].cover, p.cover, "$what örtü")
                if (p.mode == TextPaint.MODE_COVER) {
                    assertNull(what, p.spot)
                    assertNull(what, p.twin)
                    assertNull(what, p.label)
                    continue
                }
                near(box(e.getJSONArray("spot")), p.spot, "$what spot")
                near(box(e.getJSONArray("room")), p.spotRoom, "$what spotRoom")
                if (p.mode == TextPaint.MODE_BESIDE) {
                    assertEquals(what, e.getString("label"), p.label)
                    assertNull(what, p.twin)
                } else {
                    near(box(e.getJSONArray("twin")), p.twin, "$what twin")
                    assertEquals(what, e.getString("bg"), p.background)
                    assertNull(what, p.label)
                }
            }
        }
    }

    /**
     * İkiz kartın kişi resmi kareden bulunur ([TextPainter.cardPortrait]): başlığa yakın resim bulunur; harita, harf taşması
     * ve resimsiz kart resim sayılmaz. Ortak deneme dosyası fixtures/card-portrait.json.
     */
    @Test
    fun cardPortraitSharedCases() {
        val root = JSONObject(Fixtures.text("card-portrait.json"))
        val width = root.getInt("width")
        val height = root.getInt("height")
        fun rgb(hex: String) = hex.substring(1).toInt(16)
        val cases = root.getJSONArray("cases")
        for (n in 0 until cases.length()) {
            val c = cases.getJSONObject(n)
            val id = c.getString("id")
            val rects = c.getJSONArray("rects").let { a ->
                (0 until a.length()).map { k ->
                    val r = a.getJSONObject(k)
                    val b = r.getJSONArray("box")
                    intArrayOf(b.getInt(0), b.getInt(1), b.getInt(2), b.getInt(3)) to rgb(r.getString("color"))
                }
            }
            val ground = rgb(c.getString("base"))
            val color = { x: Int, y: Int ->
                rects.lastOrNull { (b, _) -> x >= b[0] && x < b[2] && y >= b[1] && y < b[3] }?.second ?: ground
            }
            val covers = c.getJSONArray("covers").let { a ->
                (0 until a.length()).map { k ->
                    val v = a.getJSONArray(k)
                    TextBox(v.getDouble(0) / width, v.getDouble(1) / height, v.getDouble(2) / width, v.getDouble(3) / height)
                }
            }
            val card = c.getJSONArray("card").let { a -> (0 until a.length()).map { a.getInt(it) } }
            val found = TextPainter.cardPortrait(covers, card, c.getString("background"), c.getDouble("line") / height, width, height, color)
            if (c.isNull("expect")) {
                assertNull("$id: resim bulunmamalı, bulunan $found", found)
                continue
            }
            val e = c.getJSONArray("expect")
            near(TextBox(e.getDouble(0) / width, e.getDouble(1) / height, e.getDouble(2) / width, e.getDouble(3) / height), found, id)
        }
    }

    /** İkiz kartta kişi resmi yoksa kareden aranan resim bütün parçalara konur ve ikiz kutu resmi de içine alır. */
    @Test
    fun cardTwinTakesTheFoundPortrait() {
        val title = TextPaint("#1E2A5A", 0.04, TextBox(0.30, 0.30, 0.50, 0.34))
        val body = TextPaint("#1E2A5A", 0.04, TextBox(0.24, 0.36, 0.60, 0.44))
        val targets = listOf(title, body).map { TextPainter.Target(it.cover, 0.04, 1, "#1E2A5A", "#F0F0F0", false, "left") }
        val face = TextBox(0.24, 0.29, 0.28, 0.35)
        var asked = 0
        val result = MenuLayout.locked(listOf(title, body), targets, listOf(listOf(0, 1)), false, 1.0) { _, fill ->
            asked++
            assertEquals("#1E2A5A", fill)
            face to "data:image/png;base64,AA=="
        }
        assertEquals(1, asked)
        for (p in result) {
            assertEquals(TextPaint.MODE_TWIN, p.mode)
            assertEquals(face, p.portrait)
            assertEquals("data:image/png;base64,AA==", p.portraitImage)
            assertTrue("ikiz resmi içine alır", p.twin!!.left <= face.left && p.portraitTwin!!.top > p.twin!!.top - 1e-9)
        }
        // Görev listesindeki kart ikiz kurulmaz: resim de aranmaz.
        val row = TextPaint("#1E2A5A", 0.04, TextBox(0.24, 0.10, 0.40, 0.14))
        val listTargets = listOf(TextPainter.Target(row.cover, 0.04, 1, "#1E2A5A", "#F0F0F0", false, "left")) + targets
        MenuLayout.locked(listOf(row, title, body), listTargets, listOf(listOf(1, 2)), false, 1.0) { _, _ -> asked++; null }
        assertEquals(1, asked)
    }

    /**
     * Menüde biçim ayardan gelince satırın saklı kipi ([RegionWatcher.steadyPaints], menuCover): ayar değişince eski biçim
     * kalmaz, A'da bir kez örtülen satır örtülü kalmaz, kart ikizi harita düzeninde kalır, menü dışı okumanın kipi menüye
     * geçmez. Ortak deneme dosyası fixtures/menu-steady.json (Mac, Windows aynı).
     */
    @Test
    fun menuRowPaintFollowsTheSetting() {
        val sequences = JSONObject(Fixtures.text("menu-steady.json")).getJSONArray("sequences")
        for (s in 0 until sequences.length()) {
            val sequence = sequences.getJSONObject(s)
            val name = sequence.getString("name")
            val reads = sequence.getJSONArray("reads")
            val memory = HashMap<String, RegionWatcher.RowPaint>()
            for (index in 0 until reads.length()) {
                val read = reads.getJSONObject(index)
                val menuCover = if (read.isNull("menuCover")) null else read.getBoolean("menuCover")
                val rows = read.getJSONArray("rows").let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
                val blocks = rows.mapIndexed { i, row ->
                    val b = row.getJSONArray("box").let { TextBox(it.getDouble(0), it.getDouble(1), it.getDouble(2), it.getDouble(3)) }
                    RegionWatcher.Block(i, 1, b, 0.04, paint = steadyPaint(row.getString("mode"), b))
                }
                val out = RegionWatcher.steadyPaints(blocks, rows.map { it.getString("text") }, memory, read.getBoolean("map"), menuCover)
                val expected = read.getJSONArray("expected")
                for (k in rows.indices) {
                    assertEquals("$name okuma $index: ${rows[k].getString("text")}", expected.getString(k), out[k].paint?.mode)
                    // Taşınan ölçü satırın yeni yerindedir.
                    assertEquals("$name okuma $index", rows[k].getJSONArray("box").getDouble(1), out[k].paint!!.cover.top, 1e-9)
                }
            }
        }
    }

    private fun steadyPaint(mode: String, box: TextBox): TextPaint {
        val paint = TextPaint(background = "#202020", pitch = box.bottom - box.top, cover = box)
        val width = box.right - box.left
        val height = box.bottom - box.top
        return when (mode) {
            "beside" -> {
                val spot = TextBox(box.right + 0.01, box.top, box.right + 0.01 + width, box.bottom)
                paint.copy(mode = TextPaint.MODE_BESIDE, spot = spot, spotRoom = spot, label = MenuLayout.LABEL_COLOR)
            }
            "twin" -> {
                val twin = TextBox(box.left, box.bottom + 0.01, box.right, box.bottom + 0.01 + height)
                paint.copy(mode = TextPaint.MODE_TWIN, twin = twin, spot = twin)
            }
            else -> paint.copy(mode = TextPaint.MODE_COVER)
        }
    }
}
