// SPDX-License-Identifier: AGPL-3.0-only
// Ölçümle ilgili saf kurallar (Android'e bağlı değil; JVM testleri: MeasurementPolicyTest).
package com.couchsubs.mobile.account

/**
 * SDK'lara verilecek bayraklar. Reklam yok (AdMob ve Google'ın izin formu UMP yok); reklam kimliği hiç toplanmaz.
 * iPhone uygulamasıyla aynı: tek anahtar Profil › Kullanım verisi (varsayılan açık).
 */
data class MeasurementFlags(
    /** Firebase Analytics ve Crashlytics. */
    val analyticsCollection: Boolean,
    val crashReports: Boolean,
    /** Meta App Events: olayın adı ve otomatik açılış/kurulum olayları (reklam kimliği olmadan). */
    val metaEvents: Boolean,
)

object MeasurementPolicy {
    /**
     * [usageData]: Profil › Kullanım verisi. [welcomeSeen]: karşılama ekranı geçildi mi; Meta'nın otomatik olayları
     * iPhone'daki gibi karşılamadan sonra açılır.
     */
    fun flags(usageData: Boolean, welcomeSeen: Boolean) = MeasurementFlags(
        analyticsCollection = usageData,
        crashReports = usageData,
        metaEvents = usageData && welcomeSeen,
    )
}
