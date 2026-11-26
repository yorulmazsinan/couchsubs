// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Aşama süreleri satırı (Mac/iPhone StageTimingTests, Windows StageTimingTests ile aynı durumlar). */
class StageTimingTest {
    @Test fun reportsOncePerPeriodAndResets() {
        val timing = StageTiming(30_000)
        assertNull(timing.report(0))
        timing.add("okuma", 80_000_000)
        timing.add("okuma", 140_250_000)
        timing.add("çizim", 30_040_000)
        assertNull(timing.report(29_999))
        assertEquals("aşama süreleri (30 sn): okuma 2× ort 110,1 en çok 140,3 ms; çizim 1× ort 30,0 en çok 30,0 ms",
            timing.report(30_000))
        // Sıfırlandı: yeni ölçüm yoksa satır yok.
        assertNull(timing.report(60_000))
        timing.add("tur", 5_000_000)
        assertNull(timing.report(60_001))
        assertEquals("aşama süreleri (30 sn): tur 1× ort 5,0 en çok 5,0 ms", timing.report(90_000))
    }

    @Test fun clockGoingBackReportsAndRestarts() {
        val timing = StageTiming(30_000)
        timing.report(100_000)
        timing.add("tur", 1_000_000)
        assertEquals("aşama süreleri (0 sn): tur 1× ort 1,0 en çok 1,0 ms", timing.report(50))
    }

    /** Erken duran sayım saf sayımla aynı sonucu verir (bütün kare ölçümü hızlandı, sonuç değişmedi). */
    @Test fun earlyStopCountsMatchFullCounts() {
        val random = java.util.Random(7)
        repeat(4000) {
            val from = random.nextInt(20)
            val until = from + random.nextInt(140)
            val step = 1 + random.nextInt(5)
            val share = listOf(0.1, 0.5, 0.7, 0.03)[random.nextInt(4)]
            val density = random.nextDouble()
            val cells = (0 until 200).map { random.nextDouble() < density }
            var n = 0
            var ok = 0
            var at = from
            while (at < until) {
                n++
                if (cells[at]) ok++
                at += step
            }
            assertEquals(n > 0 && ok >= share * n, TextPainter.shareAtLeast(from, until, step, share) { cells[it] })
            val free = (0 until 200).map { if (random.nextDouble() < 0.02) null else random.nextDouble() < density * 0.2 }
            val list = (from until until).map { free[it] }
            val open = list.isNotEmpty() && list.none { it == null } && list.count { it == true } < TextPainter.BESIDE_SHARE * list.size
            assertEquals(open, TextPainter.roomOpen(from, until) { free[it] })
        }
        assertFalse(TextPainter.shareAtLeast(5, 5, 1, 0.5) { true })
        assertTrue(TextPainter.roomOpen(0, 3) { false })
    }
}
