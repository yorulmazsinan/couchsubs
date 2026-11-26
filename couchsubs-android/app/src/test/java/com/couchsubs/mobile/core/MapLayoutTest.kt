// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Harita düzeni (#1365): GTA 6 Harita › STORY ekranı (koyu panelde görev listesi, görev kartı, haritanın üstünde tuş
 * çubuğu) menü sayılır; liste tek alanda okunur, hazır alanlar yer verir; kamera oynayan ya da karanlık oyun sahnesi menü
 * sayılmaz. Ortak deneme dosyası fixtures/map-layout.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac
 * MapLayoutTests.swift ve Windows MapLayoutTests.cs aynı dosyayı okur).
 */
class MapLayoutTest {
    private data class Text(val role: String, val column: Int, val row: Int, val width: Int, val kind: String)
    private data class Box(val cells: List<Int>, val fill: Int)
    private data class Panel(val side: String, val columns: Int, val fill: Int)
    private data class Scene(
        val name: String, val map: Int, val texture: Boolean, val moving: Boolean, val mirror: Boolean, val panel: Panel?,
        val boxes: List<Box>, val texts: List<Text>, val untilMs: Int, val expect: JSONObject,
    )

    private fun scenes(): List<Scene> {
        val array = JSONObject(Fixtures.text("map-layout.json")).getJSONArray("scenes")
        return (0 until array.length()).map { i ->
            val o = array.getJSONObject(i)
            val panel = o.optJSONObject("panel")?.let { Panel(it.getString("side"), it.getInt("columns"), it.getInt("fill")) }
            val boxes = o.getJSONArray("boxes").let { a ->
                (0 until a.length()).map { j ->
                    val b = a.getJSONObject(j)
                    val cells = b.getJSONArray("cells")
                    Box((0 until cells.length()).map { cells.getInt(it) }, b.getInt("fill"))
                }
            }
            val texts = o.getJSONArray("texts").let { a ->
                (0 until a.length()).map { j ->
                    val t = a.getJSONObject(j)
                    Text(t.getString("role"), t.getInt("column"), t.getInt("row"), t.getInt("width"), t.getString("kind"))
                }
            }
            Scene(o.getString("name"), o.getInt("map"), o.getBoolean("texture"), o.getBoolean("moving"),
                o.optBoolean("mirror", false), panel, boxes, texts, o.getInt("untilMs"), o.getJSONObject("expect"))
        }
    }

    /** Aynalanmış sahne (sütunlar öbür yana). */
    private fun mirrored(scene: Scene): Scene {
        if (!scene.mirror) return scene
        return scene.copy(
            texts = scene.texts.map { it.copy(column = 32 - it.column - it.width) },
            boxes = scene.boxes.map { b -> b.copy(cells = listOf(31 - b.cells[2], b.cells[1], 31 - b.cells[0], b.cells[3])) },
            panel = scene.panel?.let { it.copy(side = if (it.side == "left") "right" else "left") },
        )
    }

    /** Sahnenin [phase] anındaki karesi (gri ton). */
    private fun pixels(scene: Scene, phase: Int): IntArray {
        val gray = IntArray(WIDTH * HEIGHT) { scene.map }
        fun set(x: Int, y: Int, v: Int) { gray[y * WIDTH + x] = v }
        val panelColumns: Set<Int> = scene.panel?.let { panel ->
            if (panel.side == "left") (0 until panel.columns).toSet() else ((32 - panel.columns) until 32).toSet()
        } ?: emptySet()
        for (row in 0 until 18) for (column in 0 until 32) {
            val x0 = column * TILE
            val y0 = row * TILE
            if (column in panelColumns) {
                for (y in y0 until y0 + TILE) for (x in x0 until x0 + TILE) set(x, y, scene.panel!!.fill)
            } else if (scene.texture && (column + row) % 3 != 0) {
                val shift = if (scene.moving) phase % 3 else 0
                for (y in y0 until y0 + TILE) for (x in x0 until x0 + TILE) set(x, y, if ((y + shift) % 3 == 0) 200 else 120)
            }
        }
        for (box in scene.boxes) {
            for (y in box.cells[1] * TILE until (box.cells[3] + 1) * TILE) {
                for (x in box.cells[0] * TILE until (box.cells[2] + 1) * TILE) set(x, y, box.fill)
            }
        }
        for (text in scene.texts) {
            val y0 = text.row * TILE
            for (y in y0 + 3 until y0 + 17) {
                val r = (y - y0) % 6
                for (x in text.column * TILE until (text.column + text.width) * TILE) {
                    val stroke = x % 5 < 2
                    if (text.kind == "dark") {
                        set(x, y, if ((r == 2 || r == 3) && stroke) 240 else 24)
                    } else if ((r == 2 || r == 3) && stroke) {
                        set(x, y, 240)
                    } else if ((r == 1 || r == 4) && stroke) {
                        set(x, y, 40)
                    }
                }
            }
        }
        return gray
    }

    private fun holder(areas: List<ExtraArea>, text: Text): ExtraArea? {
        val cx = (text.column + text.width / 2.0) / 32
        val cy = (text.row + 0.5) / 18
        return areas.firstOrNull { cx >= it.region.left && cx <= it.region.right && cy >= it.region.top && cy <= it.region.bottom }
    }

    @Test
    fun mapLayoutScenes() {
        for (original in scenes()) {
            val scene = mirrored(original)
            val detector = ScreenTextDetector { 0L }
            val notes = mutableListOf<String>()
            detector.onLog = { notes.add(it) }
            var time = 0
            while (time <= scene.untilMs) {
                val frame = pixels(scene, time / 100)
                detector.update(detector.sample(WIDTH, HEIGHT) { x, y -> frame[y * WIDTH + x] }, listOf(CropRegion()), time.toLong())
                time += ScreenTextDetector.SAMPLE_GAP_MS.toInt()
            }
            val expect = scene.expect
            assertEquals(scene.name, expect.getBoolean("menu"), detector.menu)
            assertEquals(scene.name, expect.getBoolean("mapLayout"), detector.inMapLayout)
            if (expect.getBoolean("mapLayout")) {
                assertTrue("${scene.name}: $notes", notes.any { it.startsWith("ekran menüsü: harita düzeni bulundu") })
            }
            val areas = detector.areas
            expect.optJSONArray("together")?.let { roles ->
                for (i in 0 until roles.length()) {
                    val role = roles.getString(i)
                    val held = scene.texts.filter { it.role == role }.map { holder(areas, it)?.id }
                    assertFalse("${scene.name}: $role alansız", held.contains(null))
                    assertEquals("${scene.name}: $role bölündü", 1, held.toSet().size)
                }
            }
            expect.optJSONArray("apart")?.let { pairs ->
                for (i in 0 until pairs.length()) {
                    val pair = pairs.getJSONArray(i)
                    val a = scene.texts.filter { it.role == pair.getString(0) }.mapNotNull { holder(areas, it)?.id }.toSet()
                    val b = scene.texts.filter { it.role == pair.getString(1) }.mapNotNull { holder(areas, it)?.id }.toSet()
                    assertTrue("${scene.name}: $pair aynı alanda", a.intersect(b).isEmpty())
                }
            }
            if (expect.optBoolean("presetsYield", false)) {
                val kept = RegionWatcher.yieldingPresets(GameAreaPresets.areas("GTA 6") + areas)
                assertFalse("${scene.name}: hazır alan okunuyor", kept.any { GameAreaPresets.isPreset(it.id) })
            }
        }
    }

    /** Düzen karolara bakar: sentetik karo tonlarıyla (çizimsiz) sol panel bulunur, panelsiz ya da koyu haritada bulunmaz. */
    @Test
    fun mapPanelFromTileTones() {
        fun panel(tone: (Int, Int) -> Double, text: Set<Int> = emptySet(), steady: Boolean = true) =
            ScreenTextDetector.mapPanel({ it in text }) { index -> tone(index % 32, index / 32) to steady }
        val list = (1..6).flatMap { row -> (1..6).map { row * 32 + it } }.toSet()
        val found = panel({ column, _ -> if (column < 9) 45.0 else 160.0 }, list)
        assertEquals(true, found?.left)
        assertEquals(9, found?.width)
        assertNull("panelde liste yok", panel({ column, _ -> if (column < 9) 45.0 else 160.0 }))
        assertNull("harita oynuyor", panel({ column, _ -> if (column < 9) 45.0 else 160.0 }, list, steady = false))
        assertNull("yanı da karanlık", panel({ column, _ -> if (column < 9) 45.0 else 60.0 }, list))
        assertNull("panel tam boy değil", panel({ column, row -> if (column < 9 && row < 12) 45.0 else 160.0 }, list))
        val right = (1..6).flatMap { row -> (25..30).map { row * 32 + it } }.toSet()
        assertEquals(false, panel({ column, _ -> if (column >= 23) 45.0 else 160.0 }, right)?.left)
    }

    private companion object {
        const val WIDTH = 640
        const val HEIGHT = 360
        const val TILE = 20
    }
}
