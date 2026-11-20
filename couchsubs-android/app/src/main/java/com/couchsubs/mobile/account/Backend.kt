// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

import android.app.ActivityManager
import android.content.Context
import android.os.Build
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
        flagsAllowCrashReports = flags.crashReports
    }

    private fun status(granted: Boolean) =
        if (granted) FirebaseAnalytics.ConsentStatus.GRANTED else FirebaseAnalytics.ConsentStatus.DENIED

    internal fun analyticsOrNull() = analytics

    /** Çökme raporunda görünecek iz satırı (çeviri başlarken hangi adımda kalındığı). */
    fun breadcrumb(message: String) {
        Log.i(TAG, message)
        if (available) FirebaseCrashlytics.getInstance().log(message)
    }

    fun recordError(error: Throwable) {
        if (available) FirebaseCrashlytics.getInstance().recordException(error)
    }

    /**
     * Android'in kaydettiği önceki kapanışlardan Crashlytics'in göremediklerini (yerel çökme, bellek yetmedi, ANR)
     * raporlar (bkz. [ExitReport]). [lastSeen] son raporlanan kapanışın anı; dönen değer yenisi. [duringTranslation]:
     * en son kapanış çeviri sürerken mi oldu. Ağır değil ama IPC'dir; ana iş parçacığında çağrılmamalı.
     */
    fun reportPreviousExits(context: Context, lastSeen: Long, duringTranslation: Boolean, lastHealth: String? = null): Long {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return lastSeen
        val records = try {
            context.getSystemService(ActivityManager::class.java).getHistoricalProcessExitReasons(null, 0, 10).map {
                ExitRecord(it.reason, it.timestamp, it.description, it.importance, it.pss, it.rss)
            }
        } catch (error: Exception) {
            Log.w(TAG, "kapanış nedenleri", error)
            return lastSeen
        }
        val reportable = ExitReport.reportable(records, lastSeen)
        val newest = reportable.lastOrNull()
        for (record in reportable) {
            val translating = duringTranslation && record === newest
            val message = ExitReport.message(record, translating, lastHealth)
            Log.w(TAG, "önceki kapanış: $message")
            if (available && flagsAllowCrashReports) {
                val crashlytics = FirebaseCrashlytics.getInstance()
                crashlytics.setCustomKey("exit_reason", ExitReport.reasonName(record.reason))
                crashlytics.setCustomKey("exit_during_translation", translating)
                crashlytics.recordException(PreviousExitException(message))
            }
            Telemetry.event("app_exit", "reason" to ExitReport.reasonName(record.reason), "during_translation" to translating)
        }
        return ExitReport.newestTimestamp(records, lastSeen)
    }

    /** Kullanım verisi kapalıysa Crashlytics'e elle de bir şey gönderilmez. */
    @Volatile private var flagsAllowCrashReports = false
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
