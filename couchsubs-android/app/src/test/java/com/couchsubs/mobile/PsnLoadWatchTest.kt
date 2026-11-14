// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile

import com.couchsubs.mobile.remoteplay.PsnLoadWatch
import com.couchsubs.mobile.remoteplay.PsnPageProblem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PsnLoadWatchTest {
    private val start = 1_000L
    private val late = start + PsnLoadWatch.LOAD_TIMEOUT_MS

    @Test
    fun nothingBeforeTimeout() {
        assertNull(PsnLoadWatch(start).problemAt(late - 1))
    }

    @Test
    fun timesOutWithoutAnyWebViewEvent() {
        // WebView hiç olay vermese de (çerez silme dönmedi, yükleme başlamadı) süre dolunca hata.
        assertEquals(PsnPageProblem.TIMEOUT, PsnLoadWatch(start).problemAt(late))
    }

    @Test
    fun finishedButNoFormIsBlank() {
        val watch = PsnLoadWatch(start)
        watch.onPageFinished()
        watch.onInteractiveCount("0")
        assertEquals(PsnPageProblem.BLANK, watch.problemAt(late))
    }

    @Test
    fun formStopsTheTimer() {
        val watch = PsnLoadWatch(start)
        watch.onPageFinished()
        watch.onInteractiveCount("3")
        assertNull(watch.problemAt(late + 60_000))
    }

    @Test
    fun redirectStopsTheTimer() {
        val watch = PsnLoadWatch(start)
        watch.onRedirect()
        assertNull(watch.problemAt(late))
    }

    @Test
    fun oddScriptResultsAreNotReady() {
        val watch = PsnLoadWatch(start)
        watch.onInteractiveCount(null)
        watch.onInteractiveCount("null")
        watch.onInteractiveCount("\"2\"".substring(0, 1))
        assertEquals(PsnPageProblem.TIMEOUT, watch.problemAt(late))
        watch.onInteractiveCount("\"2\"")
        assertNull(watch.problemAt(late))
    }
}
