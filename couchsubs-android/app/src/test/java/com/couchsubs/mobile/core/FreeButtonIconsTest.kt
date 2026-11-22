// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Görüntüden tuş simgesi bulma ([ButtonIcons.markFree]): tuş çubuğu, satır başı/sonu, yanlış okunmuş simge ve renksiz
 * simge (#860). Ortak vakalar fixtures/free-button-icons.json (core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac
 * FreeButtonIconsTests.swift ve Windows FreeButtonIconsTests.cs aynı dosyayı okur); geri kalanı Mac ve Windows'taki
 * testlerin aynısı.
 */
class FreeButtonIconsTest {
    private companion object {
        const val M = ButtonIcons.MARKER
    }

    private val root = JSONObject(Fixtures.text("free-button-icons.json"))
    private val layout = root.getJSONObject("frame")

    /** Renkli sentetik kare: gri düzlem ve (x, y) rengi. */
    private class Image(val gray: GrayFrame, val color: (Int, Int) -> Int)

    /** Zeminde, verilen x'lerde 3 piksel kalın halkalar (düğme dairesi gibi). */
    private fun image(rings: List<Int>, background: Int = 0x000000, ink: Int = 0xFFFFFF): Image {
        val width = layout.getInt("width")
        val height = layout.getInt("height")
        val top = layout.getInt("top")
        val size = layout.getInt("size")
        val rgb = IntArray(width * height) { background }
        for (x0 in rings) for (y in top until top + size) for (x in x0 until x0 + size) {
            if (x - x0 < 3 || x0 + size - x <= 3 || y - top < 3 || top + size - y <= 3) rgb[y * width + x] = ink
        }
        val luma = ByteArray(rgb.size) { i ->
            val c = rgb[i]
            ((299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000).toByte()
        }
        return Image(GrayFrame(luma, width, height)) { x, y -> rgb[y * width + x] }
    }

    private fun image(vararg rings: Int) = image(rings.toList())

    private fun rgb(array: JSONArray?, fallback: Int) =
        array?.let { (it.getInt(0) shl 16) or (it.getInt(1) shl 8) or it.getInt(2) } ?: fallback

    private fun word(text: String, left: Double, right: Double) = TextWord(text, TextBox(left, 0.25, right, 0.75))

    private fun line(vararg words: TextWord) = line(words.toList())

    private fun line(words: List<TextWord>) =
        TextLine(words.joinToString(" ") { it.text }, words.drop(1).fold(words[0].box) { all, w -> all.union(w.box) }, words = words)

    private val full = CropRegion(0.0, 1.0, 0.0, 1.0)

    @Test
    fun sharedCasesMatchMacAndWindows() {
        val cases = root.getJSONArray("cases")
        assertTrue(cases.length() >= 10)
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val rings = case.getJSONArray("rings").let { list -> (0 until list.length()).map { list.getInt(it) } }
            val picture = image(rings, rgb(case.optJSONArray("background"), 0x000000), rgb(case.optJSONArray("ink"), 0xFFFFFF))
            val words = case.getJSONArray("words").let { list ->
                (0 until list.length()).map { k -> list.getJSONArray(k).let { word(it.getString(0), it.getDouble(1), it.getDouble(2)) } }
            }
            val source = line(words)
            case.optJSONObject("markFree")?.let { expected ->
                val marked = ButtonIcons.markFree(source, picture.gray, picture.color)
                assertEquals(name, expected.getString("text"), marked.text)
                val icons = expected.optJSONArray("icons")?.let { list -> (0 until list.length()).map { list.getString(it) } }
                assertEquals(name, icons, marked.icons?.map { it.text })
                if (icons == null) assertSame(name, source, marked)
                // Kesilen her simge karenin içinde ve resmi var.
                marked.icons?.let { slots ->
                    for (icon in ButtonIcons.withImages(slots, picture.gray)) {
                        assertTrue(name, icon.box.left >= 0 && icon.box.right <= 1)
                        assertNotNull(name, icon.image)
                    }
                    for (k in 1 until slots.size) assertTrue(name, slots[k - 1].box.right <= slots[k].box.left)
                }
            }
            case.optJSONObject("screen")?.let { expected ->
                val groups = ScreenTranslation.groups(Reading(listOf(source)), wholeScreen = true, frame = picture.gray, color = picture.color)
                val paragraphs = expected.getJSONArray("paragraphs").let { list -> (0 until list.length()).map { list.getString(it) } }
                assertEquals(name, paragraphs, groups.flatMap { it.paragraphs })
                assertTrue(name, groups.all { it.icons == null })
                assertTrue(name, groups.all { it.box.right <= expected.getDouble("maxRight") + 1e-9 })
            }
        }
    }

    @Test
    fun onlyVisibleIconsChangeTheCandidateKey() {
        val reading = Reading(listOf(line(word("SET", 0.05, 0.15), word("DESTINATION", 0.17, 0.45), word("EXIT", 0.55, 0.65))))
        assertNotEquals(RegionWatcher.candidate(reading, full, image().gray).key, RegionWatcher.candidate(reading, full, image(191).gray).key)
    }

    @Test
    fun measuredButtonIncludesTheOutlineAroundItsLetters() {
        val picture = image(120)
        // Yazı tanıma düğmenin yalnız ortasındaki harfleri kutuladı (124..134); kontur 120..138.
        val marked = ButtonIcons.markFree(line(word("SELECT", 0.05, 0.26), word("R1", 124 / 400.0, 134 / 400.0)), picture.gray)
        val icon = ButtonIcons.withImages(marked.icons!!, picture.gray).single()
        assertEquals(ButtonIcons.crop(picture.gray, TextBox(0.28, 0.1, 0.36, 0.9)), icon.image)
    }

    @Test
    fun regionGroupsKeepTheButtonOutsideTheBox() {
        val reading = Reading(listOf(line(word("R2", 0.05, 0.11), word("Swing", 0.13, 0.28)),
            line(word("Incoming", 0.65, 0.79), word("call", 0.8, 0.89))))
        val candidate = RegionWatcher.candidate(reading, full, image(22).gray)
        assertEquals(2, candidate.blocks?.size)
        // Satır başındaki tuş simgesi çeviriye girmez, kutunun dışında kalır; ekranda görünür (#860).
        assertEquals(listOf("Swing", "Incoming call"), candidate.paragraphs)
        assertNull(candidate.icons)
        assertTrue(candidate.blocks!![0].box.left >= 0.11)
    }

    /**
     * "Ekranı çevir"de tuş ipucu atılmaz: etiketi kendi kutusunda çevrilir, tuş ("R2") çeviriye girmez ve ekranda özgün
     * haliyle görünür kalır (simgesi görünse de görünmese de).
     */
    @Test
    fun fullScreenTranslatesThePromptLabelAndLeavesTheButton() {
        val reading = Reading(listOf(line(word("R2", 0.05, 0.11), word("Swing", 0.13, 0.28))))
        for (picture in listOf(image(), image(22))) {
            val calls = mutableListOf<String>()
            val item = ScreenTranslation.translate(reading, TextTranslator { calls.add(it); "TR: $it" }, frame = picture.gray,
                color = picture.color).single()
            assertEquals(listOf("Swing"), calls)
            assertEquals(0.13, item.box.left, 1e-9)
            assertNull(item.icons)
        }
    }

    /** Otomatik ekran yazısı renk bilmeden satır ucundaki şekli simge saymaz (portre, harita parçası olabilir). */
    @Test
    fun monochromeNeedsColour() {
        val picture = image(listOf(179), 0x0973EA, 0xFFFFFF)
        val source = line(word("RECENTER", 0.05, 0.40), word("13", 0.45, 0.49))
        assertSame(source, ButtonIcons.markFree(source, picture.gray, null, monochrome = true))
        assertEquals("RECENTER", ButtonIcons.markFree(source, picture.gray, picture.color, monochrome = true).text)
        assertEquals("RECENTER $M", ButtonIcons.markFree(source, picture.gray, picture.color).text)
    }
}
