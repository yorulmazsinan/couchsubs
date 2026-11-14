// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

import android.app.Application
import android.util.Log
import com.couchsubs.mobile.BuildConfig
import com.facebook.FacebookSdk
import com.facebook.appevents.AppEventsLogger

/**
 * Meta App Events (iPhone'daki Measurement.swift ile aynı): kimlikler secrets.properties'te yoksa hiç açılmaz. Reklam
 * kimliği hiç toplanmaz; otomatik olaylar karşılama ekranından sonra ve Kullanım verisi açıkken gider. Uygulamada
 * reklam yoktur.
 */
object Meta {
    private const val TAG = "CouchSubsMeta"
    private var application: Application? = null
    @Volatile private var started = false
    @Volatile private var eventsOn = false

    private val configured get() = BuildConfig.FACEBOOK_APP_ID.isNotBlank()

    fun init(app: Application) {
        application = app
    }

    fun apply(flags: MeasurementFlags) {
        val app = application ?: return
        if (!configured) return
        try {
            if (!started) {
                // Otomatik başlatma manifestte kapalı; burada reklam kimliği kapalıyken açılır.
                FacebookSdk.setAdvertiserIDCollectionEnabled(false)
                FacebookSdk.setAutoInitEnabled(true)
                @Suppress("DEPRECATION")
                FacebookSdk.sdkInitialize(app)
                started = true
            }
            FacebookSdk.setAdvertiserIDCollectionEnabled(false)
            FacebookSdk.setAutoLogAppEventsEnabled(flags.metaEvents)
            if (flags.metaEvents && !eventsOn) AppEventsLogger.activateApp(app)
            eventsOn = flags.metaEvents
        } catch (error: Exception) {
            Log.w(TAG, "Meta SDK", error)
        }
    }

    /** Ürün olayının yalnız adı gider (parametre yok). */
    fun mirror(name: String) {
        if (!eventsOn) return
        val app = application ?: return
        runCatching { AppEventsLogger.newLogger(app).logEvent(name) }
    }
}
