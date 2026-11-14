// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.demo

import org.junit.Assert.assertEquals
import org.junit.Test

class ClipClockTest {
    private var now = 10_000L
    private val clock = ClipClock({ now })

    @Test
    fun firstFrameIsShownAtOnceAndLaterFramesFollowPresentationTime() {
        assertEquals(0, clock.delayFor(0))
        assertEquals(500, clock.delayFor(500_000))
        now += 300
        assertEquals(200, clock.delayFor(500_000))
    }

    @Test
    fun lateFramesAreNotDelayed() {
        clock.delayFor(0)
        now += 2_000
        assertEquals(0, clock.delayFor(1_000_000))
    }

    @Test
    fun restartTiesNextFrameToTheClockAgain() {
        clock.delayFor(0)
        now += 60_000
        clock.restart()
        // Klip başa sarınca sunum zamanı yeniden 0'dan başlar; bekleme oluşmamalı.
        assertEquals(0, clock.delayFor(0))
        assertEquals(41, clock.delayFor(41_667))
    }

    @Test
    fun slowerSpeedStretchesWaits() {
        val slow = ClipClock({ now }, speed = 0.5)
        assertEquals(0, slow.delayFor(0))
        assertEquals(1_000, slow.delayFor(500_000))
    }
}
