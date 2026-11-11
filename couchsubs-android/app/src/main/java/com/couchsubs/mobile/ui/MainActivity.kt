// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Ads
import com.couchsubs.mobile.account.RemoteFlags
import com.couchsubs.mobile.account.Telemetry
import com.couchsubs.mobile.service.LiveState
import com.couchsubs.mobile.service.TranslationService
import com.couchsubs.mobile.settings.SubtitleTarget

/** Gezinme yolları (Compose Navigation). */
object Routes {
    const val CONSENT = "consent"
    const val WELCOME = "welcome"
    const val PSN = "psn"
    const val PAIR = "pair"
    const val TARGET = "target"
    const val MAIN = "main"
    const val PACKS = "packs"
    const val PROFILE = "profile"
    const val SETTINGS = "settings"
    const val PRIVACY = "privacy"

    /** Kurulumun eksik ilk adımı; hepsi tamamsa ana ekran. */
    fun next(): String {
        val settings = Services.settings
        return when {
            !settings.consent.decided -> CONSENT
            !settings.welcomeSeen -> WELCOME
            settings.accountId == null -> PSN
            settings.console == null -> PAIR
            !settings.onboarded -> TARGET
            else -> MAIN
        }
    }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val settings = Services.settings
        setContent {
            CouchSubsTheme {
                val navigation = rememberNavController()
                val status by LiveState.status.collectAsState()
                val adsEnabled by RemoteFlags.adsEnabled.collectAsState()
                LaunchedEffect(status.running) {
                    if (status.running && settings.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                // Reklam yalnız uzak ayarla açılırsa Google'ın izin formu (AEA/İngiltere) sorulur.
                LaunchedEffect(adsEnabled) { if (adsEnabled) Ads.requestUmpIfNeeded(this@MainActivity, true) {} }
                DisposableEffect(navigation) {
                    val listener = androidx.navigation.NavController.OnDestinationChangedListener { _, destination, _ ->
                        destination.route?.let { Telemetry.screen(it.substringBefore('/')) }
                    }
                    navigation.addOnDestinationChangedListener(listener)
                    onDispose { navigation.removeOnDestinationChangedListener(listener) }
                }
                NavHost(navigation, startDestination = Routes.next()) {
                    composable(Routes.CONSENT) { ConsentScreen { advance(navigation) } }
                    composable(Routes.WELCOME) {
                        WelcomeScreen {
                            settings.welcomeSeen = true
                            advance(navigation)
                        }
                    }
                    composable(Routes.PSN) { PsnLoginScreen(onBack = back(navigation)) { advance(navigation) } }
                    composable(Routes.PAIR) { PairScreen(onBack = back(navigation)) { advance(navigation) } }
                    composable(Routes.TARGET) {
                        val onboarding = navigation.previousBackStackEntry == null
                        TargetScreen(onBack = back(navigation)) {
                            if (onboarding) Telemetry.event(Telemetry.ONBOARDING_DONE, "target" to settings.target.name.lowercase())
                            advance(navigation)
                        }
                    }
                    composable(Routes.MAIN) {
                        MainScreen(
                            status = status,
                            onStart = ::startTranslation,
                            onStop = { TranslationService.stop(this@MainActivity) },
                            onPhoneView = { startActivity(Intent(this@MainActivity, PhoneSubtitleActivity::class.java)) },
                            onTarget = { navigation.navigate(Routes.TARGET) },
                            onPairing = { navigation.navigate(Routes.PAIR) },
                            onPacks = { navigation.navigate(Routes.PACKS) },
                            onProfile = { navigation.navigate(Routes.PROFILE) },
                            onSettings = { navigation.navigate(Routes.SETTINGS) },
                        )
                    }
                    composable(Routes.PACKS) {
                        PacksScreen(onBack = { navigation.popBackStack() }, packInUse = status.packInUse)
                    }
                    composable(Routes.PROFILE) {
                        ProfileScreen(
                            onBack = { navigation.popBackStack() },
                            onSettings = { navigation.navigate(Routes.SETTINGS) },
                            onPairing = { navigation.navigate(Routes.PAIR) },
                            onTarget = { navigation.navigate(Routes.TARGET) },
                            onPsn = { navigation.navigate(Routes.PSN) },
                            onPrivacy = { navigation.navigate(Routes.PRIVACY) },
                        )
                    }
                    composable(Routes.PRIVACY) { ConsentScreen(editing = true) { navigation.popBackStack() } }
                    composable(Routes.SETTINGS) {
                        SettingsScreen(onBack = { navigation.popBackStack() }, onPacks = { navigation.navigate(Routes.PACKS) },
                            onTarget = { navigation.navigate(Routes.TARGET) }, onPairing = { navigation.navigate(Routes.PAIR) })
                    }
                }
            }
        }
    }

    /**
     * Kurulumda bir sonraki eksik adıma geçer. Ana ekrandan açılmış bir adım (ör. Profil › Eşlemeyi yenile) bitince
     * geri dönülür.
     */
    private fun advance(navigation: NavHostController) {
        val next = Routes.next()
        if (next == Routes.MAIN && navigation.previousBackStackEntry != null) {
            navigation.popBackStack()
            return
        }
        navigation.navigate(next) { popUpTo(0) { inclusive = true } }
    }

    /** Ana ekrandan açılmış adımda geri düğmesi; kurulumda (yığında önceki ekran yok) düğme görünmez. */
    private fun back(navigation: NavHostController): (() -> Unit)? =
        if (navigation.previousBackStackEntry != null) ({ navigation.popBackStack() }) else null

    private fun startTranslation() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        TranslationService.start(this)
        if (Services.settings.target == SubtitleTarget.PHONE) startActivity(Intent(this, PhoneSubtitleActivity::class.java))
    }
}
