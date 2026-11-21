// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * İlk kareden sonra Xbox görüntüsü kesilince uyarı ve yeniden kurma. Sahte saat: anlar ms olarak verilir.
 * CouchSubsCore XboxPictureWatchTests ve Windows'taki XboxPictureWatchTests ile aynı durumlar.
 */
class XboxPictureWatchTest {
    private val fine = XboxPictureVerdict.Fine

    @Test fun nothingIsDecidedBeforeTheFirstFrame() {
        val watch = XboxPictureWatch()
        watch.iceChanged(XboxPictureWatch.Ice.DISCONNECTED, 0)
        assertEquals(fine, watch.tick(60_000))
    }

    @Test fun flowingPictureIsFine() {
        val watch = XboxPictureWatch()
        for (second in 0L until 120L) {
            watch.frameArrived(second * 1000)
            assertEquals(fine, watch.tick(second * 1000 + 500))
        }
    }

    @Test fun warnsOnceThenReconnectsWhenFramesStopWhileTheConnectionLooksOpen() {
        val watch = XboxPictureWatch()
        watch.frameArrived(10_000)
        assertEquals(fine, watch.tick(14_000))
        assertEquals(XboxPictureVerdict.Warn, watch.tick(15_000))
        assertTrue(watch.warned)
        assertEquals(fine, watch.tick(16_000))
        assertEquals(fine, watch.tick(21_000))
        assertEquals(XboxPictureVerdict.Stalled("Xbox'tan 12 sn'dir görüntü gelmiyor (bağlantı açık görünüyor)"), watch.tick(22_000))
    }

    @Test fun recoversWhenFramesComeBackBeforeTheLimit() {
        val watch = XboxPictureWatch()
        watch.frameArrived(0)
        assertEquals(XboxPictureVerdict.Warn, watch.tick(6000))
        watch.frameArrived(8000)
        assertEquals(XboxPictureVerdict.Recovered, watch.tick(8500))
        assertFalse(watch.warned)
        assertEquals(fine, watch.tick(9500))
    }

    @Test fun iceDisconnectedWarnsAfterOneSecondWithoutFrames() {
        val watch = XboxPictureWatch()
        watch.frameArrived(0)
        watch.iceChanged(XboxPictureWatch.Ice.DISCONNECTED, 200)
        assertEquals(fine, watch.tick(500))
        assertEquals(XboxPictureVerdict.Warn, watch.tick(1200))
        watch.iceChanged(XboxPictureWatch.Ice.CONNECTED, 3000)
        watch.frameArrived(3100)
        assertEquals(XboxPictureVerdict.Recovered, watch.tick(3500))
    }

    @Test fun iceStuckInDisconnectedEndsTheSessionAtTheLimit() {
        val watch = XboxPictureWatch()
        watch.frameArrived(0)
        watch.iceChanged(XboxPictureWatch.Ice.DISCONNECTED, 100)
        assertEquals(XboxPictureVerdict.Warn, watch.tick(1000))
        assertEquals(XboxPictureVerdict.Stalled("Xbox'tan 12 sn'dir görüntü gelmiyor (ICE disconnected)"), watch.tick(12_000))
    }

    @Test fun iceFailedEndsTheSessionAtOnce() {
        val watch = XboxPictureWatch()
        watch.frameArrived(0)
        watch.iceChanged(XboxPictureWatch.Ice.FAILED, 500)
        assertEquals(XboxPictureVerdict.Stalled("Xbox ICE bağlantısı koptu (failed)"), watch.tick(600))
    }

    @Test fun framesWhileIceSaysDisconnectedDoNotWarn() {
        val watch = XboxPictureWatch()
        watch.iceChanged(XboxPictureWatch.Ice.DISCONNECTED, 0)
        for (second in 0L until 20L) {
            watch.frameArrived(second * 1000)
            assertEquals(fine, watch.tick(second * 1000 + 300))
        }
    }

    @Test fun stalledSessionRetriesThroughTheMachine() {
        var clock = 0L
        val machine = XboxSessionMachine(clock = { clock })
        machine.start()
        machine.played()
        machine.status("Provisioned", null)
        assertTrue(machine.streaming())
        clock = 30_000
        assertEquals(XboxSessionMachine.Action.Retry(5000), machine.fail(XboxError.NO_PICTURE, "Xbox'tan 12 sn'dir görüntü gelmiyor"))
    }
}
