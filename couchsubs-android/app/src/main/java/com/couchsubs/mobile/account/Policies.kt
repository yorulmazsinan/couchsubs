// SPDX-License-Identifier: AGPL-3.0-only
// Hesap, abonelik ve izinle ilgili saf kurallar (Android'e bağlı değil; JVM testleri: AccountPoliciesTest).
package com.couchsubs.mobile.account

import java.math.BigDecimal
import java.math.RoundingMode
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

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

/** RevenueCat'teki bir hakkın anlık görüntüsü (SDK'nın EntitlementInfo'sundan). */
data class EntitlementSnapshot(
    val isActive: Boolean,
    val expiresAtMillis: Long?,
    val willRenew: Boolean,
    val productId: String?,
)

/** Kullanıcının paket aboneliği. */
data class PackAccess(
    val active: Boolean,
    val expiresAtMillis: Long? = null,
    val willRenew: Boolean = false,
    val plan: PlanKind? = null,
) {
    companion object {
        const val ENTITLEMENT = "packs"
        val None = PackAccess(false)

        /**
         * RevenueCat hakkından paket erişimi. SDK "isActive"ı önbellekten verir; süresi geçmiş ama hâlâ etkin görünen
         * hak (cihaz saati, önbellek) burada da kapalı sayılır.
         */
        fun from(entitlements: Map<String, EntitlementSnapshot>, nowMillis: Long): PackAccess {
            val info = entitlements[ENTITLEMENT] ?: return None
            val expires = info.expiresAtMillis
            val active = info.isActive && (expires == null || expires > nowMillis)
            return PackAccess(active, expires, info.willRenew, PlanKind.fromProduct(info.productId))
        }
    }
}

enum class PlanKind(val productId: String, val packageId: String) {
    MONTHLY("couchsubs_packs_monthly", "\$rc_monthly"),
    ANNUAL("couchsubs_packs_annual", "\$rc_annual");

    companion object {
        /** Play ürün kimliği "couchsubs_packs_annual" ya da "couchsubs_packs_annual:yillik" (temel plan ekiyle). */
        fun fromProduct(productId: String?): PlanKind? = productId?.substringBefore(':')?.let { id -> entries.firstOrNull { it.productId == id } }
    }
}

/** Satın alma ekranında gösterilen plan; fiyat metinleri RevenueCat'in (Play'in) verdiğidir. */
data class Plan(
    val kind: PlanKind,
    val price: String,
    /** Yıllık planda aylık karşılığı ("299 TL/ay" için "₺299,00"); aylıkta null. */
    val perMonth: String?,
    val priceMicros: Long,
    val currency: String,
)

object Pricing {
    /** Yıllık fiyatın aylık karşılığı, para biriminin yerel biçimiyle (3.588 TL → 299 TL). */
    fun perMonth(annualMicros: Long, currency: String, locale: Locale = Locale("tr", "TR")): String {
        val monthly = BigDecimal.valueOf(annualMicros).divide(BigDecimal.valueOf(12_000_000L), 2, RoundingMode.HALF_UP)
        return NumberFormat.getCurrencyInstance(locale).apply { this.currency = Currency.getInstance(currency) }.format(monthly)
    }

    /** Yıllık planın aylığa göre kazancı, yüzde (aylık 399, yıllık 3.588 → 25). */
    fun savingPercent(monthlyMicros: Long, annualMicros: Long): Int {
        if (monthlyMicros <= 0) return 0
        val yearOfMonthly = monthlyMicros * 12.0
        return ((1 - annualMicros / yearOfMonthly) * 100).toInt().coerceAtLeast(0)
    }
}

/** Paket araması ne zaman yapılır. */
object PackGate {
    /**
     * Abonelik etkin ve ayarlarda paketler açık olmalı. [debugFree]: yalnız hata ayıklama derlemesinde, ayarlardaki
     * "abonelik olmadan dene" anahtarı (mağaza derlemesinde her zaman false).
     */
    fun allowed(access: PackAccess, packsEnabled: Boolean, debugFree: Boolean): Boolean =
        packsEnabled && (access.active || debugFree)
}
