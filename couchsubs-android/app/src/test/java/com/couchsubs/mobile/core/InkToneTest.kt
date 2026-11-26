// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Açık zemindeki koyu yazı (kâğıt ilan) altyazı sayılmaz (GitHub #1124). Örnekler ortak deneme dosyasından
 * (fixtures/dark-ink.json, core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac InkToneTests.swift ve Windows
 * InkToneTests.cs aynı dosyayı okur).
 */
class InkToneTest {
    private val root = JSONObject(Fixtures.text("dark-ink.json"))

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    private fun render(image: JSONObject): IntArray {
        val width = image.getInt("width")
        val height = image.getInt("height")
        val pixels = IntArray(width * height) { image.getInt("fill") }
        val rects = image.getJSONArray("rects")
        for (i in 0 until rects.length()) {
            val r = rects.getJSONArray(i)
            for (y in maxOf(0, r.getInt(1)) until minOf(height, r.getInt(3))) {
                for (x in maxOf(0, r.getInt(0)) until minOf(width, r.getInt(2))) pixels[y * width + x] = r.getInt(4)
            }
        }
        return pixels
    }

    @Test
    fun pixels() {
        val images = root.getJSONArray("images")
        for (i in 0 until images.length()) {
            val image = images.getJSONObject(i)
            val width = image.getInt("width")
            val pixels = render(image)
            val dark = InkTone.isDarkOnLight(box(image.getJSONArray("box")), width, image.getInt("height")) { x, y -> pixels[y * width + x] }
            assertEquals(image.getString("name"), image.getBoolean("dark"), dark)
        }
    }

    /** Aynı denetim NV21 parlaklık düzleminden (altyazı hattının yolu; sınırlı aralık 16–235). */
    @Test
    fun samplerReadsLimitedRangeLuma() {
        val images = root.getJSONArray("images")
        for (i in 0 until images.length()) {
            val image = images.getJSONObject(i)
            val pixels = render(image)
            val luma = ByteArray(pixels.size) { (16 + (pixels[it] * 219 + 127) / 255).toByte() }
            val frame = GrayFrame(luma, image.getInt("width"), image.getInt("height"))
            assertEquals(image.getString("name"), image.getBoolean("dark"), InkTone.sampler(frame)(box(image.getJSONArray("box"))))
        }
    }

    @Test
    fun blocks() {
        val area = box(root.getJSONArray("area"))
        val blocks = root.getJSONArray("blocks")
        for (i in 0 until blocks.length()) {
            val vector = blocks.getJSONObject(i)
            val name = vector.getString("name")
            val lines = vector.getJSONArray("lines")
            val reading = Reading((0 until lines.length()).map { TextLine(lines.getJSONObject(it).getString("text"), box(lines.getJSONObject(it).getJSONArray("box"))) })
            val dark = (0 until lines.length()).map { lines.getJSONObject(it) }.filter { it.optBoolean("dark", false) }.map { box(it.getJSONArray("box")) }
            val reasons = mutableListOf<String>()
            val block = reading.subtitleBlock(area, darkInk = { it in dark }) { _, reason -> reasons += reason }
            val subtitle = vector.getString("subtitle")
            assertEquals(name, subtitle, block.text)
            if (subtitle.isEmpty()) assertEquals(name, listOf(InkTone.REASON), reasons)
            // Renk verilmezse koyu yazı kuralı çalışmaz.
            assertNotEquals(name, "", reading.subtitleBlock(area).text)
        }
    }

    @Test
    fun gameStyle() {
        val area = box(root.getJSONArray("area"))
        val style = root.getJSONArray("style")
        for (i in 0 until style.length()) {
            val vector = style.getJSONObject(i)
            val name = vector.getString("name")
            val lightInk = vector.optBoolean("lightInk", false)
            fun run(knownLight: Boolean): DarkInkStyle {
                val style = DarkInkStyle().apply { this.lightInk = knownLight }
                val blocks = vector.getJSONArray("blocks")
                for (j in 0 until blocks.length()) {
                    val block = blocks.getJSONObject(j)
                    val b = box(block.getJSONArray("box"))
                    style.observe(Reading(block.getString("text").split("\n").map { TextLine(it, b) }), area)
                }
                return style
            }
            val seen = run(lightInk)
            assertEquals(name, vector.getBoolean("gameStyle"), seen.isGameStyle)
            seen.reset()
            assertFalse(name, seen.isGameStyle)
            // Açık yazılı oyunda kuralı kapatmayan bloklar başka oyunda kapatır (vektör anlamlı).
            if (lightInk) assertTrue(name, run(false).isGameStyle)
        }
    }
}
