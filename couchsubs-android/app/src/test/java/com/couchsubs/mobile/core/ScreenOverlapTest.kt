// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import com.couchsubs.mobile.translation.AiRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #827: aynı yazı aynı yerde tek kez çizilir; menüdeki simge çeviri kutusunun dışında kalır. Kurallar ortak deneme
 * dosyasından (fixtures/screen-overlap.json, core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac ScreenOverlapTests.swift
 * ve Windows ScreenOverlapTests.cs aynı dosyayı okur).
 */
class ScreenOverlapTest {
    private val root = JSONObject(Fixtures.text("screen-overlap.json"))

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))
    private fun strings(array: JSONArray) = (0 until array.length()).map { array.getString(it) }
    private fun lines(array: JSONArray) = (0 until array.length()).map { i ->
        val line = array.getJSONObject(i)
        TextLine(line.getString("text"), box(line.getJSONArray("box")))
    }

    @Test
    fun sharedVectors() {
        val overlap = root.getJSONArray("overlap")
        for (i in 0 until overlap.length()) {
            val vector = overlap.getJSONObject(i)
            val a = box(vector.getJSONArray("a"))
            val b = box(vector.getJSONArray("b"))
            val share = vector.getDouble("share")
            assertEquals(vector.getString("name"), share, ScreenTranslation.overlap(a, b), 1e-9)
            assertEquals(vector.getString("name"), share, ScreenTranslation.overlap(b, a), 1e-9)
        }
        val lines = root.getJSONArray("lines")
        for (i in 0 until lines.length()) {
            val vector = lines.getJSONObject(i)
            assertEquals(vector.getString("name"), strings(vector.getJSONArray("kept")),
                ScreenTranslation.withoutDuplicateLines(lines(vector.getJSONArray("lines"))).map { it.text })
        }
        val layers = root.getJSONArray("layers")
        for (i in 0 until layers.length()) {
            val vector = layers.getJSONObject(i)
            val entries = vector.getJSONArray("items")
            val items = (0 until entries.length()).map { j ->
                val entry = entries.getJSONObject(j)
                val source = entry.getString("source")
                ScreenTranslation.Item(source, entry.optString("translation", "Türkçe $source"), box(entry.getJSONArray("box")), 0.03)
            }
            assertEquals(vector.getString("name"), strings(vector.getJSONArray("kept")), ScreenTranslation.layered(items).map { it.source })
        }
    }

    /** Menüdeki simge (dükkân, kamera, ayar) çeviri kutusunun dışında kalır: kutu yalnız yazıyı kapsar. */
    @Test
    fun edgeMarksStayOutsideTheBox() {
        val edges = root.getJSONArray("edges")
        for (i in 0 until edges.length()) {
            val vector = edges.getJSONObject(i)
            val name = vector.getString("name")
            val words = vector.optJSONArray("words")?.let { array ->
                (0 until array.length()).map { j -> TextWord(array.getJSONObject(j).getString("text"), box(array.getJSONObject(j).getJSONArray("box"))) }
            }
            val trimmed = ScreenTranslation.withoutEdgeMarks(TextLine(vector.getString("text"), box(vector.getJSONArray("box")), words))
            val expect = vector.getJSONObject("expect")
            assertEquals(name, expect.getString("text"), trimmed.text)
            val want = box(expect.getJSONArray("box"))
            val got = trimmed.box!!
            assertEquals(name, want.left, got.left, 1e-9)
            assertEquals(name, want.right, got.right, 1e-9)
            assertEquals(name, want.top, got.top, 1e-9)
            assertEquals(name, want.bottom, got.bottom, 1e-9)
        }
        val icon = TextLine("${ButtonIcons.MARKER} Back", TextBox(0.1, 0.1, 0.2, 0.13),
            icons = listOf(IconSlot(TextBox(0.1, 0.1, 0.12, 0.13), "O")))
        assertSame(icon, ScreenTranslation.withoutEdgeMarks(icon))
    }

    /** "Ekranı çevir": görev listesinin seçili satırı bir de parça olarak okununca ayrı grup (ve altında ikinci kutu) olmaz. */
    @Test
    fun wholeScreenDoesNotTranslateTheSameLineTwice() {
        val vector = root.getJSONArray("lines").getJSONObject(0)
        val paragraphs = ScreenTranslation.groups(Reading(lines(vector.getJSONArray("lines"))), wholeScreen = true).flatMap { it.paragraphs }
        assertFalse(paragraphs.toString(), "Find" in paragraphs)
        assertTrue(paragraphs.toString(), paragraphs.any { it.contains("Find Donnie's Package") })
    }

    /** Aynı okumanın çevirilerinden aynı yeri çizenlerin yalnız biri gösterilir. */
    @Test
    fun presentDropsDuplicateItems() {
        val whole = ScreenTranslation.Item("Find Donnie's Package", "Donnie'nin Paketini Bul", TextBox(0.074, 0.245, 0.25, 0.272), 0.027)
        val piece = ScreenTranslation.Item("Find", "Bulur", TextBox(0.15, 0.255, 0.19, 0.285), 0.03)
        assertEquals(listOf("Find Donnie's Package"), ScreenTranslation.present(listOf(piece, whole), null).map { it.source })
    }

    /** "Ekranı çevir" ekrandayken onun yerindeki ek alan blokları atılır, başka yerdekiler kalır. */
    @Test
    fun uncoveredKeepsOnlyBlocksElsewhere() {
        val screen = listOf(ScreenTranslation.Item("Make Money", "Para Kazan", TextBox(0.075, 0.185, 0.17, 0.21), 0.025))
        val region = listOf(ScreenTranslation.Item("Make Money", "Para Kazanın", TextBox(0.07, 0.18, 0.17, 0.212), 0.025),
            ScreenTranslation.Item("Shoeless Keys", "Shoeless Keys adası", TextBox(0.44, 0.14, 0.53, 0.16), 0.02))
        assertEquals(listOf("Shoeless Keys"), ScreenTranslation.uncovered(region, screen).map { it.source })
    }

    /** Menü ve görev etiketleri kısa, tekil emir kipinde çevrilir ("Para Kazan"; "Para Kazanın" değil). */
    @Test
    fun systemPromptAsksForSingularImperativeLabels() {
        assertTrue(AiRequest.SYSTEM_PROMPT.contains("singular informal imperatives"))
        assertTrue(AiRequest.SYSTEM_PROMPT.contains("\"Para Kazan\""))
    }
}
