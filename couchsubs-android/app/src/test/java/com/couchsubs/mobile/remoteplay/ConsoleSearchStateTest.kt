// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "PS5 … adresinde bulunamadı" etiketi ve yanıtsız aramada tanı satırı (Mac/iPhone ve Windows ile aynı kural). */
class ConsoleSearchStateTest {
    /**
     * Arama yanıtı kaçıp "yine de bağlanılıyor" ile kurulan oturum saatlerce sürse de sonraki kopma eskiden
     * "bulunamadı" oluyordu. Bağlanınca PS5'e ulaşıldığı bilinir.
     */
    @Test
    fun connectedSessionDropIsNotLabelledNotFound() {
        val search = ConsoleSearchState()
        search.searched(answered = false)
        val network = SessionState.Disconnected(DisconnectKind.NETWORK)
        assertEquals(DisconnectKind.NOT_FOUND, search.classify(network, "192.168.1.70").kind)
        search.connected()
        assertEquals(network, search.classify(network, "192.168.1.70"))
        val stall = SessionState.Disconnected(DisconnectKind.OTHER, "no picture from the PS5")
        assertEquals(stall, search.classify(stall, "192.168.1.70"))
    }

    @Test
    fun unansweredSearchAfterConnectingIsNotFoundAgain() {
        val search = ConsoleSearchState()
        search.connected()
        search.searched(answered = false)
        assertEquals(SessionState.Disconnected(DisconnectKind.NOT_FOUND, "10.0.0.2"),
            search.classify(SessionState.Disconnected(DisconnectKind.NETWORK), "10.0.0.2"))
        val refused = SessionState.Disconnected(DisconnectKind.REFUSED)
        assertEquals(refused, search.classify(refused, "10.0.0.2"))
    }

    @Test
    fun diagnosisIsWrittenOnFirstAndEveryFifthUnansweredSearch() {
        val search = ConsoleSearchState()
        val written = (1..11).map { search.searched(answered = false) }
        assertEquals(listOf(true, false, false, false, true, false, false, false, false, true, false), written)
        assertEquals(11, search.unanswered)
        assertFalse(search.searched(answered = true))
        assertEquals(0, search.unanswered)
        assertTrue(search.searched(answered = false))
        search.reset()
        assertTrue(search.answered)
        assertEquals(0, search.unanswered)
    }

    @Test
    fun deviceDiagnosticsLine() {
        assertEquals("açık tanıtıcı 37/32768; IPv4 wlan0 192.168.1.23/24",
            DeviceDiagnostics.describe(37, 32768, listOf("wlan0 192.168.1.23/24")))
        assertEquals("açık tanıtıcı 5/-; IPv4 ağı yok", DeviceDiagnostics.describe(5, null, emptyList()))
    }
}
