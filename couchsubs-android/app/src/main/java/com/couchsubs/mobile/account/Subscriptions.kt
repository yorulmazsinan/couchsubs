// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

import android.app.Activity
import android.content.Context
import android.util.Log
import com.couchsubs.mobile.BuildConfig
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.Package
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchasesError
import com.revenuecat.purchases.getCustomerInfoWith
import com.revenuecat.purchases.getOfferingsWith
import com.revenuecat.purchases.interfaces.UpdatedCustomerInfoListener
import com.revenuecat.purchases.logInWith
import com.revenuecat.purchases.logOutWith
import com.revenuecat.purchases.purchaseWith
import com.revenuecat.purchases.restorePurchasesWith
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class PurchaseException(val cancelled: Boolean, message: String) : Exception(message)

/**
 * Paket aboneliği (RevenueCat + Google Play Billing). RevenueCat, Firebase UID'siyle tanınır (appUserID), böylece paket
 * sunucusu (server/packs) aynı kimlikle hakkı sorar. Hak: "packs"; teklif: "default" ($rc_monthly, $rc_annual).
 * RevenueCat anahtarı yoksa ([available] false) satın alma ekranı "Yakında" der.
 */
object Subscriptions {
    private const val TAG = "CouchSubsBilling"
    const val OFFERING = "default"

    private val accessState = MutableStateFlow(PackAccess.None)
    val access: StateFlow<PackAccess> = accessState
    @Volatile var available = false
        private set
    private var configured = false
    private var pendingUser: String? = null

    fun init(context: Context) {
        val key = BuildConfig.REVENUECAT_API_KEY
        if (key.isBlank()) return
        try {
            Purchases.configure(PurchasesConfiguration.Builder(context, key).apply { pendingUser?.let { appUserID(it) } }.build())
            Purchases.sharedInstance.updatedCustomerInfoListener = UpdatedCustomerInfoListener(::publish)
            configured = true
            available = true
            Purchases.sharedInstance.getCustomerInfoWith({ Log.w(TAG, it.message) }, ::publish)
        } catch (error: Exception) {
            Log.w(TAG, "RevenueCat açılamadı", error)
        }
    }

    /** Firebase kullanıcısı değişince: giriş yapan UID ile tanınır, çıkışta anonim kullanıcıya döner. */
    fun identify(uid: String?) {
        if (!configured) {
            pendingUser = uid
            return
        }
        val purchases = Purchases.sharedInstance
        if (uid != null && purchases.appUserID != uid) purchases.logInWith(uid, { Log.w(TAG, it.message) }) { info, _ -> publish(info) }
        else if (uid == null && !purchases.isAnonymous) purchases.logOutWith({ Log.w(TAG, it.message) }, ::publish)
        if (uid == null) accessState.value = PackAccess.None
    }

    private fun publish(info: CustomerInfo) {
        val snapshots = info.entitlements.all.mapValues { (_, value) ->
            EntitlementSnapshot(value.isActive, value.expirationDate?.time, value.willRenew, value.productIdentifier)
        }
        accessState.value = PackAccess.from(snapshots, System.currentTimeMillis())
    }

    /** Aboneliği yönetme sayfası (Play'in abonelikler sayfası, bu ürünle). */
    fun manageUrl(context: Context, plan: PlanKind?): String =
        "https://play.google.com/store/account/subscriptions?package=${context.packageName}" + (plan?.let { "&sku=${it.productId}" } ?: "")

    /** "default" teklifindeki aylık ve yıllık plan; fiyat metinleri Play'den. */
    suspend fun plans(): List<Pair<Plan, Package>> {
        if (!available) return emptyList()
        return suspendCancellableCoroutine { continuation ->
            Purchases.sharedInstance.getOfferingsWith({ continuation.resumeWithException(PurchaseException(false, it.message)) }) { offerings ->
                val offering = offerings[OFFERING] ?: offerings.current
                val monthly = offering?.monthly
                val annual = offering?.annual
                val result = mutableListOf<Pair<Plan, Package>>()
                monthly?.let { pkg ->
                    val price = pkg.product.price
                    result.add(Plan(PlanKind.MONTHLY, price.formatted, null, price.amountMicros, price.currencyCode) to pkg)
                }
                annual?.let { pkg ->
                    val price = pkg.product.price
                    result.add(Plan(PlanKind.ANNUAL, price.formatted, Pricing.perMonth(price.amountMicros, price.currencyCode), price.amountMicros, price.currencyCode) to pkg)
                }
                continuation.resume(result)
            }
        }
    }

    suspend fun purchase(activity: Activity, plan: Plan, pkg: Package): PackAccess = suspendCancellableCoroutine { continuation ->
        Purchases.sharedInstance.purchaseWith(
            PurchaseParams.Builder(activity, pkg).build(),
            onError = { error: PurchasesError, cancelled: Boolean -> continuation.resumeWithException(PurchaseException(cancelled, error.message)) },
            onSuccess = { _, info ->
                publish(info)
                Telemetry.event(Telemetry.PURCHASE, "plan" to plan.kind.name.lowercase(), "value" to plan.priceMicros / 1_000_000.0,
                    "currency" to plan.currency)
                continuation.resume(accessState.value)
            },
        )
    }

    suspend fun restore(): PackAccess = suspendCancellableCoroutine { continuation ->
        Purchases.sharedInstance.restorePurchasesWith({ continuation.resumeWithException(PurchaseException(false, it.message)) }) { info ->
            publish(info)
            continuation.resume(accessState.value)
        }
    }
}
