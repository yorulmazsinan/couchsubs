// SPDX-License-Identifier: AGPL-3.0-only
// Telefon kilitliyken çevirinin sürmesi: çeviri ön plan hizmetinde, işlemci ve Wi-Fi kilidiyle çalışır. Pil
// optimizasyonu ya da arka plan kısıtlaması açıksa bazı telefonlar (Vivo, Xiaomi, Oppo, Samsung) ekran kapanınca hizmeti
// yavaşlatıyor, ağını kesiyor ya da kapatıyor; bu durumda kullanıcıya söylenir ve ayara tek dokunuşla gidilir.
package com.couchsubs.mobile.ui

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import com.couchsubs.mobile.R

object BackgroundLimits {
    /** Sistem bu uygulamanın arka planda çalışmasını kısıtlıyor mu (pil optimizasyonu ya da arka plan kısıtlaması). */
    fun restricted(context: Context): Boolean = try {
        val power = context.getSystemService(PowerManager::class.java)
        val optimized = power?.isIgnoringBatteryOptimizations(context.packageName) == false
        val background = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context.getSystemService(ActivityManager::class.java)?.isBackgroundRestricted == true
        optimized || background
    } catch (error: RuntimeException) {
        false
    }

    /** Uygulamanın sistem ayarları (Pil › Kısıtlamasız buradan seçilir); açılamazsa pil optimizasyonu listesi. */
    fun openSettings(context: Context) {
        val app = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        for (intent in listOf(app, list)) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (error: RuntimeException) {
                Log.w("CouchSubsBattery", "Ayar açılamadı: ${intent.action}", error)
            }
        }
    }
}

/**
 * Pil kısıtlaması açıksa uyarı ve ayara giden düğme; kısıtlama yoksa hiçbir şey çizmez. Ayardan dönülünce (pencere
 * yeniden odak alınca) yeniden bakılır.
 */
@Composable
internal fun BackgroundLimitNote() {
    val context = LocalContext.current
    var restricted by remember { mutableStateOf(BackgroundLimits.restricted(context)) }
    val focused = LocalWindowInfo.current.isWindowFocused
    LaunchedEffect(focused) { if (focused) restricted = BackgroundLimits.restricted(context) }
    if (!restricted) return
    Tile(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.background_limit_title), style = Tokens.Type.headline, color = Tokens.Color.text)
        Text(stringResource(R.string.background_limit_body), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        GhostButton(stringResource(R.string.background_limit_button)) { BackgroundLimits.openSettings(context) }
    }
}
