// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

import android.content.Context
import android.os.Bundle
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.analytics.FirebaseAnalytics
import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * Firebase'e tek giriş noktası: Analytics ve Crashlytics (hesap yok, reklam yok; uygulama tamamen ücretsiz).
 * app/google-services.json yoksa Firebase hiç açılmaz ([available] false): ölçüm ve çökme raporu sessizce atlanır.
 */
object Backend {
    private const val TAG = "CouchSubsBackend"
    @Volatile var available = false
        private set
    private var analytics: FirebaseAnalytics? = null

    fun init(context: Context) {
        available = try {
            FirebaseApp.getApps(context).isNotEmpty() || FirebaseApp.initializeApp(context) != null
        } catch (error: Exception) {
            Log.w(TAG, "Firebase yok", error)
            false
        }
        if (!available) return
        analytics = FirebaseAnalytics.getInstance(context)
    }

    /**
     * Profil › Kullanım verisi değişince ölçüm ve çökme raporu açılır/kapanır. Reklam depolama ve kişiselleştirme
     * (Consent Mode v2) her zaman kapalıdır; reklam kimliği manifestte kapalıdır.
     */
    fun apply(flags: MeasurementFlags) {
        if (!available) return
        analytics?.setAnalyticsCollectionEnabled(flags.analyticsCollection)
        analytics?.setConsent(
            mapOf(
                FirebaseAnalytics.ConsentType.ANALYTICS_STORAGE to status(flags.analyticsCollection),
                FirebaseAnalytics.ConsentType.AD_STORAGE to status(false),
                FirebaseAnalytics.ConsentType.AD_USER_DATA to status(false),
                FirebaseAnalytics.ConsentType.AD_PERSONALIZATION to status(false),
            )
        )
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(flags.crashReports)
    }

    private fun status(granted: Boolean) =
        if (granted) FirebaseAnalytics.ConsentStatus.GRANTED else FirebaseAnalytics.ConsentStatus.DENIED

    internal fun analyticsOrNull() = analytics

    fun recordError(error: Throwable) {
        if (available) FirebaseCrashlytics.getInstance().recordException(error)
    }
}

/**
 * Ürün olayları. Firebase'in ayrılmış adları (session_start, first_open…) kullanılamadığı için okuma oturumu
 * "subtitle_session_start/stop" adını taşır.
 */
object Telemetry {
    const val PACK_HIT = "pack_hit"
    const val SESSION_START = "subtitle_session_start"
    const val SESSION_STOP = "subtitle_session_stop"
    const val TV_CONNECTED = "tv_connected"
    const val ONBOARDING_DONE = "onboarding_done"

    fun event(name: String, vararg params: Pair<String, Any?>) {
        Meta.mirror(name)
        val analytics = Backend.analyticsOrNull() ?: return
        analytics.logEvent(name, Bundle().apply {
            for ((key, value) in params) when (value) {
                is String -> putString(key, value)
                is Int -> putLong(key, value.toLong())
                is Long -> putLong(key, value)
                is Double -> putDouble(key, value)
                is Boolean -> putString(key, value.toString())
                null -> {}
                else -> putString(key, value.toString())
            }
        })
    }

    fun screen(route: String) {
        val analytics = Backend.analyticsOrNull() ?: return
        analytics.logEvent(FirebaseAnalytics.Event.SCREEN_VIEW, Bundle().apply {
            putString(FirebaseAnalytics.Param.SCREEN_NAME, route)
            putString(FirebaseAnalytics.Param.SCREEN_CLASS, "Compose")
        })
    }
}
