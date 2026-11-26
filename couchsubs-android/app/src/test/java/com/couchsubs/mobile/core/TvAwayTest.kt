// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #1303: arka plandayken TV bağlantısı koptuysa "CouchSubs'ı açık tutun" uyarısı (Mac/iPhone TVAwayTests ile aynı durumlar). */
class TvAwayTest {
    @Test
    fun linkLostWhileAwayWarnsOncePerTrip() {
        val away = TvAway()
        away.left(linked = true)
        assertTrue(away.lost(10.0))
        assertFalse(away.lost(20.0))
        assertFalse(away.returned(30.0, linked = false))
        away.left(linked = true)
        assertTrue(away.lost(40.0))
    }

    @Test
    fun tvMissingOnReturnWarns() {
        val away = TvAway()
        away.left(linked = true)
        assertTrue(away.returned(100.0, linked = false))
    }

    @Test
    fun lossRightAfterReturnCountsAsAway() {
        val away = TvAway()
        away.left(linked = true)
        assertFalse(away.returned(100.0, linked = true))
        assertTrue(away.lost(103.0))
    }

    @Test
    fun lossLongAfterReturnIsNotAboutTheBackground() {
        val away = TvAway()
        away.left(linked = true)
        assertFalse(away.returned(100.0, linked = true))
        assertFalse(away.lost(100.0 + TvAway.DEFAULT_GRACE + 1))
    }

    @Test
    fun noWarningWhileTheAppIsOnScreenOrTheTvWasNotLinked() {
        val away = TvAway()
        assertFalse(away.lost(1.0))
        away.left(linked = false)
        assertFalse(away.returned(5.0, linked = false))
        assertFalse(away.lost(6.0))
    }

    @Test
    fun resetForgetsTheTrip() {
        val away = TvAway()
        away.left(linked = true)
        away.reset()
        assertFalse(away.returned(5.0, linked = false))
        assertFalse(away.away)
    }
}
