// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

/**
 * Uygulamanın önceki kapanışlarından biri (Android 11+ ApplicationExitInfo'dan; Android'e bağlı değil, JVM testi:
 * ExitReportTest).
 */
data class ExitRecord(
    val reason: Int,
    val timestamp: Long,
    val description: String?,
    /** Kapanış anında süreç ön planda mıydı (ActivityManager.RunningAppProcessInfo.IMPORTANCE_*). */
    val importance: Int,
    val pssKb: Long,
    val rssKb: Long,
)

/**
 * Crashlytics yalnız Java çökmelerini görür: yerel kütüphanedeki (libchiaki, MediaCodec) çökme, sistemin belleği
 * yetmediği için süreci öldürmesi ve ANR hiç raporlanmaz. "Çeviriyi başlatınca uygulama kapanıyor" bildirimlerinde
 * Crashlytics boştu. Bir sonraki açılışta Android'in kaydettiği kapanış nedeni okunup raporlanır.
 */
object ExitReport {
    // ApplicationExitInfo.REASON_* (API 30); JVM testinde android.jar olmadan da okunabilsin diye burada.
    const val REASON_SIGNALED = 2
    const val REASON_LOW_MEMORY = 3
    const val REASON_CRASH = 4
    const val REASON_CRASH_NATIVE = 5
    const val REASON_ANR = 6
    const val REASON_INITIALIZATION_FAILURE = 7
    const val REASON_EXCESSIVE_RESOURCE_USAGE = 9

    /**
     * Raporlanan nedenler. Java çökmesi (REASON_CRASH) Crashlytics'te zaten var; kullanıcının kapatması, güncelleme
     * ve izin değişikliği hata değildir.
     */
    private val reported = setOf(
        REASON_SIGNALED, REASON_LOW_MEMORY, REASON_CRASH_NATIVE, REASON_ANR, REASON_INITIALIZATION_FAILURE,
        REASON_EXCESSIVE_RESOURCE_USAGE,
    )

    /** [lastSeen]'den sonraki raporlanacak kapanışlar, eskiden yeniye. */
    fun reportable(records: List<ExitRecord>, lastSeen: Long): List<ExitRecord> =
        records.filter { it.timestamp > lastSeen && it.reason in reported }.sortedBy { it.timestamp }

    /** Kayıtların en yenisinin anı (hiç yoksa [lastSeen]); bir dahaki açılışta aynı kapanış yeniden raporlanmaz. */
    fun newestTimestamp(records: List<ExitRecord>, lastSeen: Long): Long = maxOf(lastSeen, records.maxOfOrNull { it.timestamp } ?: lastSeen)

    fun reasonName(reason: Int): String = when (reason) {
        REASON_SIGNALED -> "signaled"
        REASON_LOW_MEMORY -> "low_memory"
        REASON_CRASH -> "crash"
        REASON_CRASH_NATIVE -> "crash_native"
        REASON_ANR -> "anr"
        REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        else -> "reason_$reason"
    }

    /**
     * Crashlytics'te kümelenecek hata satırı: neden başlıkta, ayrıntı iletide. Çeviri sürerken kapandıysa son sağlık
     * satırı ([SessionHealth]; oturum süresi, bellek, ısı) da eklenir.
     */
    fun message(record: ExitRecord, duringTranslation: Boolean, lastHealth: String? = null): String =
        "${reasonName(record.reason)}${if (duringTranslation) " (çeviri sürerken)" else ""}: ${record.description ?: "-"}" +
            " importance=${record.importance} pss=${record.pssKb / 1024}MB rss=${record.rssKb / 1024}MB" +
            if (duringTranslation) "; son durum: ${lastHealth ?: "ilk 10 dk içinde"}" else ""
}

/**
 * Uzun oturumun sağlık satırı. Telefon uygulamasının uzun oyunda (40-45 dk) kendiliğinden kapandığı bildirildi; çeviri
 * sürerken on dakikada bir bellek, ısı ve oturum süresi Crashlytics izine yazılır ve saklanır, süreç ölürse bir sonraki
 * açılışta kapanış nedeniyle birlikte raporlanır ([ExitReport.message]). iPhone'daki SessionHealth ile aynı biçim.
 */
object SessionHealth {
    const val INTERVAL_MS = 10 * 60 * 1000L

    /** PowerManager.THERMAL_STATUS_* (0 yok … 6 kapanma) iPhone'un dört basamağına (normal, orta, yüksek, kritik). */
    fun thermalLevel(status: Int): Int = when {
        status <= 0 -> 0
        status <= 2 -> 1
        status == 3 -> 2
        else -> 3
    }

    fun thermalName(level: Int): String = when {
        level < 1 -> "normal"
        level == 1 -> "orta"
        level == 2 -> "yüksek"
        else -> "kritik"
    }

    /** "oturum 40 dk; bellek 812 MB (boş 310 MB); bellek uyarısı 2; ısı yüksek" */
    fun line(minutes: Long, memoryMb: Long, availableMb: Long?, memoryWarnings: Int, thermal: Int): String =
        "oturum ${maxOf(0L, minutes)} dk; bellek $memoryMb MB" + (availableMb?.let { " (boş $it MB)" } ?: "") +
            "; bellek uyarısı $memoryWarnings; ısı ${thermalName(thermal)}"
}

/** Önceki kapanış; Crashlytics'te ölümcül olmayan hata olarak görünür (yığın izi yok, neden iletide). */
class PreviousExitException(message: String) : Exception(message)
