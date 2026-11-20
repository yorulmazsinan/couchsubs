// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Bağlıyken görüntü kesilince oturum yeniden kurulur (Mac/Windows ile aynı kural). */
class PictureWatchdogTest {
    /**
     * Hata: istenen IDR karesi de bozuk gelince libchiaki yeniden istemiyor, bağlantı açık kalıp hiç kare gelmiyordu;
     * oturum hiç yeniden kurulmuyor, altyazı ancak uygulamayı kapatıp açınca dönüyordu.
     */
    @Test
    fun connectedWithoutPictureForFifteenSecondsIsStalled() {
        val watchdog = PictureWatchdog()
        watchdog.connected(0)
        for (second in 1..120) watchdog.picture(second * 1000L)
        // İki dakika görüntü geldi, sonra kesildi.
        assertNull(watchdog.stalledMs(134_000))
        assertEquals(PictureWatchdog.STALL_AFTER_MS, watchdog.stalledMs(135_000))
    }

    /** GitHub #593: libchiaki IDR'yi saniyede bir yeniden isterken 8-14 sn'lik boşluk oturumu kapatmaz. */
    @Test
    fun idrRetryWindowIsNotAStall() {
        val watchdog = PictureWatchdog()
        watchdog.connected(0)
        watchdog.picture(1000)
        assertNull(watchdog.stalledMs(15_000))
    }

    /** Olağan FEC duraklaması (IDR bir saniyeden kısa sürede gelir) oturumu yeniden kurdurmaz. */
    @Test
    fun shortGapIsNotAStall() {
        val watchdog = PictureWatchdog()
        watchdog.connected(0)
        watchdog.picture(1000)
        watchdog.picture(2500)
        assertNull(watchdog.stalledMs(9000))
    }

    /** Bağlandıktan sonra ilk kare hiç gelmezse de yakalanır. */
    @Test
    fun noFirstPictureIsStalled() {
        val watchdog = PictureWatchdog()
        watchdog.connected(0)
        assertNotNull(watchdog.stalledMs(PictureWatchdog.STALL_AFTER_MS))
    }

    /** İlk kare 5 sn'de gelmezse takılma sayılır (çözücü türü değiştirilip yeniden denenecek). */
    @Test
    fun firstPictureMissingForFiveSecondsIsStalled() {
        val watchdog = PictureWatchdog()
        watchdog.connected(0)
        assertNull(watchdog.stalledMs(PictureWatchdog.FIRST_PICTURE_MS - 1))
        assertNotNull(watchdog.stalledMs(PictureWatchdog.FIRST_PICTURE_MS))
    }

    /**
     * Hata: hiç görüntü gelmeyen oturum her 8 sn'de bir sonsuza dek yeniden kuruluyordu ("Bağlantı koptu, yeniden
     * bağlanılıyor"). Şimdi öbür çözücü türü denenir, art arda 3 görüntüsüz oturumdan sonra durulur.
     */
    @Test
    fun noPictureSessionsSwapDecoderThenGiveUp() {
        val watchdog = PictureWatchdog()
        assertEquals(false, watchdog.swapDecoder)
        watchdog.connected(0)
        assertEquals(PictureWatchdog.Next.RECONNECT_OTHER_DECODER, watchdog.stalled())
        assertEquals(true, watchdog.swapDecoder)
        watchdog.ended()
        watchdog.connected(10_000)
        assertEquals(PictureWatchdog.Next.RECONNECT_OTHER_DECODER, watchdog.stalled())
        assertEquals(false, watchdog.swapDecoder)
        watchdog.ended()
        watchdog.connected(20_000)
        assertEquals(PictureWatchdog.Next.GIVE_UP, watchdog.stalled())
        watchdog.reset()
        assertEquals(0, watchdog.noPictureStreak)
    }

    /** Görüntü gelmiş oturum kesilirse aynı çözücüyle yeniden kurulur; görüntü sayacı sıfırlar. */
    @Test
    fun pictureResetsNoPictureStreak() {
        val watchdog = PictureWatchdog()
        watchdog.connected(0)
        watchdog.stalled()
        watchdog.ended()
        watchdog.connected(10_000)
        watchdog.picture(11_000)
        assertEquals(0, watchdog.noPictureStreak)
        assertEquals(false, watchdog.swapDecoder)
        assertEquals(PictureWatchdog.Next.RECONNECT, watchdog.stalled())
    }

    /** Bağlı değilken görüntü beklenmez; geç gelen eski kare de bekçiyi kurmaz. */
    @Test
    fun notConnectedIsNeverStalled() {
        val watchdog = PictureWatchdog()
        watchdog.picture(0)
        assertNull(watchdog.stalledMs(600_000))
        watchdog.connected(0)
        watchdog.ended()
        assertNull(watchdog.stalledMs(600_000))
    }
}
