// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class FallbackWatchTest {
    private static final long LIMIT = FallbackWatch.LIMIT_MS;

    @Test
    public void noPictureForTheLimitSwitchesToOverlay() {
        FallbackWatch watch = new FallbackWatch();
        watch.trouble(1_000);
        assertFalse(watch.shouldSwitch(1_000 + LIMIT - 1, true, true));
        assertTrue(watch.shouldSwitch(1_000 + LIMIT, true, true));
    }

    @Test
    public void retriesDoNotRestartTheClock() {
        FallbackWatch watch = new FallbackWatch();
        watch.trouble(0);
        watch.trouble(4_000);
        watch.trouble(8_000);
        assertTrue(watch.shouldSwitch(LIMIT, true, true));
    }

    @Test
    public void pictureThatArrivedOnceNeverSwitches() {
        // TV uygulama içinde gösterebiliyor; sonradan kesilmesi (PS5 uykuda) TV'nin sorunu değil.
        FallbackWatch watch = new FallbackWatch();
        watch.trouble(0);
        watch.videoAvailable();
        watch.trouble(1_000);
        assertFalse(watch.shouldSwitch(1_000 + 10 * LIMIT, true, true));
        assertFalse(watch.needsPermission(1_000 + 10 * LIMIT, true, false));
    }

    @Test
    public void emptyInputDoesNotSwitch() {
        FallbackWatch watch = new FallbackWatch();
        watch.trouble(0);
        assertFalse(watch.shouldSwitch(2 * LIMIT, false, true));
        assertFalse(watch.needsPermission(2 * LIMIT, false, false));
    }

    @Test
    public void missingPermissionAsksInsteadOfSwitching() {
        FallbackWatch watch = new FallbackWatch();
        watch.trouble(0);
        assertFalse(watch.shouldSwitch(LIMIT, true, false));
        assertTrue(watch.needsPermission(LIMIT, true, false));
        assertFalse(watch.needsPermission(LIMIT, true, true));
    }

    @Test
    public void nothingHappensBeforeTheInputIsOpened() {
        assertFalse(new FallbackWatch().shouldSwitch(10 * LIMIT, true, true));
    }

    @Test
    public void pauseRestartsTheClock() {
        FallbackWatch watch = new FallbackWatch();
        watch.trouble(0);
        watch.pause();
        assertFalse(watch.shouldSwitch(LIMIT, true, true));
        watch.trouble(LIMIT + 5_000);
        assertFalse(watch.shouldSwitch(2 * LIMIT, true, true));
        assertTrue(watch.shouldSwitch(2 * LIMIT + 5_000, true, true));
    }

    @Test
    public void pushedToBackgroundRightAfterTuningIsATakeover() {
        // MediaTek Google TV: TV kendi HDMI oynatıcısını ~1,3 sn sonra öne çekti.
        FallbackWatch watch = new FallbackWatch();
        assertFalse(watch.takenOver(1_000, true));
        watch.tuned(1_000);
        assertTrue(watch.takenOver(2_300, true));
        assertFalse(watch.takenOver(2_300, false));
        assertFalse(watch.takenOver(1_000 + FallbackWatch.TAKEOVER_MS, true));
    }
}
