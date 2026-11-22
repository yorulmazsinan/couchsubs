// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/** #794: HDR devreye girince, PS5 açılınca ya da bildirim gelince TV kendi HDMI ekranına geçiyordu. */
public class ScreenReclaimTest {
    @Test
    public void takeoverRightAfterASignalChangeIsReclaimed() {
        ScreenReclaim reclaim = new ScreenReclaim();
        reclaim.signal(60_000, 0);
        assertTrue(reclaim.shouldReclaim(61_500, true));
        // Aynı olay ikinci kez geri aldırmaz.
        assertFalse(reclaim.shouldReclaim(62_000, true));
    }

    @Test
    public void userLeavingWithoutASignalChangeIsNotReclaimed() {
        ScreenReclaim reclaim = new ScreenReclaim();
        assertFalse(reclaim.shouldReclaim(60_000, true));
        reclaim.signal(60_000, 0);
        assertFalse(reclaim.shouldReclaim(60_000 + ScreenReclaim.SIGNAL_WINDOW_MS + 1, true));
    }

    @Test
    public void eventsOfOurOwnTuningAndScreensWithoutPictureAreNotReclaimed() {
        ScreenReclaim reclaim = new ScreenReclaim();
        reclaim.signal(10_500, 10_000);
        assertFalse(reclaim.shouldReclaim(11_000, true));
        reclaim.signal(60_000, 10_000);
        assertFalse(reclaim.shouldReclaim(60_500, false));
    }

    /**
     * X (TCL Google TV, 0.9.56 sonrası): "ayarlar tuşu uygulamadan atıyor". Kumandada tuşa basılıp hemen ardından ekran
     * önden çekildiyse (hızlı ayarlar paneli) devralma değildir: geri alınmaz, hak dolmuş olsa da katmana geçilmez.
     */
    @Test
    public void screenOpenedByTheUsersKeyIsNotATakeover() {
        ScreenReclaim reclaim = new ScreenReclaim();
        for (long t = 100_000; t < 130_000; t += 5_000) {
            reclaim.signal(t, 0);
            reclaim.userKey(t + 200);
            assertEquals(ScreenReclaim.Action.NONE, reclaim.onTakenAway(t + 400, true));
        }
        assertTrue(reclaim.userActedBefore(130_000 - 5_000 + 200 + ScreenReclaim.USER_KEY_MS));
        assertFalse(reclaim.userActedBefore(130_000 - 5_000 + 200 + ScreenReclaim.USER_KEY_MS + 1));
        // Tuştan uzun süre sonra gelen devralma yine tanınır.
        reclaim.userKey(200_000);
        reclaim.signal(210_000, 0);
        assertTrue(reclaim.shouldReclaim(210_500, true));
    }

    /** Girişi açtıran tuş (seçicide 1-4) TV'nin hemen ardından gelen devralmasını kullanıcının işi saydırmaz (#42). */
    @Test
    public void keyThatTunedTheInputDoesNotHideTheTakeover() {
        ScreenReclaim reclaim = new ScreenReclaim();
        reclaim.userKey(50_000);
        reclaim.tuned();
        assertFalse(reclaim.userActedBefore(51_500));
    }

    /** Aynı boyu ya da aynı izleri yineleyen TV'de (görüntü değişmedi) sinyal olayı sayılmaz; gerçek değişim sayılır. */
    @Test
    public void onlyRealSizeOrTrackChangesCount() {
        ScreenReclaim reclaim = new ScreenReclaim();
        reclaim.videoSize(60_000, 0, 1920, 1080);
        reclaim.videoTracks(60_000, 0, "v:1920x1080@60.0;");
        for (long t = 61_000; t < 70_000; t += 1_000) {
            reclaim.videoSize(t, 0, 1920, 1080);
            reclaim.videoTracks(t, 0, "v:1920x1080@60.0;");
        }
        assertFalse(reclaim.shouldReclaim(70_100, true));
        // HDR/çözünürlük değişimi.
        reclaim.videoSize(80_000, 0, 3840, 2160);
        assertTrue(reclaim.shouldReclaim(80_500, true));
        reclaim.videoTracks(90_000, 0, "v:3840x2160@120.0;");
        assertTrue(reclaim.shouldReclaim(90_500, true));
        // Giriş yeniden açılınca ilk bildirim değişim sayılmaz.
        reclaim.tuned();
        reclaim.videoSize(100_000, 0, 1280, 720);
        assertFalse(reclaim.shouldReclaim(100_500, true));
    }

    @Test
    public void atMostThreeTimesAMinute() {
        ScreenReclaim reclaim = new ScreenReclaim();
        int done = 0;
        for (long t = 100_000; t < 160_000; t += 5_000) {
            reclaim.signal(t, 0);
            if (reclaim.shouldReclaim(t + 500, true)) done++;
        }
        assertTrue(done == ScreenReclaim.MAX_PER_MINUTE);
        // Hak dolunca devralma yine tanınır (katmana geçilsin); olay yoksa hiçbir şey yapılmaz.
        reclaim.signal(157_000, 0);
        assertEquals(ScreenReclaim.Action.GIVE_UP, reclaim.onTakenAway(157_500, true));
        assertEquals(ScreenReclaim.Action.NONE, reclaim.onTakenAway(158_000, true));
        reclaim.signal(200_000, 0);
        assertTrue(reclaim.shouldReclaim(200_500, true));
    }
}
