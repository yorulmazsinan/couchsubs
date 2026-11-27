// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReconnectTest {
    /** PS5 oturumu birkaç saniyede düşürüyorsa aralık sıfırlanmaz; uzun süren oturumdan sonra baştan başlar (Mac ve Windows ile aynı). */
    @Test
    fun shortSessionsKeepBackingOff() {
        val policy = ReconnectPolicy()
        assertEquals(2, policy.nextDelaySeconds())
        policy.connected(10_000)
        policy.ended(14_000)
        // Bağlı oturum kopunca PS5 eski oturumu bıraksın diye en az 8 sn.
        assertEquals(8, policy.nextDelaySeconds())
        policy.connected(20_000)
        policy.ended(20_000 + ReconnectPolicy.STABLE_AFTER_MS)
        assertEquals(8, policy.nextDelaySeconds())
        // Bağlanamayan denemeler büyümeye devam eder.
        assertEquals(16, policy.nextDelaySeconds())
    }

    /** Redmi Pad, iPad: birer dakika süren oturumlar aralığı sıfırlıyor, her dakika bağlanıp kopuyordu. */
    @Test
    fun minuteLongSessionsKeepBackingOff() {
        val policy = ReconnectPolicy()
        val delays = List(4) { round ->
            val connected = round * 1_000_000L
            policy.connected(connected)
            policy.ended(connected + 90_000)
            policy.nextDelaySeconds()
        }
        assertEquals(listOf(8, 16, 32, 60), delays)
    }

    /** Üç dört dakikada bir kopan ağda bekleme büyümez (5 dk kuralında 8, 16, 32, 60 sn diye büyüyüp 60 sn'de kalıyordu). */
    @Test
    fun sessionsOfAFewMinutesRetryAfterEightSeconds() {
        val policy = ReconnectPolicy()
        val delays = List(4) { round ->
            val connected = round * 1_000_000L
            policy.connected(connected)
            policy.ended(connected + 180_000)
            policy.nextDelaySeconds()
        }
        assertEquals(listOf(8, 8, 8, 8), delays)
    }

    @Test
    fun backoffDoublesUpToSixtySeconds() {
        val policy = ReconnectPolicy()
        assertEquals(listOf(2, 4, 8, 16, 32, 60, 60), List(7) { policy.nextDelaySeconds() })
    }

    @Test
    fun inUseWaitsAtLeastEightSeconds() {
        val policy = ReconnectPolicy()
        assertEquals(listOf(8, 16, 32), List(3) { policy.nextDelaySeconds(inUse = true) })
    }

    /** Kablosuz ağda akış sık kopuyordu (GitHub #388, #401): on dakikada iki kopmadan sonra 720p istenir. */
    @Test
    fun twoDropsWithinWindowLowerTo720p() {
        val quality = QualityFallback()
        assertFalse(quality.dropped(0))
        assertFalse(quality.lowered)
        assertTrue(quality.dropped(120_000))
        assertTrue(quality.lowered)
        assertFalse(quality.dropped(130_000))
        assertTrue(quality.lowered)
    }

    @Test
    fun dropsFarApartKeep1080p() {
        val quality = QualityFallback()
        assertFalse(quality.dropped(0))
        assertFalse(quality.dropped(QualityFallback.WINDOW_MS + 1))
        assertFalse(quality.dropped(2 * QualityFallback.WINDOW_MS + 2))
        assertFalse(quality.lowered)
    }

    @Test
    fun onlyNetworkLikeDropsCount() {
        assertTrue(QualityFallback.countsAsDrop(DisconnectKind.NETWORK))
        assertTrue(QualityFallback.countsAsDrop(DisconnectKind.OTHER))
        for (kind in listOf(DisconnectKind.IN_USE, DisconnectKind.REJECTED, DisconnectKind.REGISTRATION_INVALID, DisconnectKind.STOPPED))
            assertFalse(QualityFallback.countsAsDrop(kind))
    }

    /** 0x80108b26: PS5 bu cihazın eşlemesini bulamadı (yeniden eşlenmeli); 0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9). */
    @Test
    fun knownApplicationReasonsAreClassified() {
        assertEquals(DisconnectKind.REGISTRATION_INVALID,
            DisconnectKind.sessionRequestHint("Reported Application Reason: 0x80108b26 (unknown)")?.kind)
        assertEquals(SessionState.Disconnected(DisconnectKind.REJECTED, DisconnectKind.REMOTE_PLAY_DISABLED),
            DisconnectKind.sessionRequestHint("Reported Application Reason: 0x80108b12 (unknown)"))
    }

    /**
     * X, 21 Kas: oyun sırasında PS5'te ana hesaba geçince PS5 akışı kendisi kapatıyor. Ağ kopması değildir: ayrı neden,
     * 720p'ye düşürme sayılmaz, PS5 aramaya yanıt vermese de "bulunamadı"ya çevrilmez.
     */
    @Test
    fun consoleClosedStreamIsNotANetworkDrop() {
        assertEquals(DisconnectKind.CONSOLE_CLOSED, DisconnectKind.fromNative(NativeBridge.QUIT_CONSOLE_CLOSED))
        assertFalse(QualityFallback.countsAsDrop(DisconnectKind.CONSOLE_CLOSED))
        val closed = SessionState.Disconnected(DisconnectKind.CONSOLE_CLOSED, "Client disconnected")
        assertEquals(closed, ConsoleSearchState().classify(closed, "192.168.1.70"))
    }

    /** GitHub #519: PS5'teki Uzaktan Oynatma çöktüyse İngilizce libchiaki metni (OTHER) değil, ayrı bir neden. */
    @Test
    fun consoleRemotePlayCrashIsItsOwnKind() {
        assertEquals(DisconnectKind.CONSOLE_RP_CRASHED, DisconnectKind.fromNative(NativeBridge.QUIT_RP_CRASHED))
        assertEquals(DisconnectKind.STOPPED, DisconnectKind.fromNative(NativeBridge.QUIT_STOPPED))
        assertEquals(DisconnectKind.IN_USE, DisconnectKind.fromNative(NativeBridge.QUIT_IN_USE))
        assertEquals(DisconnectKind.REFUSED, DisconnectKind.fromNative(NativeBridge.QUIT_REFUSED))
        assertEquals(DisconnectKind.NETWORK, DisconnectKind.fromNative(NativeBridge.QUIT_NETWORK))
        assertEquals(DisconnectKind.OTHER, DisconnectKind.fromNative(NativeBridge.QUIT_OTHER))
        // TCP reddi eşleme sorunu değildir; yalnız PSN eşlemesinin reddi yeniden eşleme ister.
        assertEquals(DisconnectKind.REGISTRATION_INVALID, DisconnectKind.fromNative(NativeBridge.QUIT_PSN_REGIST_FAILED))
        // 720p'ye düşürme nedeni değildir.
        assertFalse(QualityFallback.countsAsDrop(DisconnectKind.CONSOLE_RP_CRASHED))
    }

    /** GitHub #519: PS5 çöktü dedikçe sonsuza kadar yeniden bağlanmak yerine iki denemeden sonra durulur. */
    @Test
    fun consoleRemotePlayCrashStopsAfterTwoRetries() {
        val limit = CrashRetryLimit()
        assertEquals(2, CrashRetryLimit.MAX_RETRIES)
        assertTrue(limit.crashed())
        assertTrue(limit.crashed())
        assertFalse(limit.crashed())
        assertFalse(limit.crashed())
        assertEquals(4, limit.crashes)
        // Çeviri yeniden başlatılınca, ağ değişince ya da bağlanınca sayaç baştan.
        limit.reset()
        assertEquals(0, limit.crashes)
        assertTrue(limit.crashed())
    }

    /** GitHub #353: PS5 akışı kendisi kapattı (ikinci hesap PS5'te seçildi) → en çok bir yeniden deneme, sonra dur. */
    @Test
    fun consoleClosedRetriesOnceThenStops() {
        val limit = ReconnectLimit()
        assertEquals(1, ReconnectLimit.MAX_CONSOLE_CLOSED_RETRIES)
        val closed = DisconnectKind.fromNative(NativeBridge.QUIT_CONSOLE_CLOSED)
        limit.connected(1_000)
        assertNull(limit.ended(closed, 21_000))          // 1. kapatma: bir kez yeniden dene
        limit.connected(41_000)                           // yeniden bağlandı, kısa sürdü
        assertEquals(DisconnectKind.CONSOLE_CLOSED_REPEATEDLY, limit.ended(DisconnectKind.CONSOLE_CLOSED, 61_000))
    }

    /** Ağ kopmasında beklemeli deneme sürer ama art arda beşten fazla olmaz; sonra "Yeniden bağlan". */
    @Test
    fun networkDropsStopAfterFiveRetries() {
        val limit = ReconnectLimit()
        assertEquals(5, ReconnectLimit.MAX_NETWORK_RETRIES)
        for (kind in listOf(DisconnectKind.NETWORK, DisconnectKind.NOT_FOUND, DisconnectKind.REFUSED, DisconnectKind.OTHER,
                DisconnectKind.fromNative(NativeBridge.QUIT_NETWORK))) assertNull(limit.ended(kind, 0))
        assertEquals(DisconnectKind.RECONNECT_GAVE_UP, limit.ended(DisconnectKind.NETWORK, 0))
    }

    /** PS5 kapalıyken açılması, başka cihazda kullanılırken bırakılması beklenir: bunlar sayılmaz. */
    @Test
    fun waitingReasonsAreNotCounted() {
        val limit = ReconnectLimit()
        repeat(20) {
            assertNull(limit.ended(DisconnectKind.CONSOLE_ASLEEP, 0))
            assertNull(limit.ended(DisconnectKind.IN_USE, 0))
        }
        assertEquals(0, limit.networkFailures)
        assertEquals(0, limit.consoleClosed)
    }

    /** Uzun (kararlı) oturumdan sonraki kapatma yeni sayılır; saatler sonra yine hesap değişirse bir deneme var. */
    @Test
    fun stableSessionResetsLimitCounters() {
        val limit = ReconnectLimit()
        assertNull(limit.ended(DisconnectKind.CONSOLE_CLOSED, 0))
        repeat(5) { assertNull(limit.ended(DisconnectKind.NETWORK, 0)) }
        limit.connected(0)
        assertNull(limit.ended(DisconnectKind.CONSOLE_CLOSED, ReconnectPolicy.STABLE_AFTER_MS))
        assertEquals(0, limit.networkFailures)
        assertEquals(1, limit.consoleClosed)
        // Çeviri yeniden başlayınca, ağ değişince ya da "Yeniden bağlan"a basınca sayaçlar baştan.
        assertEquals(DisconnectKind.CONSOLE_CLOSED_REPEATEDLY, limit.ended(DisconnectKind.CONSOLE_CLOSED, 0))
        limit.reset()
        assertNull(limit.ended(DisconnectKind.CONSOLE_CLOSED, 0))
    }

    /** CouchSubs kendi PS5 oturumunu kapatınca günlükte nedeniyle görünür (Windows ve Mac/iPhone ile aynı metin). */
    @Test
    fun closingLineNamesOurOwnConnectionAndTheReason() {
        assertEquals(
            "PS5 oturumu: CouchSubs kendi PS5 bağlantısını kapatıyor (çeviri durdu)",
            StreamSession.closingLine("çeviri durdu"),
        )
    }
}
