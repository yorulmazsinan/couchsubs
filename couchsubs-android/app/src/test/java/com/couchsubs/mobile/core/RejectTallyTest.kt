// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** Altyazı kapısının eleme sayacı ([RejectTally]; beta.103 kaçan altyazı). Mac ve Windows RejectTallyTests aynı vakalar. */
class RejectTallyTest {
    @Test fun lineCarriesTheReasonCount() {
        val tally = RejectTally()
        assertEquals(listOf("a [bu nedenle 1. kez]"), tally.note("menü", "a", 0))
        assertEquals(emptyList<String>(), tally.note("menü", null, 10))
        assertEquals(listOf("b [bu nedenle 3. kez]"), tally.note("menü", "b", 20))
        assertEquals(listOf("c [bu nedenle 1. kez]"), tally.note("telefon", "c", 30))
        assertEquals(3, tally.count("menü"))
    }

    @Test fun linesAreCappedPerMinuteAndSummarized() {
        val tally = RejectTally()
        val written = mutableListOf<String>()
        for (index in 0 until RejectTally.PER_MINUTE + 5) written += tally.note("menü", "satır $index", index.toLong())
        tally.note("telefon", null, 100)
        assertEquals(RejectTally.PER_MINUTE, written.size)
        val next = tally.note("menü", "yeni", RejectTally.WINDOW_MS + 1)
        assertEquals(listOf(
            "altyazı elemesi (son 60 sn): menü ×${RejectTally.PER_MINUTE + 5}; telefon ×1; sınır yüzünden yazılmayan 5 satır",
            "yeni [bu nedenle ${RejectTally.PER_MINUTE + 6}. kez]",
        ), next)
    }

    @Test fun resetForgetsTheCounts() {
        val tally = RejectTally()
        tally.note("menü", null, 0)
        tally.reset()
        assertEquals(listOf("a [bu nedenle 1. kez]"), tally.note("menü", "a", 1))
    }
}
