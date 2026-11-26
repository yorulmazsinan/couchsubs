// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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

    /**
     * #1268 (gerçek karede "ADD MARKER"): kontur yazının zemin kümesi denizle kontur grisinin karışımı; ikisinin parlaklığı
     * aynı (125) ama rengi değil. Zemin renk sapmasıyla düz sayılmaz, yanındaki şerit de konturlu olduğundan bir şerit ötedeki
     * düz deniz zemin olur. Eskiden sapma yalnız parlaklıktan ölçülüyor, kutu grimsi çiziliyordu (Mac ve Windows ile aynı
     * görüntü).
     */
    @Test
    fun lumaFlatButColouredGroundTakesTheFarBand() {
        val width = 400
        val height = 100
        val rgb = IntArray(width * height) { index ->
            val x = index % width
            val y = index / width
            when {
                y in 30 until 70 && x % 16 < 5 -> 0xF0F0F0
                y in 20 until 80 && x % 16 in 5 until 10 -> 0x7D7D7D
                else -> 0x3A94BB
            }
        }
        val luma = ByteArray(rgb.size) { i ->
            val c = rgb[i]
            ((299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000).toByte()
        }
        val style = TextStyleSampler.sample(GrayFrame(luma, width, height), 40, 30, 360, 70, 40.0, "ADD MARKER",
            color = { x, y -> rgb[y * width + x] })!!
        fun distance(hex: String, r: Int, g: Int, b: Int): Int {
            val c = hex.removePrefix("#").toInt(16)
            return maxOf(kotlin.math.abs(((c shr 16) and 0xff) - r), kotlin.math.abs(((c shr 8) and 0xff) - g),
                kotlin.math.abs((c and 0xff) - b))
        }
        assertFalse(style.surface.flat)
        assertTrue(style.surface.background, distance(style.surface.background, 58, 148, 187) <= 8)
        assertTrue(style.surface.foreground, distance(style.surface.foreground, 240, 240, 240) <= 8)
    }

    /**
     * GTA 6 duraklatma menüsü (#1339): otomatik alan sütunun yazısından yalnız bir karo geniştir. Yanına yazmanın boş alanı
     * alanın karesinde ölçülünce en uzun satır ("Photo Studio") sağa sığmıyor, liste dağılıp satır örtülüyordu. Boş alan
     * bütün karede ölçülür: sütunun bütün satırları aynı yanda, Türkçeleri tek hizada (Mac ve Windows aynı).
     */
    @Test
    fun menuColumnIsMeasuredOnTheWholeFrame() {
        // Mavi zeminde (gri tonda 51) solda simgeli dikey menü (simge 40..52, yazı 60'tan başlar); sağı boş.
        val rows = listOf(Triple("Game", 100, 104), Triple("Store", 130, 106), Triple("Help", 160, 92),
            Triple("Photo Studio", 190, 150), Triple("Settings", 220, 122))
        val width = 640
        val height = 360
        val luma = ByteArray(width * height) { index ->
            val x = index % width
            val y = index / width
            val ink = rows.any { (_, top, right) -> y in top until top + 14 && (x in 40 until 52 || (x in 60 until right && x % 6 < 2)) }
            (if (ink) 240 else 51).toByte()
        }
        val screen = GrayFrame(luma, width, height)
        // Bulucunun alanı: sütunun karolarından solda ve sağda bir karo (640 piksellik karede karo 20 piksel).
        val region = CropRegion(80.0 / 360, 260.0 / 360, 40.0 / 640, 180.0 / 640)
        val crop = GrayFrame(ByteArray(140 * 180) { index -> luma[(80 + index / 140) * width + 40 + index % 140] }, 140, 180)
        val reading = Reading(rows.map { (text, top, right) ->
            TextLine(text, TextBox((60.0 - 40) / 140, (top - 80) / 180.0, (right - 40) / 140.0, (top + 14 - 80) / 180.0))
        })
        val candidate = RegionWatcher.styled(RegionWatcher.candidate(reading, region, crop, keepPrompts = true, auto = true),
            reading, region, crop, modes = true, kind = ScreenTextKind.MENU, screen = screen)
        val paints = candidate.blocks!!.mapNotNull { it.paint }
        assertEquals(rows.size, paints.size)
        val left = paints[0].spot!!.left
        for ((paint, row) in paints.zip(rows)) {
            assertEquals(row.first, TextPaint.MODE_BESIDE, paint.mode)
            val spot = paint.spot!!
            // Sağda, kendi satırının hizasında, ortak hizada.
            assertTrue(row.first, spot.left >= row.third / 640.0)
            assertEquals(row.first, paint.cover.top, spot.top, 1e-9)
            assertEquals(row.first, left, spot.left, 1e-9)
        }
    }

    /**
     * Kullanıcının ek alanı ve hazır alan (otomatik değil), otomatik alanla aynı çizim kipini alır (#1324): tek kutu tuş
     * simgelerini örtmez, yazı boyu özgünden ölçülür (Mac ve Windows aynı).
     */
    @Test
    fun extraAreaGetsTheAutoAreaPaintMode() {
        // Koyu zeminde solda tek satır yazı; sağı ve altı boş.
        val width = 400
        val height = 120
        val luma = ByteArray(width * height) { index ->
            val x = index % width
            val y = index / width
            (if (y in 15 until 45 && x in 20 until 200 && x % 10 < 5) 240 else 22).toByte()
        }
        val frame = GrayFrame(luma, width, height)
        val region = CropRegion(0.0, 1.0, 0.0, 1.0)
        val reading = Reading(listOf(TextLine("ROB VICKI'S BOSS", TextBox(20.0 / 400, 15.0 / 120, 200.0 / 400, 45.0 / 120))))
        val auto = RegionWatcher.styled(RegionWatcher.candidate(reading, region, frame, auto = true), reading, region, frame, modes = true)
            .blocks!!.single().paint!!
        val extra = RegionWatcher.styled(RegionWatcher.candidate(reading, region, frame, styled = true), reading, region, frame,
            modes = true).blocks!!.single().paint!!
        assertEquals(auto.mode, extra.mode)
        assertNotEquals(TextPaint.MODE_COVER, extra.mode)
        assertEquals(auto.pitch, extra.pitch, 1e-9)
    }

    /**
     * Görev/hedef satırının çevirisi altyazıdan ve öbür ekran yazılarından ayrı görünür (beta.100): özgün zemin yerine koyu
     * kehribar kutu, birebir çizim yok, başında hedef imi (Mac ve Windows aynı).
     */
    @Test
    fun missionLineHasItsOwnAmberLook() {
        val frame = image(30, 230, 2)
        val region = CropRegion(0.0, 1.0, 0.0, 1.0)
        val reading = Reading(listOf(TextLine("Lose the cops", TextBox(0.0, 0.1, 0.6, 0.9))))
        val base = RegionWatcher.candidate(reading, region, frame, auto = true)
        val other = RegionWatcher.styled(base, reading, region, frame, modes = true)
        assertEquals("#1E1E1E", other.styles!!.single()!!.surface.background)
        assertFalse(other.blocks!!.single().mission)
        val mission = RegionWatcher.styled(base, reading, region, frame, modes = true, kind = ScreenTextKind.MISSION)
        val block = mission.blocks!!.single()
        assertTrue(block.mission)
        assertEquals(null, block.paint)
        assertEquals(MissionLine.STYLE, mission.styles!!.single()!!.surface)
        val item = RegionWatcher.renderBlocks(mission, mission.blocks!!, listOf("Polislerden kurtul"), listOf(false), emptyList()).single().second
        assertEquals("\u25BA Polislerden kurtul", item.translation)
        assertEquals("#7A4E00", item.surface!!.background)
    }
}
