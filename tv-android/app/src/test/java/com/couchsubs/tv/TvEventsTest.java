// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import org.junit.Test;

public class TvEventsTest {
    private static final class Memory implements TvEvents.Store {
        String value = "";
        @Override public String read() { return value; }
        @Override public void write(String value) { this.value = value; }
    }

    @Test
    public void linesAreKeptUntilThePageTakesThem() {
        Memory store = new Memory();
        TvEvents events = new TvEvents(store);
        assertTrue(events.add("exit intent (keeper)", 1_000));
        assertTrue(events.add("hdmi tune (resume)", 6_000));
        // Ekran kapandı, işlem yeniden açıldı: satırlar saklı yerden okunur; 5 sn'den eskiye yaşı eklenir.
        TvEvents next = new TvEvents(store);
        assertEquals(Arrays.asList("exit intent (keeper) (9s ago)", "hdmi tune (resume)"), next.take(10_000));
        assertEquals(Collections.emptyList(), next.take(11_000));
    }

    /** Aynı türden satır 15 sn'de bir; aradakiler sonraki satırda "+n" olarak sayılır. Başka türler etkilenmez. */
    @Test
    public void sameKindIsRateLimitedAndCounted() {
        TvEvents events = new TvEvents(new Memory());
        assertTrue(events.add("hdmi tune (outage)", 0));
        assertFalse(events.add("hdmi tune (outage)", 1_000));
        assertFalse(events.add("hdmi tune (no picture)", 2_000));
        assertTrue(events.add("activity reclaim (taken over)", 3_000));
        assertTrue(events.add("hdmi tune (resume)", TvEvents.GAP_MS));
        assertEquals(Arrays.asList("hdmi tune (outage) (15s ago)", "activity reclaim (taken over) (12s ago)",
                "hdmi tune (resume) +2"), events.take(TvEvents.GAP_MS));
    }

    /** Döngüde günlük taşmaz: 10 dakikada en çok 20 satır, en çok 20 bekleyen satır. */
    @Test
    public void totalIsBounded() {
        Memory store = new Memory();
        TvEvents events = new TvEvents(store);
        int accepted = 0;
        for (int i = 0; i < 200; i++) if (events.add("kind" + i + " (loop)", i * 1_000L)) accepted++;
        assertEquals(TvEvents.WINDOW_MAX, accepted);
        List<String> taken = events.take(200_000);
        assertEquals(TvEvents.PENDING_MAX, taken.size());
        // Pencere geçince yeniden yazılır.
        assertTrue(events.add("kind0 (loop)", 200_000 + TvEvents.WINDOW_MS));
    }

    @Test
    public void controlCharactersCannotBreakTheStore() {
        Memory store = new Memory();
        TvEvents events = new TvEvents(store);
        assertTrue(events.add("hdmi tune\n(evil)\tx", 0));
        assertEquals(Collections.singletonList("hdmi tune (evil) x"), events.take(0));
        assertFalse(events.add("   ", 0));
        assertFalse(events.add(null, 0));
        StringBuilder longLine = new StringBuilder();
        for (int i = 0; i < 400; i++) longLine.append('x');
        assertTrue(events.add(longLine.toString(), 100_000));
        assertEquals(TvEvents.TEXT_MAX, events.take(100_000).get(0).length());
    }

    @Test
    public void brokenStoreLinesAreSkipped() {
        Memory store = new Memory();
        store.value = "garbage\nabc\tline\n5\tok (x)";
        assertEquals(Collections.singletonList("ok (x)"), new TvEvents(store).take(5));
    }
}
