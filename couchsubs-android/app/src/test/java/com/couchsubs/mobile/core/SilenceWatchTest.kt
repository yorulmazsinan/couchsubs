// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Sessizlik bekçisi (Mac SilenceWatchTests ve Windows SilenceWatchTests ile aynı örnekler). */
class SilenceWatchTest {
    @Test fun onlySpeechLikeLinesCount() {
        listOf("We should reach the lighthouse before dark.", "JASON: Get in the car",
            "Hey, look, we don't wanna get caught out here, man.", "I need 5 more minutes, okay?")
            .forEach { assertTrue(it, SilenceWatch.isSpeech(it)) }
        listOf("SETTINGS", "Search the camp for Donnie", "RETRY CHECKPOINT RESTART MISSION", "Okay.", "$1,250 in 3 days.",
            "Collect the packages", "LUREPREDATOR / L35₽")
            .forEach { assertFalse(it, SilenceWatch.isSpeech(it)) }
    }

    @Test fun firesAfterTenSilentSecondsOncePerLineAndAtMostEveryTenSeconds() {
        val watch = SilenceWatch()
        val line = "We should reach the lighthouse before dark."
        assertNull(watch.due(listOf(line), 0))
        assertNull(watch.due(listOf(line), 9_900))
        assertEquals(line, watch.due(listOf(line), 10_000))
        watch.fired(line, 10_000)
        // Aynı satır bir daha gönderilmez.
        assertNull(watch.due(listOf(line), 20_000))
        val next = "Don't let him see you, stay low."
        assertNull(watch.due(listOf(next), 21_000))
        assertNull(watch.due(listOf(next), 30_000))
        assertEquals(next, watch.due(listOf(next), 31_000))
        watch.fired(next, 31_000)
        // Bir çeviri gönderildi: sessizlik yeniden başlar.
        watch.sent()
        val third = "Where the hell is Donnie now?"
        assertNull(watch.due(listOf(third), 32_000))
        assertNull(watch.due(listOf(third), 41_000))
        assertEquals(third, watch.due(listOf(third), 42_000))
        // Konuşma kesilirse süre baştan başlar.
        val gap = SilenceWatch()
        assertNull(gap.due(listOf(line), 0))
        assertNull(gap.due(listOf("SETTINGS"), 5_000))
        assertNull(gap.due(listOf(line), 6_000))
        assertNull(gap.due(listOf(line), 15_000))
        assertEquals(line, gap.due(listOf(line), 16_000))
    }
}
