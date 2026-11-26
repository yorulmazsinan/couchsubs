// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/** Katmanın boşta kapanması (beta.104, Vestel UA9600: bilgisayar kapandıktan sonra katman ve sağ üstteki nokta kalıyordu). */
public class OverlayIdleTest {
    private static final long T0 = 1_000_000;

    @Test
    public void neverConnectedOverlayClosesAfterTheLimit() {
        OverlayIdle idle = new OverlayIdle();
        idle.started(T0);
        assertEquals(T0 + OverlayIdle.EXIT_AFTER_MS, idle.exitAt());
        assertFalse(idle.expired(T0 + OverlayIdle.EXIT_AFTER_MS - 1));
        assertTrue(idle.expired(T0 + OverlayIdle.EXIT_AFTER_MS));
    }

    @Test
    public void connectedOverlayStaysOpenIndefinitely() {
        OverlayIdle idle = new OverlayIdle();
        idle.started(T0);
        assertTrue(idle.connection(true, T0 + 2_000));
        assertEquals(-1, idle.exitAt());
        assertFalse(idle.expired(T0 + 24 * 3_600_000L));
    }

    @Test
    public void computerClosedOverlayClosesTwoMinutesAfterTheLoss() {
        OverlayIdle idle = new OverlayIdle();
        idle.started(T0);
        idle.connection(true, T0 + 2_000);
        long lost = T0 + 3_600_000;
        assertTrue(idle.connection(false, lost));
        assertEquals(lost + OverlayIdle.EXIT_AFTER_MS, idle.exitAt());
        assertFalse(idle.expired(lost + OverlayIdle.EXIT_AFTER_MS - 1));
        assertTrue(idle.expired(lost + OverlayIdle.EXIT_AFTER_MS));
        assertEquals(OverlayIdle.EXIT_AFTER_MS / 1000, idle.secondsSince(lost + OverlayIdle.EXIT_AFTER_MS));
    }

    @Test
    public void shortReconnectKeepsTheOverlay() {
        OverlayIdle idle = new OverlayIdle();
        idle.started(T0);
        idle.connection(true, T0);
        idle.connection(false, T0 + 10_000);
        idle.connection(true, T0 + 40_000);
        assertFalse(idle.expired(T0 + 10_000 + OverlayIdle.EXIT_AFTER_MS * 5));
    }

    @Test
    public void repeatedSameStateDoesNotRestartTheClock() {
        OverlayIdle idle = new OverlayIdle();
        idle.started(T0);
        // Sayfa her hata olayında yeniden "kopuk" bildirse de süre baştan başlamaz; katman yine kapanır.
        assertFalse(idle.connection(false, T0 + 60_000));
        assertFalse(idle.connection(false, T0 + 110_000));
        assertTrue(idle.expired(T0 + OverlayIdle.EXIT_AFTER_MS));
    }

    @Test
    public void newWindowStartsAFreshClock() {
        OverlayIdle idle = new OverlayIdle();
        idle.started(T0);
        idle.connection(true, T0 + 1_000);
        // Sayfa çöktü, pencere yeniden kuruldu: yeni sayfa henüz bağlı değil.
        idle.started(T0 + 50_000);
        assertFalse(idle.connected());
        assertEquals(T0 + 50_000 + OverlayIdle.EXIT_AFTER_MS, idle.exitAt());
    }

    @Test
    public void limitIsLongerThanAnOrdinaryReconnect() {
        // Bilgisayarın yeniden bağlanması (tarama, kısa ağ kopması) birkaç saniye; katman onu beklemeli.
        assertTrue(OverlayIdle.EXIT_AFTER_MS >= 60_000);
        assertTrue(OverlayIdle.EXIT_AFTER_MS <= 5 * 60_000);
    }
}
