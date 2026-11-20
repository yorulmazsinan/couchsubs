// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * "Çeviriyi başlatınca uygulama kapanıyor" bildirimlerinde Crashlytics boştu: yerel çökme, bellek yetmemesi ve ANR
 * Crashlytics'e hiç düşmüyordu. Önceki kapanışlar bir sonraki açılışta raporlanır.
 */
class ExitReportTest {
    private fun record(reason: Int, at: Long, description: String? = null) =
        ExitRecord(reason, at, description, importance = 125, pssKb = 300 * 1024L, rssKb = 400 * 1024L)

    @Test
    fun nativeCrashLowMemoryAndAnrAreReportedJavaCrashAndUserExitAreNot() {
        val records = listOf(
            record(ExitReport.REASON_CRASH_NATIVE, 50, "crash"),
            record(ExitReport.REASON_CRASH, 40),
            record(ExitReport.REASON_LOW_MEMORY, 30),
            record(10, 20), // USER_REQUESTED
            record(ExitReport.REASON_ANR, 10),
            record(1, 5), // EXIT_SELF
        )
        val reported = ExitReport.reportable(records, lastSeen = 0)
        assertEquals(listOf(ExitReport.REASON_ANR, ExitReport.REASON_LOW_MEMORY, ExitReport.REASON_CRASH_NATIVE), reported.map { it.reason })
    }

    @Test
    fun sameExitIsNotReportedTwice() {
        val records = listOf(record(ExitReport.REASON_CRASH_NATIVE, 50), record(ExitReport.REASON_LOW_MEMORY, 30))
        val seen = ExitReport.newestTimestamp(records, lastSeen = 0)
        assertEquals(50, seen)
        assertTrue(ExitReport.reportable(records, seen).isEmpty())
        // Yeni kapanış geldiğinde yalnız o raporlanır.
        val later = listOf(record(ExitReport.REASON_SIGNALED, 70)) + records
        assertEquals(listOf(70L), ExitReport.reportable(later, seen).map { it.timestamp })
        // Kayıt yoksa son görülen değişmez.
        assertEquals(50, ExitReport.newestTimestamp(emptyList(), 50))
    }

    @Test
    fun messageNamesReasonTranslationAndMemory() {
        val message = ExitReport.message(record(ExitReport.REASON_LOW_MEMORY, 1, "lmk"), duringTranslation = true)
        assertEquals("low_memory (çeviri sürerken): lmk importance=125 pss=300MB rss=400MB; son durum: ilk 10 dk içinde", message)
        assertEquals("crash_native: - importance=125 pss=300MB rss=400MB", ExitReport.message(record(ExitReport.REASON_CRASH_NATIVE, 1), false))
    }
    /** Uzun oyunda (40-45 dk) kapanma bildirimi: kapanış raporunda oturum süresi, bellek ve ısı da görünür. */
    @Test
    fun translationExitCarriesLastHealthLine() {
        val record = record(ExitReport.REASON_LOW_MEMORY, 1, "lmk")
        assertEquals("low_memory (çeviri sürerken): lmk importance=125 pss=300MB rss=400MB; son durum: oturum 40 dk; bellek 812 MB",
            ExitReport.message(record, duringTranslation = true, lastHealth = "oturum 40 dk; bellek 812 MB"))
        assertEquals("low_memory (çeviri sürerken): lmk importance=125 pss=300MB rss=400MB; son durum: ilk 10 dk içinde",
            ExitReport.message(record, duringTranslation = true, lastHealth = null))
        // Çeviri dışındaki kapanışa eski satır eklenmez.
        assertEquals("low_memory: lmk importance=125 pss=300MB rss=400MB", ExitReport.message(record, false, "oturum 40 dk"))
    }

    @Test
    fun healthLineMatchesIphoneFormat() {
        assertEquals("oturum 40 dk; bellek 812 MB (boş 310 MB); bellek uyarısı 2; ısı yüksek",
            SessionHealth.line(40, 812, 310, 2, thermal = 2))
        assertEquals("oturum 0 dk; bellek 300 MB; bellek uyarısı 0; ısı normal", SessionHealth.line(-1, 300, null, 0, 0))
        // PowerManager.THERMAL_STATUS_*: 0 yok, 1-2 hafif/orta, 3 ciddi, 4+ kritik.
        assertEquals(listOf(0, 1, 1, 2, 3, 3, 3), (0..6).map(SessionHealth::thermalLevel))
    }
}
