// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Gerçek kare gerileme seti (testdata/frames, scripts/regression-frames.sh): ML Kit JVM testinde çalışmadığı için
 * karelerin Mac'te Apple Vision ile kaydedilmiş okumaları (testdata/frames/ocr) Android'in altyazı seçiminden geçer:
 * oturum oturum, sırayla; düğme ipuçları ve okuma çöpü atılır, satırlar birleşir, altyazı bloğu seçilir, altyazının yeri
 * öğrenilir ([SubtitleBand]). Seçilen blok Mac'in seçtiğiyle (ocr/selection.json) aynı olmalı (Mac FrameReplayTests,
 * Windows FrameReplayTests aynı dosyaları okur).
 */
class FrameReplayTest {
    private val directory: File = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .first { File(it, "frames.json").isFile }

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    private fun reading(lines: JSONArray) = Reading((0 until lines.length()).map { i ->
        val line = lines.getJSONObject(i)
        val words = line.optJSONArray("words")?.let { list ->
            (0 until list.length()).map { k -> TextWord(list.getJSONObject(k).getString("text"), box(list.getJSONObject(k).getJSONArray("box"))) }
        }
        TextLine(line.getString("text"), line.optJSONArray("box")?.let(::box), words = words,
            confidence = if (line.has("confidence")) line.getDouble("confidence").toFloat() else null)
    })

    @Test
    fun selectionMatchesMacOnRealFrames() {
        val frames = JSONObject(File(directory, "frames.json").readText()).getJSONArray("frames")
        val expected = JSONObject(File(directory, "ocr/selection.json").readText())
        val bands = mutableMapOf<String, SubtitleBand>()
        assertTrue(frames.length() >= 40)
        assertEquals(frames.length(), expected.length())
        for (i in 0 until frames.length()) {
            val frame = frames.getJSONObject(i)
            val id = frame.getString("id")
            val fixture = JSONObject(File(directory, "ocr/$id.json").readText())
            val area = box(fixture.getJSONArray("region"))
            val band = bands.getOrPut(frame.optString("session", id).ifEmpty { id }) { SubtitleBand() }
            var lines = reading(fixture.getJSONArray("lines"))
            fixture.optJSONArray("phone")?.let { p ->
                // Altyazı hattı gibi: telefonun ekranındaki satırlar okunmaz (SubtitlePipeline.process phone).
                val handset = ScreenPhoneCard.Handset(
                    GamePhoneGeometry.Pose(p.getDouble(0), p.getDouble(1), p.getDouble(2), p.getDouble(3)), p.getDouble(4))
                lines = Reading(lines.lines.filter { line -> line.box?.let { !ScreenPhoneCard.holds(it.placedIn(area), handset) } ?: true })
            }
            val block = lines.withoutButtonPrompts().withoutOcrNoise().joiningRows().subtitleBlock(area, band)
            band.record(block, area)
            assertEquals(id, expected.getString(id), block.text)
        }
    }
}
