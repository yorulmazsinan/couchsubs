// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1251: telefon ekranda görünürken otomatik okumadan hiç satır gelmiyordu ve günlük de sessizdi. Telefonun açılıp
 * kapanması ve oynadığı için açılmaması artık sınırlı satırlarla günlüğe yazılır (Windows ve Mac/iPhone ile aynı metinler).
 */
class PhoneTraceTest {
    /** #1334: telefon indirilince çevirisi süreyle (~1 sn) kalkar; örnekler seyrek gelse de ıska sayısı beklenmez. */
    @Test
    fun closedPhoneLeavesWithinASecondEvenWhenSamplesAreSparse() {
        val image = TestPhoneImage.phone()
        var found = true
        val pose = GamePhoneGeometry.Pose(0.45, 0.15, 0.45, 0.83)
        fun tracker() = GamePhoneTracker { if (found) pose else null }

        // Olağan aralık (330 ms): üçüncü ıskada, son görülmeden ~1 sn sonra kapanır (önceden dördüncüde, ~1,3 sn).
        var t = tracker()
        found = true
        assertEquals(null, t.sample(image, 0).pose)
        assertTrue(t.sample(image, 330).pose != null)
        found = false
        assertTrue(t.sample(image, 660).pose != null)
        assertTrue(t.sample(image, 990).pose != null)
        assertEquals(null, t.sample(image, 1320).pose)

        // Seyrek örnekler (1 sn arayla): tek ıska kapatmaz, ikinci ıskada kapanır (önceden dördüncüde, ~4 sn).
        t = tracker()
        found = true
        t.sample(image, 0)
        assertTrue(t.sample(image, 1000).pose != null)
        found = false
        assertTrue(t.sample(image, 2000).pose != null)
        found = true
        assertTrue(t.sample(image, 3000).pose != null)
        found = false
        assertTrue(t.sample(image, 4000).pose != null)
        assertEquals(null, t.sample(image, 5000).pose)

        // Akış takıldı, telefon iki kat süre hiç görülmedi: tek ıska yeter.
        t = tracker()
        found = true
        t.sample(image, 0)
        assertTrue(t.sample(image, 330).pose != null)
        found = false
        assertEquals(null, t.sample(image, 330 + 2 * GamePhoneTracker.MISS_GRACE_MS).pose)

        assertTrue(!GamePhoneTracker.closes(1, 1200))
        assertTrue(GamePhoneTracker.closes(4, 0))
    }

    @Test
    fun trackerLogsOpeningClosingAndAMovingPhoneOncePerMinute() {
        val log = mutableListOf<String>()
        var top = 0.15
        var found = true
        val image = TestPhoneImage.phone()
        val tracker = GamePhoneTracker { if (found) GamePhoneGeometry.Pose(0.45, top, 0.45, top + 0.68) else null }
        tracker.onLog = { log.add(it) }
        var time = 0L
        fun sample() { time += 400; tracker.sample(image, time) }

        sample()
        sample()
        assertEquals(listOf("düşen satır [PhoneTrace] telefon açıldı: \"\""), log)
        found = false
        repeat(3) { sample() }
        assertEquals("düşen satır [PhoneTrace] telefon kapandı (1200 ms görülmedi, 3 ıska): \"\"", log.last())

        // Elde sallanan telefon: her örnekte %10 kayıyor, iki uyumlu gözlem olmadığı için hiç açılmıyor.
        log.clear()
        found = true
        repeat(6) {
            top = if (top == 0.15) 0.25 else 0.15
            sample()
        }
        assertEquals(1, log.size)
        assertTrue(log[0], log[0].startsWith("düşen satır [PhoneTrace] telefon oynuyor, açılmadı (%10 oynama)"))
        time += DropLog.REPEAT_MS
        top = if (top == 0.15) 0.25 else 0.15
        sample()
        assertEquals(2, log.size)
    }

    @Test
    fun shiftIsTheLargestEdgeMove() {
        assertEquals(0.07, PhoneTrace.shift(CropRegion(0.1, 0.8, 0.3, 0.6), CropRegion(0.12, 0.8, 0.37, 0.6)), 1e-9)
        assertEquals(7, PhoneTrace.percent(0.07))
    }
}
