// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import com.couchsubs.mobile.service.LiveStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * "Oyunun kendi altyazısını açın": görüntü bir dakikadır geliyor ama tek satır yok (GitHub #503, #566, #572; Mac/iPhone
 * SubtitleOffTipTests, Windows AppControllerTests ile aynı).
 */
class SubtitleOffTipTest {
    @Test
    fun rule() {
        assertTrue(SubtitleOffTip.visible(streaming = true, sawLine = false, framesForMs = 60_000))
        assertFalse(SubtitleOffTip.visible(streaming = true, sawLine = false, framesForMs = 59_999))
        assertFalse(SubtitleOffTip.visible(streaming = true, sawLine = true, framesForMs = 600_000))
        assertFalse(SubtitleOffTip.visible(streaming = false, sawLine = false, framesForMs = 600_000))
        assertFalse(SubtitleOffTip.visible(streaming = true, sawLine = false, framesForMs = null))
    }

    @Test
    fun clockStartsAtFirstFramesAndResetsWhenNotStreaming() {
        assertNull(SubtitleOffTip.framesSince(null, streaming = true, framesBefore = 0, framesNow = 0, now = 1_000))
        assertEquals(1_000L, SubtitleOffTip.framesSince(null, streaming = true, framesBefore = 0, framesNow = 20, now = 1_000))
        assertEquals(1_000L, SubtitleOffTip.framesSince(1_000, streaming = true, framesBefore = 20, framesNow = 40, now = 3_000))
        assertNull(SubtitleOffTip.framesSince(1_000, streaming = false, framesBefore = 40, framesNow = 40, now = 5_000))
        // Yeniden bağlanınca yeni oturumun sayacı sıfırdan başlar.
        assertEquals(9_000L, SubtitleOffTip.framesSince(null, streaming = true, framesBefore = 5_000, framesNow = 30, now = 9_000))
    }

    @Test
    fun liveStatusShowsTheTipAfterAMinuteAndHidesItAtTheFirstLine() {
        var status = LiveStatus(running = true).withStreaming(true)
        status = status.withFrames(20, 0)
        status = status.withFrames(600, 59_000)
        assertFalse(status.subtitleOffTip)
        status = status.withFrames(620, 61_000)
        assertTrue(status.subtitleOffTip)
        status = status.withStreaming(false)
        assertFalse(status.subtitleOffTip)
        assertNull(status.framesSince)
    }

    @Test
    fun demoNeverShowsTheTip() {
        var status = LiveStatus(running = true, demo = true).withStreaming(true)
        status = status.withFrames(20, 0).withFrames(600, 120_000)
        assertFalse(status.subtitleOffTip)
    }

    @Test
    fun aShownLineKeepsTheTipHidden() {
        var status = LiveStatus(running = true, shownLines = 1).withStreaming(true)
        status = status.withFrames(20, 0).withFrames(600, 120_000)
        assertFalse(status.subtitleOffTip)
    }
}
