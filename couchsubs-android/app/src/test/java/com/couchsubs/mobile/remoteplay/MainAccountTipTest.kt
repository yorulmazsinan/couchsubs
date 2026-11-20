// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kol ikinci hesaba atanınca PS5 her yeniden bağlanışta kolu kapatıyor (Play yorumu 20 Kas): ipucu bağlantı koptuğunda da
 * görünmeli (Mac/iPhone MainAccountTipTests, Windows AppControllerTests ile aynı).
 */
class MainAccountTipTest {
    @Test
    fun showsBeforeFirstSubtitle() {
        assertTrue(MainAccountTip.visible(ps5 = true, demo = false, hasSubtitle = false, streaming = false))
        assertTrue(MainAccountTip.visible(ps5 = true, demo = false, hasSubtitle = false, streaming = true))
    }

    @Test
    fun hidesWhileSubtitlesFlow() {
        assertFalse(MainAccountTip.visible(ps5 = true, demo = false, hasSubtitle = true, streaming = true))
    }

    @Test
    fun showsAgainWhenConnectionDropsAfterSubtitles() {
        assertTrue(MainAccountTip.visible(ps5 = true, demo = false, hasSubtitle = true, streaming = false))
    }

    @Test
    fun neverForXboxOrDemo() {
        assertFalse(MainAccountTip.visible(ps5 = false, demo = false, hasSubtitle = false, streaming = false))
        assertFalse(MainAccountTip.visible(ps5 = true, demo = true, hasSubtitle = true, streaming = false))
    }
}
