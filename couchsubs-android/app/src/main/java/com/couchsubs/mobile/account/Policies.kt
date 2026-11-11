// SPDX-License-Identifier: AGPL-3.0-only
// İzinle ilgili saf kurallar (Android'e bağlı değil; JVM testleri: AccountPoliciesTest).
package com.couchsubs.mobile.account


/**
 * Kullanıcının izin seçimi (KVKK/GDPR). İlk açılışta sorulur; karar verilene kadar hiçbir ölçüm ve reklam kimliği
 * toplanmaz. [analytics]: Firebase Analytics ve Crashlytics. [ads]: Meta App Events (reklam ölçümü), reklam kimliği ve
 * kişiselleştirilmiş reklam.
 */
data class ConsentChoice(val decided: Boolean = false, val analytics: Boolean = false, val ads: Boolean = false)

/** İzin ve uzak ayarlardan türeyen, SDK'lara verilecek bayraklar. */
data class ConsentFlags(
    val analyticsCollection: Boolean,
    val crashReports: Boolean,
    /** Firebase Consent Mode v2. */
    val analyticsStorage: Boolean,
    val adStorage: Boolean,
    val adUserData: Boolean,
    val adPersonalization: Boolean,
    /** Meta SDK: App Events otomatik kaydı ve reklam kimliği. */
    val metaEnabled: Boolean,
    /** AdMob başlatılsın ve reklam gösterilsin mi. */
    val showAds: Boolean,
    /** Kişiselleştirilmemiş reklam istenmeli mi (npa=1). */
    val nonPersonalizedAds: Boolean,
)

object ConsentPolicy {
    /**
     * [adsEnabledRemote]: Firebase Remote Config "ads_enabled" (varsayılan false: reklam hiç gösterilmez).
     * [umpCanRequestAds]: Google UMP formu reklam istemeye izin veriyor mu (AEA/İngiltere'de form, başka yerde true).
     */
    fun flags(choice: ConsentChoice, adsEnabledRemote: Boolean, umpCanRequestAds: Boolean): ConsentFlags {
        val analytics = choice.decided && choice.analytics
        val ads = choice.decided && choice.ads
        return ConsentFlags(
            analyticsCollection = analytics,
            crashReports = analytics,
            analyticsStorage = analytics,
            adStorage = ads,
            adUserData = ads,
            adPersonalization = ads,
            metaEnabled = ads,
            showAds = choice.decided && adsEnabledRemote && umpCanRequestAds,
            nonPersonalizedAds = !ads,
        )
    }
}
