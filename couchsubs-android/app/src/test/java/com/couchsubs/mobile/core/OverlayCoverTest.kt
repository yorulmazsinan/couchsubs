// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Altyazı kutusunun opaklığı ve ayar ekranındaki "Koyuluk" notu. Ortak vakalar fixtures/box-opacity.json (Mac
 * OverlayCoverTests, Windows OverlayPlacementTests aynı). İki kullanıcı (X ve Google Play, beta.107) "zemin koyuluğu
 * ayarlanamıyor" dedi: "Örtsün"de en yeni satır her koyulukta opak kalır (İngilizce görünmesin), not bunu söyler.
 */
class OverlayCoverTest {
    private val fixture = JSONObject(Fixtures.text("box-opacity.json"))

    @Test
    fun sharedBoxOpacityCases() {
        val cases = fixture.getJSONArray("opacity")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val item = cases.getJSONObject(i)
            val actual = OverlayCover.boxOpacity(item.getInt("background"), item.getBoolean("covering"), item.getBoolean("current"))
            assertEquals(item.toString(), item.getDouble("opacity"), actual, 1e-9)
        }
    }

    @Test
    fun darknessNoteOnlyInCoverWithABackground() {
        val cases = fixture.getJSONArray("note")
        for (i in 0 until cases.length()) {
            val item = cases.getJSONObject(i)
            val placement = SubtitlePlacement.valueOf(item.getString("placement").uppercase())
            assertEquals(item.toString(), item.getBoolean("shown"), OverlayCover.darknessFixedByCover(placement, item.getInt("background")))
        }
    }
}
