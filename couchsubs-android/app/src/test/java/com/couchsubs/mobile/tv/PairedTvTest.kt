// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import com.couchsubs.mobile.core.SubtitleAccess
import com.couchsubs.mobile.core.SubtitlePairing
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

/** PR #870 incelemesi: TV'nin başlattığı eşleşme onaylanınca TV kaydedilmiyordu (bekçi ve TV kartı çalışmıyordu). */
class PairedTvTest {
    @Test
    fun adoptsOnlyWhenNoTvIsChosen() {
        assertTrue(PairedTv.shouldAdopt("192.168.1.40", null))
        assertFalse(PairedTv.shouldAdopt("192.168.1.40", InstalledTv(TvBrand.LG, "192.168.1.30")))
        assertFalse(PairedTv.shouldAdopt("", null))
    }

    @Test
    fun brandComesFromTheTvsOwnAnswers() {
        val samsung = PairedTv.samsungName("""{"device":{"name":"[TV] Samsung Q80","modelName":"QE55Q80"},"name":"x"}""")
        assertEquals("[TV] Samsung Q80", samsung)
        assertEquals(FoundTv("[TV] Samsung Q80", "192.168.1.40", TvBrand.SAMSUNG), PairedTv.classify("192.168.1.40", samsung, null, true, true))
        val lg = PairedTv.lgName("<root><device><manufacturer>LG Electronics</manufacturer><friendlyName>LG OLED</friendlyName></device></root>")
        assertEquals(FoundTv("LG OLED", "192.168.1.40", TvBrand.LG), PairedTv.classify("192.168.1.40", null, lg, false, true))
        assertEquals(FoundTv("LG TV", "192.168.1.40", TvBrand.LG), PairedTv.classify("192.168.1.40", null, null, true, false))
        assertEquals(FoundTv("Android TV", "192.168.1.40", TvBrand.ANDROID_TV), PairedTv.classify("192.168.1.40", null, null, false, true))
        assertNull(PairedTv.classify("192.168.1.40", null, null, false, false))
        assertNull(PairedTv.samsungName("not json"))
        assertNull(PairedTv.lgName("<root><device><manufacturer>Sony</manufacturer></device></root>"))
    }

    @Test
    fun requesterAddressTravelsWithTheTicket() {
        assertEquals("192.168.1.40", SubtitleAccess.tvHost(InetAddress.getByName("192.168.1.40")))
        assertEquals("192.168.1.40", SubtitleAccess.tvHost(InetAddress.getByName("::ffff:192.168.1.40")))
        assertEquals("", SubtitleAccess.tvHost(InetAddress.getByName("127.0.0.1")))
        assertEquals("", SubtitleAccess.tvHost(InetAddress.getByName("::1")))
        assertEquals("", SubtitleAccess.tvHost(InetAddress.getByName("8.8.8.8")))
        val pairing = SubtitlePairing()
        pairing.setSession(true)
        assertEquals("192.168.1.40", pairing.begin("192.168.1.40")?.host)
        assertEquals("192.168.1.40", pairing.pending?.host)
    }
}
