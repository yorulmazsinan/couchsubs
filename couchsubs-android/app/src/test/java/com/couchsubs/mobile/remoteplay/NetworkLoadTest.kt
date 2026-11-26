// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #1366: PS5 ağ taraması seyreltilir, bağlıyken yoklama ağı taramaz, ağ yükü dakikada bir satırla günlükte. */
class NetworkLoadTest {
    private fun saved() = RegisteredConsole("192.168.1.20", "PS5-A", "0123abcd".toByteArray(), ByteArray(16) { 7 }, "1C98C1AABBCC")

    @Test
    fun sweepSendsOnlyTwoPacedRounds() {
        assertTrue(SweepPacing.isSweep(254))
        assertFalse(SweepPacing.isSweep(1))
        assertEquals(listOf(0, 1), (0 until 6).filter { SweepPacing.sendsInRound(it, 254) })
        assertEquals((0 until 6).toList(), (0 until 6).filter { SweepPacing.sendsInRound(it, 1) })
        // 254 adres, 3 sn: eskiden 6 tur (1524 paket), artık 2 tur.
        assertEquals(508, SweepPacing.plannedPackets(254, 3000))
        // Tek adres, 2 sn: yarım saniyede bir.
        assertEquals(4, SweepPacing.plannedPackets(1, 2000))
        assertTrue(1000 / SweepPacing.PACE_MS <= 250)
    }

    @Test
    fun locateWithoutSweepNeverScansTheNetwork() {
        val asked = mutableListOf<String?>()
        val finder = ConsoleFinder(saved(), { host -> asked += host; emptyList() }, log = {})
        assertEquals(null, finder.locate(sweep = false).info)
        assertEquals(null, finder.locate(sweep = false).info)
        assertEquals(listOf<String?>("192.168.1.20", "192.168.1.20"), asked)
    }

    @Test
    fun networkLoadWritesAtMostOneLinePerMinute() {
        val lines = mutableListOf<String>()
        val load = NetworkLoad { lines += it }
        val start = 1_000_000L
        load.discovery(true, 508, start)
        assertEquals(listOf("Ağ yükü (son 0 sn): PS5 ağ taraması 1 kez, 508 paket; tek adres sorgusu 0 kez, 0 paket; PS5'e yeniden bağlanma 0"), lines)
        for (second in 1..59) load.discovery(false, 4, start + second * 1000L)
        load.retry(start + 59_000)
        assertEquals(1, lines.size)
        load.discovery(true, 500, start + 60_000)
        assertEquals("Ağ yükü (son 59 sn): PS5 ağ taraması 1 kez, 500 paket; tek adres sorgusu 59 kez, 236 paket; PS5'e yeniden bağlanma 1",
            lines.last())
    }
}
