// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PS5'i kimliğiyle (keşifteki host-id) tanıma: ad değişse de, aynı adlı iki PS5 olsa da doğru PS5 bulunur; eski kayıt kimliği
 * ilk bulunuşta öğrenir (Mac/iPhone ve Windows ConsoleIdentityTests ile aynı durumlar).
 */
class ConsoleIdentityTest {
    private fun saved(host: String = "192.168.1.20", name: String = "PS5-A", hostId: String? = "1C98C1AABBCC") =
        RegisteredConsole(host, name, "0123abcd".toByteArray(), ByteArray(16) { 7 }, hostId)

    private val noLog: (String) -> Unit = {}

    @Test
    fun hostIdIsNormalized() {
        assertEquals("1C98C1AABBCC", ConsoleIdentity.normalized("1c:98:c1:aa:bb:cc"))
        assertEquals("1C98C1AABBCC", ConsoleIdentity.normalized(" 1c98c1aabbcc\r"))
        assertNull(ConsoleIdentity.normalized(""))
        assertNull(ConsoleIdentity.normalized("000000000000"))
        assertNull(ConsoleIdentity.normalized(null))
        assertEquals("1C98C1AABBCC", ConsoleIdentity.fromMac(byteArrayOf(0x1C, 0x98.toByte(), 0xC1.toByte(), 0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte())))
        assertNull(ConsoleIdentity.fromMac(ByteArray(6)))
        assertNull(ConsoleIdentity.fromMac(null))
    }

    /** Yerel kütüphanenin keşif satırı: altıncı alan host-id; eski biçimde (beş ya da üç alan) yok. */
    @Test
    fun discoveryLineCarriesTheHostId() {
        val line = ConsoleDiscovery.parseLine("192.168.1.20\tPS5-123\t1\tPPSA12345\tGTA VI\t1c98c1aabbcc")
        assertEquals("1C98C1AABBCC", line?.hostId)
        assertEquals("GTA VI", line?.runningAppName)
        assertNull(ConsoleDiscovery.parseLine("192.168.1.20\tPS5-123\t0\t\t\t")?.hostId)
        assertNull(ConsoleDiscovery.parseLine("192.168.1.20\tPS5-123\t1")?.hostId)
    }

    /** PS5'in adı değişti: kimlik tuttuğu için yeni adreste yine bulunur ve kayıttaki ad güncellenir. */
    @Test
    fun renamedConsoleIsFoundByHostId() {
        val console = saved()
        val renamed = ConsoleInfo("192.168.1.44", "Salon PS5", true, hostId = "1C98C1AABBCC")
        assertTrue(ConsoleIdentity.isRegistered(renamed, console))
        assertEquals(renamed, ConsoleIdentity.pickMoved(listOf(renamed), console))
        val updated = ConsoleIdentity.updated(console, renamed)
        assertEquals("192.168.1.44", updated?.host)
        assertEquals("Salon PS5", updated?.name)
        assertEquals("1C98C1AABBCC", updated?.hostId)
        assertArrayEquals(console.registKey, updated?.registKey)
    }

    /** Aynı adlı iki PS5: kimlikli kayıt doğru olanı seçer; kayıtlı adreste yanıt veren öteki PS5 kayıtlı sayılmaz. */
    @Test
    fun twoConsolesWithTheSameNameAreToldApart() {
        val console = saved()
        val mine = ConsoleInfo("192.168.1.31", "PS5-A", false, hostId = "1C98C1AABBCC")
        val other = ConsoleInfo("192.168.1.20", "PS5-A", true, hostId = "F8461C000001")
        assertFalse(ConsoleIdentity.isRegistered(other, console))
        assertEquals(mine, ConsoleIdentity.pickMoved(listOf(other, mine), console))
        // Kimliksiz (eski) kayıtta iki aynı ad emin olunamaz: hiçbirine geçilmez.
        assertNull(ConsoleIdentity.pickMoved(listOf(other, mine), saved(hostId = null)))
    }

    /** Eski kayıt (kimlik yok): adıyla bulunur, kimliği kayda yazılır; ad değişmez. Sonraki aramalar kimlikle olur. */
    @Test
    fun legacyRecordLearnsHostIdOnFirstMatch() {
        val legacy = saved(hostId = null)
        val found = ConsoleInfo("192.168.1.20", "ps5-a", true, hostId = "1C98C1AABBCC")
        assertTrue(ConsoleIdentity.isRegistered(found, legacy))
        val learned = ConsoleIdentity.updated(legacy, found)!!
        assertEquals("1C98C1AABBCC", learned.hostId)
        assertEquals("192.168.1.20", learned.host)
        assertEquals("PS5-A", learned.name)
        assertEquals("PS5 kimliği kayda yazıldı: 1C98C1AABBCC", ConsoleIdentity.changeLine(legacy, learned))
        assertNull(ConsoleIdentity.updated(learned, found))
    }

    /** Eski biçimde saklanmış kayıt ("hostId" yok) okunur; yeni alan kaydedilip geri okunur. */
    @Test
    fun storedRecordWithoutHostIdStillDecodes() {
        val old = """{"host":"192.168.1.20","name":"PS5-A","registKey":"MDEyM2FiY2Q=","morning":"BwcHBwcHBwcHBwcHBwcHBw=="}"""
        val console = RegisteredConsole.fromJson(old)!!
        assertNull(console.hostId)
        assertEquals(0x0123abcdL, console.wakeCredential)
        val roundTrip = RegisteredConsole.fromJson(saved().toJson())!!
        assertEquals("1C98C1AABBCC", roundTrip.hostId)
        assertArrayEquals(saved().morning, roundTrip.morning)
        assertEquals("1C98C1AABBCC", saved().withHost("10.0.0.5").hostId)
        assertNull(RegisteredConsole.fromJson("{}"))
    }

    @Test
    fun moveIsLoggedWithHowItWasFound() {
        assertEquals("PS5 yeni adreste bulundu: 192.168.1.20 → 192.168.1.44 (host-id ile)",
            ConsoleIdentity.changeLine(saved(), saved().withHost("192.168.1.44")))
        assertEquals("PS5 yeni adreste bulundu: 192.168.1.20 → 192.168.1.44 (adıyla)",
            ConsoleIdentity.changeLine(saved(hostId = null), saved(host = "192.168.1.44", hostId = null)))
    }

    /** İlk tarama hemen; bulunamazsa 10 sn, 30 sn, 1 dk, 2 dk, sonra hep 5 dk beklenir (#1366). Bağlantı kopunca yine hemen. */
    @Test
    fun relocateScheduleShortensAfterAFailure() {
        val schedule = RelocateSchedule()
        val now = 1_000_000L
        assertTrue(schedule.isDue(now))
        for (wait in longArrayOf(10_000, 30_000, 60_000, 120_000, 300_000, 300_000)) {
            schedule.searched(false, now)
            assertFalse(schedule.isDue(now + wait - 1_000))
            assertTrue(schedule.isDue(now + wait))
        }
        schedule.connectionFailed()
        assertTrue(schedule.isDue(now))
        schedule.searched(true, now)
        assertTrue(schedule.isDue(now))
    }

    /** Kayıtlı adreste başka PS5 var: ağ taranır, PS5 kimliğiyle yeni adreste bulunur, kayıt güncellenip bildirilir. */
    @Test
    fun finderRelocatesAndReportsTheNewAddress() {
        val mine = ConsoleInfo("192.168.1.44", "PS5-A", true, hostId = "1C98C1AABBCC")
        val other = ConsoleInfo("192.168.1.20", "PS5-A", true, hostId = "F8461C000001")
        val asked = mutableListOf<String?>()
        val lines = mutableListOf<String>()
        val finder = ConsoleFinder(saved(), { host ->
            asked += host
            when (host) {
                null -> listOf(other, mine)
                "192.168.1.20" -> listOf(other)
                else -> emptyList()
            }
        }, { lines += it })
        var reported: RegisteredConsole? = null
        finder.onChange = { reported = it }
        val located = finder.locate()
        assertEquals(mine, located.info)
        assertEquals(other, located.atHost)
        assertEquals(listOf("192.168.1.20", null), asked)
        assertEquals("192.168.1.44", reported?.host)
        assertEquals("192.168.1.44", finder.console.host)
        assertTrue(lines.last(), lines.last().startsWith("PS5 yeni adreste bulundu: 192.168.1.20 → 192.168.1.44 (host-id ile)"))
    }

    /** PS5 bulunamadı: sonraki tarama 10 sn bekler (her denemede ağ taranmaz); bağlantı kopunca hemen taranır. */
    @Test
    fun finderDoesNotRescanImmediatelyAfterAMiss() {
        var scans = 0
        val finder = ConsoleFinder(saved(), { host ->
            if (host == null) scans++
            emptyList()
        }, noLog, clock = { 5_000L })
        assertNull(finder.locate().info)
        assertNull(finder.locate().info)
        assertEquals(1, scans)
        finder.connectionFailed()
        assertNull(finder.locate().info)
        assertEquals(2, scans)
    }
}
