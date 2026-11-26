// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import com.couchsubs.mobile.R
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.translation.OnlineKeyState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Çevrimiçi motor (DeepL, yapay zekâ) çeviremeyince ana ekranda gerçek nedeni söylenir (GitHub #1322): anahtar, kota, ağ
 * ayrı metinler; Mac/iPhone OnlineIssueText ve Windows Contracts.Describe ile aynı eşleme.
 */
class OnlineIssueTextTest {
    @Test fun eachFailureHasItsOwnReason() {
        assertEquals(R.string.online_issue_invalid, onlineIssueReason(OnlineKeyState.INVALID))
        assertEquals(R.string.online_issue_quota, onlineIssueReason(OnlineKeyState.QUOTA_EXCEEDED))
        assertEquals(R.string.online_issue_model, onlineIssueReason(OnlineKeyState.MODEL_REJECTED))
        assertEquals(R.string.online_issue_unreachable, onlineIssueReason(OnlineKeyState.UNREACHABLE))
        assertEquals(R.string.online_issue_busy, onlineIssueReason(OnlineKeyState.BUSY))
        assertNull(onlineIssueReason(OnlineKeyState.VALID))
    }

    @Test fun newSessionStartsWithoutAnIssue() {
        assertNull(LiveStatus(running = true).onlineIssue)
    }
}
