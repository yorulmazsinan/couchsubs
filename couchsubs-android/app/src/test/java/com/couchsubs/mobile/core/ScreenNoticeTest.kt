// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kullanıcı bildirimi (X, iki kişi, GTA 6): "Tam ekran" altyazı alanında sağ altta beliren mesaj önizlemesinin ve solda
 * kayarak giren bildirimin çevirisi ekranın ortasına geliyordu. Örnekler ortak deneme dosyasından (fixtures/screen-notice.json,
 * core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac ScreenNoticeTests.swift ve Windows ScreenNoticeTests.cs aynı dosyayı okur).
 */
class ScreenNoticeTest {
    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    private fun reading(array: JSONArray) = Reading((0 until array.length()).map { j ->
        val line = array.getJSONObject(j)
        TextLine(line.getString("text"), box(line.getJSONArray("box")))
    })

    @Test
    fun sharedVectors() {
        val cases = JSONObject(Fixtures.text("screen-notice.json")).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val area = box(case.getJSONArray("area"))
            val notices = ScreenNotices()
            val frames = case.getJSONArray("frames")
            for (f in 0 until frames.length()) {
                val frame = frames.getJSONObject(f)
                val at = frame.getLong("at")
                val edge = mutableListOf<Reading>()
                val block = reading(frame.getJSONArray("lines")).subtitleBlock(area, notices = { b ->
                    edge.add(Reading(b.lines.map { it.copy(box = it.box?.placedIn(area)) }))
                })
                assertEquals("$name @$at", frame.getString("subtitle"), block.text)
                notices.observe(edge, at)
                val expected = frame.getJSONArray("areas")
                assertEquals("$name @$at", (0 until expected.length()).map { expected.getJSONObject(it).getString("id") },
                    notices.areas.map { it.id })
                for ((k, got) in notices.areas.withIndex()) {
                    val r = expected.getJSONObject(k).getJSONArray("region")
                    assertEquals(r.getDouble(0), got.region.left, 1e-6)
                    assertEquals(r.getDouble(1), got.region.top, 1e-6)
                    assertEquals(r.getDouble(2), got.region.right, 1e-6)
                    assertEquals(r.getDouble(3), got.region.bottom, 1e-6)
                    assertTrue(got.auto)
                    // Bölge asla ekranın ortasını kaplamaz.
                    assertFalse(got.region.left < 0.5 && got.region.right > 0.5)
                }
            }
        }
    }

    @Test
    fun rules() {
        assertTrue(ScreenNotices.isWholeScreen(TextBox(0.0, 0.0, 1.0, 1.0)))
        assertFalse(ScreenNotices.isWholeScreen(TextBox(0.14, 0.62, 0.86, 0.97)))
        assertTrue(ScreenNotices.isNotice(TextBox(0.74, 0.86, 0.97, 0.92)))
        assertTrue(ScreenNotices.isNotice(TextBox(0.02, 0.4, 0.28, 0.43)))
        // Ortadan geçen ya da ortaya yakın blok bildirim değildir; sıfır alanlı kutu da.
        assertFalse(ScreenNotices.isNotice(TextBox(0.3, 0.8, 0.7, 0.84)))
        assertFalse(ScreenNotices.isNotice(TextBox(0.55, 0.8, 0.62, 0.84)))
        assertFalse(ScreenNotices.isNotice(TextBox(0.8, 0.8, 0.8, 0.84)))
        assertTrue(ScreenNotices.isNotice("auto-notice-3"))
        assertFalse(ScreenNotices.isNotice("auto-3"))
    }
}
