// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.util.Log
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.couchsubs.mobile.BuildConfig
import com.facebook.FacebookSdk
import com.facebook.appevents.AppEventsConstants
import com.facebook.appevents.AppEventsLogger
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.MobileAds
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.UserMessagingPlatform
import java.util.Currency

/**
 * Reklam tarafı: Meta App Events (reklam kampanyalarının kurulum ve satın alma ölçümü) ve AdMob. İkisi de yalnız izinle
 * açılır; AdMob ayrıca Remote Config "ads_enabled" açılmadıkça hiç başlatılmaz ve reklam göstermez (varsayılan kapalı).
 */
object Ads {
    private const val TAG = "CouchSubsAds"
    private var application: Application? = null
    @Volatile private var metaOn = false
    @Volatile private var adsStarted = false
    @Volatile var flags: ConsentFlags = ConsentPolicy.flags(ConsentChoice(), false, false)
        private set

    fun init(app: Application) {
        application = app
    }

    /** İzin ya da uzak ayar değişince çağrılır. */
    fun apply(newFlags: ConsentFlags) {
        flags = newFlags
        val app = application ?: return
        applyMeta(app, newFlags.metaEnabled)
        if (newFlags.showAds && !adsStarted) {
            adsStarted = true
            MobileAds.initialize(app) {}
        }
    }

    private fun applyMeta(app: Application, enabled: Boolean) {
        if (BuildConfig.FACEBOOK_APP_ID.isBlank()) return
        try {
            if (enabled && !metaOn) {
                // Otomatik başlatma manifestte kapalı (izinden önce hiçbir şey gitmesin); izinle burada açılır.
                FacebookSdk.setAutoInitEnabled(true)
                @Suppress("DEPRECATION")
                FacebookSdk.sdkInitialize(app)
                FacebookSdk.setAutoLogAppEventsEnabled(true)
                FacebookSdk.setAdvertiserIDCollectionEnabled(true)
                AppEventsLogger.activateApp(app)
                metaOn = true
            } else if (!enabled && metaOn) {
                FacebookSdk.setAutoLogAppEventsEnabled(false)
                FacebookSdk.setAdvertiserIDCollectionEnabled(false)
                metaOn = false
            }
        } catch (error: Exception) {
            Log.w(TAG, "Meta SDK", error)
        }
    }

    /** Ürün olaylarından reklam ölçümü için gerekenler Meta'nın standart olaylarına çevrilir. */
    fun mirror(name: String, params: Map<String, Any?>) {
        if (!metaOn) return
        val app = application ?: return
        val logger = AppEventsLogger.newLogger(app)
        when (name) {
            Telemetry.SIGN_UP -> logger.logEvent(AppEventsConstants.EVENT_NAME_COMPLETED_REGISTRATION,
                Bundle().apply { putString(AppEventsConstants.EVENT_PARAM_REGISTRATION_METHOD, params["method"]?.toString()) })
            Telemetry.PURCHASE -> {
                val value = (params["value"] as? Double) ?: return
                val currency = params["currency"]?.toString() ?: return
                logger.logEvent(AppEventsConstants.EVENT_NAME_SUBSCRIBE, value,
                    Bundle().apply { putString(AppEventsConstants.EVENT_PARAM_CURRENCY, Currency.getInstance(currency).currencyCode) })
            }
        }
    }

    /** UMP (AEA/İngiltere'de Google'ın izin formu); yalnız reklam açılacaksa sorulur. */
    fun requestUmpIfNeeded(activity: Activity, adsEnabledRemote: Boolean, done: (Boolean) -> Unit) {
        if (!adsEnabledRemote) return done(false)
        val info = UserMessagingPlatform.getConsentInformation(activity)
        info.requestConsentInfoUpdate(activity, ConsentRequestParameters.Builder().build(), {
            UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity) { done(info.canRequestAds()) }
        }, { done(info.canRequestAds()) })
    }

    fun umpCanRequestAds(context: Context): Boolean = UserMessagingPlatform.getConsentInformation(context).canRequestAds()
}

/** Banner yeri: reklam kapalıyken (varsayılan) hiçbir şey çizmez. */
@Composable
fun AdBanner(modifier: Modifier = Modifier) {
    val flags = Ads.flags
    if (!flags.showAds) return
    AndroidView(modifier = modifier.fillMaxWidth(), factory = { context ->
        AdView(context).apply {
            setAdSize(AdSize.BANNER)
            adUnitId = BuildConfig.ADMOB_BANNER_ID
            val request = AdRequest.Builder()
            if (flags.nonPersonalizedAds) request.addNetworkExtrasBundle(com.google.ads.mediation.admob.AdMobAdapter::class.java, Bundle().apply { putString("npa", "1") })
            loadAd(request.build())
        }
    })
}
