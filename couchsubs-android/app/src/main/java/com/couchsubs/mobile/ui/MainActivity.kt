// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.couchsubs.mobile.service.LiveState
import com.couchsubs.mobile.service.TranslationService
import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.settings.SubtitleTarget

/** Ekranlar arası basit geçiş; tasarım onaylanınca yerini gerçek gezinme alacak. */
enum class Screen { WELCOME, PSN, PAIR, TARGET, MAIN, SETTINGS }

class MainActivity : ComponentActivity() {
    private lateinit var settings: AppSettings

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = AppSettings(this)
        val first = if (settings.onboarded && settings.console != null && settings.accountId != null) Screen.MAIN else Screen.WELCOME
        setContent {
            CouchSubsTheme {
                var screen by remember { mutableStateOf(first) }
                val status by LiveState.status.collectAsState()
                LaunchedEffect(status.running) {
                    if (status.running && settings.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                BackHandler(enabled = screen == Screen.SETTINGS) { screen = Screen.MAIN }
                when (screen) {
                    Screen.WELCOME -> WelcomeScreen { screen = Screen.PSN }
                    Screen.PSN -> PsnLoginScreen(settings) { screen = Screen.PAIR }
                    Screen.PAIR -> PairScreen(settings) { screen = Screen.TARGET }
                    Screen.TARGET -> TargetScreen(settings) {
                        settings.onboarded = true
                        screen = Screen.MAIN
                    }
                    Screen.MAIN -> MainScreen(
                        status = status,
                        target = settings.target,
                        onStart = ::startTranslation,
                        onStop = { TranslationService.stop(this) },
                        onPhoneView = { startActivity(Intent(this, PhoneSubtitleActivity::class.java)) },
                        onSettings = { screen = Screen.SETTINGS },
                    )
                    Screen.SETTINGS -> SettingsScreen(settings, onBack = { screen = Screen.MAIN }, onRepair = { screen = Screen.PSN })
                }
            }
        }
    }

    private fun startTranslation() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        TranslationService.start(this)
        if (settings.target == SubtitleTarget.PHONE) startActivity(Intent(this, PhoneSubtitleActivity::class.java))
    }
}
