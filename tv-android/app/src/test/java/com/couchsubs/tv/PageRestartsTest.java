// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class PageRestartsTest {
    @Test
    public void occasionalLossIsRestarted() {
        PageRestarts restarts = new PageRestarts();
        long step = PageRestarts.WINDOW_MS;
        for (int i = 0; i < 10; i++) assertTrue(restarts.allow(i * step));
    }

    @Test
    public void repeatedLossInAShortTimeStops() {
        PageRestarts restarts = new PageRestarts();
        for (int i = 0; i < PageRestarts.LIMIT; i++) assertTrue(restarts.allow(1_000 + i * 5_000));
        assertFalse(restarts.allow(20_000));
        // Pencere geçince yeniden denenir.
        assertTrue(restarts.allow(1_000 + PageRestarts.WINDOW_MS + 20_000));
    }
}
