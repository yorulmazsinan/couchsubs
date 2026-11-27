// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.File
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Sinan Bey: #1300/#1320'den beri menü, görev kartı ve istem Türkçesi yanına ya da ikiz kutuya yazılıyordu; yer her okumada
 * boş alana göre yeniden seçildiği için ekranda kararlı durmuyordu. Varsayılan yine yerinde örtme: Türkçe özgün yazının
 * kendi dikdörtgenine, o kutunun ölçülen zemin renginde çizilir; simge ve kişi resmi örtülmez. Yanına yazma yalnız
 * "Menülerde Türkçeyi yanına yaz" açıkken ([RegionWatcher.writesBeside]). Gerçek GTA 6 menü/görev kartı kareleri
 * (testdata/frames, kayıtlı okumalar ocr/screen). Mac/iPhone (CoverInPlaceTests.swift) ve Windows (CoverInPlaceTests.cs) aynı.
 */
class CoverInPlaceTest {
    private val directory: File = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .first { File(it, "frames.json").isFile }

    private class Picture(val gray: GrayFrame, val color: (Int, Int) -> Int, val rgb: IntArray, val width: Int, val height: Int)

    private fun picture(rgb: IntArray, width: Int, height: Int): Picture {
        val luma = ByteArray(rgb.size) { i ->
            val c = rgb[i]
            ((299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000).toByte()
        }
        return Picture(GrayFrame(luma, width, height), { x, y -> rgb[y * width + x] }, rgb, width, height)
    }

    /** Kareyi masaüstü JDK'nın ImageIO'suyla okur (ScreenFramesTest gibi). */
    private fun load(file: File): Picture {
        val buffered = Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java).invoke(null, file)
        val type = buffered.javaClass
        val width = type.getMethod("getWidth").invoke(buffered) as Int
        val height = type.getMethod("getHeight").invoke(buffered) as Int
        val rgb = type.getMethod("getRGB", Int::class.java, Int::class.java, Int::class.java, Int::class.java, IntArray::class.java,
            Int::class.java, Int::class.java).invoke(buffered, 0, 0, width, height, null, 0, width) as IntArray
        for (i in rgb.indices) rgb[i] = rgb[i] and 0xFFFFFF
        return picture(rgb, width, height)
    }

    private fun crop(source: Picture, region: CropRegion): Picture {
        val x0 = floor(source.width * region.left).toInt().coerceIn(0, source.width)
        val x1 = ceil(source.width * region.right).toInt().coerceIn(0, source.width)
        val y0 = floor(source.height * region.top).toInt().coerceIn(0, source.height)
        val y1 = ceil(source.height * region.bottom).toInt().coerceIn(0, source.height)
        val width = x1 - x0
        val height = y1 - y0
        return picture(IntArray(width * height) { i -> source.rgb[(y0 + i / width) * source.width + x0 + i % width] }, width, height)
    }

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    private fun reading(lines: JSONArray) = Reading((0 until lines.length()).map { i ->
        val line = lines.getJSONObject(i)
        val words = line.optJSONArray("words")?.let { list ->
            (0 until list.length()).map { k -> TextWord(list.getJSONObject(k).getString("text"), box(list.getJSONObject(k).getJSONArray("box"))) }
        }
        TextLine(line.getString("text"), line.optJSONArray("box")?.let(::box), words = words,
            confidence = if (line.has("confidence")) line.getDouble("confidence").toFloat() else null)
    })

    private class Shot(val id: String, val image: Picture, val clear: List<TextBox>, val areas: List<Pair<ExtraArea, Reading>>)

    private fun shots(): List<Shot> {
        val frames = JSONObject(File(directory, "frames.json").readText()).getJSONArray("frames")
        return (0 until frames.length()).mapNotNull { i ->
            val frame = frames.getJSONObject(i)
            val screen = frame.optJSONObject("screen") ?: return@mapNotNull null
            val id = frame.getString("id")
            val fixture = JSONObject(File(directory, "ocr/screen/$id.json").readText())
            val clear = screen.optJSONArray("clear")?.let { list -> (0 until list.length()).map { box(list.getJSONArray(it)) } } ?: emptyList()
            val areas = fixture.getJSONArray("areas").let { list ->
                (0 until list.length()).map { list.getJSONObject(it) }.filter { it.getJSONArray("lines").length() > 0 }.map { area ->
                    val r = area.getJSONArray("region")
                    ExtraArea(id = area.getString("id"), name = area.getString("id"),
                        region = CropRegion(r.getDouble(1), r.getDouble(3), r.getDouble(0), r.getDouble(2)), auto = true,
                        menu = area.optBoolean("menu", false)) to reading(area.getJSONArray("lines"))
                }
            }
            Shot(id, load(File(directory, frame.getString("file"))), clear, areas)
        }
    }

    private class Recorder : RegionSender {
        val current = mutableMapOf<String, List<ScreenTranslation.Item>>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) = sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?, blocks: List<ScreenTranslation.Item>?,
        ) {
            if (text.isEmpty()) current.remove(id) else current[id] = blocks ?: emptyList()
        }
        override fun clearRegions() = current.clear()
    }

    /** Alanları üç tur okur (kararlı okuma); çizilen öğeler. */
    private fun drawn(shot: Shot, beside: Boolean): List<ScreenTranslation.Item> {
        val recorder = Recorder()
        val readings = shot.areas.associate { (area, reading) -> area.id to reading }
        var time = 0L
        val watcher = RegionWatcher({ readings[it.pixels as String] ?: Reading.Empty }, { "çeviri: $it" }, recorder, clock = { time })
        watcher.writesBeside = beside
        val offered = shot.areas.map { (area, _) ->
            val part = crop(shot.image, area.region)
            area to RegionWatcher.Crop(area.id, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { 1 }, part.gray, part.color,
                shot.image.gray, shot.image.color)
        }
        repeat(3) {
            watcher.pass(shot.areas.map { it.first.id }.toSet(), offered)
            time += RegionWatcher.DEFAULT_INTERVAL_MS
        }
        return shot.areas.flatMap { recorder.current[it.first.id] ?: emptyList() }
    }

    private fun intersects(a: TextBox, b: TextBox) =
        minOf(a.right, b.right) > maxOf(a.left, b.left) + 1.0 / 1920 && minOf(a.bottom, b.bottom) > maxOf(a.top, b.top) + 1.0 / 1080

    @Test
    fun menusCardsAndPromptsAreCoveredInPlaceByDefault() {
        val shots = shots()
        assertEquals(3, shots.size)
        for (shot in shots) {
            val first = drawn(shot, false)
            val second = drawn(shot, false)
            assertEquals(shot.id, first.map { it.paint }, second.map { it.paint })
            val painted = first.mapNotNull { item -> item.paint?.let { item to it } }
            assertTrue(shot.id, painted.size > 3)
            for ((item, paint) in painted) {
                assertEquals(shot.id, TextPaint.MODE_COVER, paint.mode)
                assertNull(shot.id, paint.twin)
                assertNull(shot.id, paint.spot)
                assertTrue(shot.id, paint.background.startsWith("#"))
                val line = maxOf(1e-6, item.lineHeight)
                assertTrue(shot.id, abs(paint.cover.top - item.box.top) / line <= 0.5)
                assertTrue(shot.id, abs(paint.cover.bottom - item.box.bottom) / line <= 0.5)
                for (zone in shot.clear) assertFalse("${shot.id}: $zone", intersects(paint.cover, zone))
            }
        }
    }

    @Test
    fun besideStaysAvailableAsAnOption() {
        val modes = shots().flatMap { drawn(it, true) }.mapNotNull { it.paint?.mode }
        assertTrue("$modes", modes.any { it != TextPaint.MODE_COVER })
    }

    @Test
    fun onlyUiKindsAreCoveredScenesKeepTheirKind() {
        assertNull(RegionWatcher.inPlaceKind(ScreenTextKind.MENU, false))
        assertNull(RegionWatcher.inPlaceKind(ScreenTextKind.MISSION, false))
        assertNull(RegionWatcher.inPlaceKind(ScreenTextKind.HELP, false))
        assertEquals(ScreenTextKind.OTHER, RegionWatcher.inPlaceKind(ScreenTextKind.OTHER, false))
        assertEquals(ScreenTextKind.MENU, RegionWatcher.inPlaceKind(ScreenTextKind.MENU, true))
        val twin = TextPaint("#203040", 0.03, TextBox(0.1, 0.1, 0.3, 0.13), mode = TextPaint.MODE_TWIN,
            twin = TextBox(0.4, 0.1, 0.6, 0.2), spot = TextBox(0.41, 0.11, 0.59, 0.14))
        val covered = RegionWatcher.coveredInPlace(twin)
        assertEquals(TextPaint.MODE_COVER, covered.mode)
        assertEquals(twin.cover, covered.cover)
        assertEquals("#203040", covered.background)
        assertNull(covered.twin)
        assertNull(covered.spot)
    }
}
