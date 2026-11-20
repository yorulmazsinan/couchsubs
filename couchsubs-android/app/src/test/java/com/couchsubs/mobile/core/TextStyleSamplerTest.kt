// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Otomatik ekran yazısının özgün stili: sentetik görüntüler (Windows TextStyleSamplerTests ile aynı durumlar). */
class TextStyleSamplerTest {
    /** [ground] zeminde [ink] renkli yatay çizgiler: her 10 satırın [thick] kadarı yazı, sütunların 3/4'ü. */
    private fun image(ground: Int, ink: Int, thick: Int, width: Int = 200, height: Int = 40): GrayFrame {
        val luma = ByteArray(width * height) { index ->
            val x = index % width
            val y = index / width
            (if (y % 10 < thick && x % 4 != 0) ink else ground).toByte()
        }
        return GrayFrame(luma, width, height)
    }

    @Test
    fun lightTextOnDarkFlatBox() {
        val style = TextStyleSampler.sample(image(30, 230, 2), 0, 0, 200, 40, 10.0, "Go to the Saloon.")
        assertNotNull(style)
        assertEquals("#E6E6E6", style!!.surface.foreground)
        assertEquals("#1E1E1E", style.surface.background)
        assertTrue(style.surface.flat)
        assertFalse(style.look.bold)
        assertFalse(style.look.upper)
    }

    @Test
    fun darkTextOnLightBox() {
        val style = TextStyleSampler.sample(image(220, 20, 2), 0, 0, 200, 40, 10.0, "Photo Studio")!!
        assertEquals("#141414", style.surface.foreground)
        assertEquals("#DCDCDC", style.surface.background)
    }

    @Test
    fun boldUpperCaseHeading() {
        // Kalın yazı: pikselin ~%37'si mürekkep; dar başlık: 30 karakter 200 px'e (harf başına 6,7 px, satır 20 px).
        val style = TextStyleSampler.sample(image(30, 230, 5), 0, 0, 200, 40, 20.0, "ROB VICKI'S BOSS AND HIS CREW!")!!
        assertTrue(style.look.bold)
        assertTrue(style.look.upper)
        assertTrue(style.look.condensed)
    }

    @Test
    fun turkishUpperCase() {
        assertEquals("VİCKİ'NİN PATRONUNU SOY", TextStyleSampler.upper("vicki'nin patronunu soy"))
        assertEquals("ISIK", TextStyleSampler.upper("ışık").replace('Ş', 'S'))
        assertTrue(TextStyleSampler.isUpper("ROB VICKI'S BOSS"))
        assertFalse(TextStyleSampler.isUpper("Photo Studio"))
    }

    @Test
    fun alignmentFromLineEdges() {
        assertEquals("left", TextStyleSampler.align(listOf(0.1 to 0.5, 0.1 to 0.3)))
        assertEquals("right", TextStyleSampler.align(listOf(0.2 to 0.6, 0.4 to 0.6)))
        assertEquals("center", TextStyleSampler.align(listOf(0.2 to 0.6, 0.3 to 0.5)))
    }

    @Test
    fun noisyGroundIsNotFlat() {
        val width = 200
        val height = 40
        val luma = ByteArray(width * height) { index ->
            val x = index % width
            val y = index / width
            (if (y % 10 < 2 && x % 4 != 0) 240 else 20 + (x * 7 + y * 13) % 80).toByte()
        }
        val style = TextStyleSampler.sample(GrayFrame(luma, width, height), 0, 0, width, height, 10.0, "Go to the Saloon.")!!
        assertFalse(style.surface.flat)
    }
}
