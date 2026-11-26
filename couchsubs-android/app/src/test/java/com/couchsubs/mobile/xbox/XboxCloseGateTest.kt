// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean

/** Xbox oturumlarının kapanış sırası (iPhone/Mac'teki XboxCloseGateTests ile aynı). */
class XboxCloseGateTest {
    @Test fun nothingPendingReturnsNull() {
        assertNull(XboxCloseGate().waitForPending(1000))
    }

    @Test fun newSessionWaitsForPreviousClose() {
        val gate = XboxCloseGate()
        val closing = gate.begin()
        val closed = AtomicBoolean(false)
        Thread {
            Thread.sleep(100)
            closed.set(true)
            closing.done()
        }.start()
        val waited = gate.waitForPending(5000)!!
        assertTrue("yeni oturum eski oturum kapanmadan açılmaz", closed.get())
        assertEquals(1, waited.sessions)
        assertFalse(waited.timedOut)
        assertEquals(0, gate.pendingCount)
    }

    @Test fun slowCloseDoesNotBlockForever() {
        val gate = XboxCloseGate()
        gate.begin()
        val waited = gate.waitForPending(50)!!
        assertTrue(waited.timedOut)
        assertTrue(waited.line.contains("bitmedi"))
    }

    @Test fun staleSessionsPassToTheNextSession() {
        val gate = XboxCloseGate()
        gate.addStale("a")
        gate.addStale("a")
        gate.addStale("b")
        assertEquals(listOf("a", "b"), gate.takeStale())
        assertEquals(emptyList<String>(), gate.takeStale())
    }

    @Test fun waitLine() {
        assertEquals("önceki oturumun kapanması beklendi (1 oturum, 0.4 sn)", XboxCloseWait(1, 420, false).line)
        assertEquals("önceki oturumun kapanması 10.0 sn'de bitmedi (2 oturum); yeni oturum yine açılıyor",
            XboxCloseWait(2, 10_000, true).line)
    }
}
