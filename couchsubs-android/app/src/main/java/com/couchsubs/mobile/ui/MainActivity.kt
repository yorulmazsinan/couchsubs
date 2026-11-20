// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import android.graphics.Color
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContentTransitionScope.SlideDirection
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Telemetry
import com.couchsubs.mobile.promo.PromoController
import com.couchsubs.mobile.service.LiveState
import com.couchsubs.mobile.service.TranslationService
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.tv.TvAppUpdate

/** Gezinme yolları (Compose Navigation). */
object Routes {
    const val WELCOME = "welcome"
    const val PSN = "psn"
    const val PAIR = "pair"
    const val TARGET = "target"
    const val MAIN = "main"
    const val PACKS = "packs"
    const val PROFILE = "profile"
    const val SETTINGS = "settings"
    const val TV_INSTALL = "tvinstall"
    const val HISTORY = "history"
    const val PLATFORM = "platform"
    const val XBOX_LOGIN = "xboxlogin"
    const val XBOX_CONSOLE = "xboxconsole"

    /** Kurulumun eksik ilk adımı; hepsi tamamsa ana ekran. */
    fun next(): String {
        val settings = Services.settings
        return when {
            !settings.welcomeSeen -> WELCOME
            // Konsol türü bir kez sorulur; PS5'i önceden eşlenmiş kurulumlar PlayStation sayılır.
            settings.platformChoice == null && settings.accountId == null && settings.console == null && !settings.setupSkipped -> PLATFORM
            // Xbox (Beta): Microsoft girişi ve Xbox seçimi; ikinci hesap (PSN) adımı yok.
            settings.xbox && !Services.xboxAuth.signedIn && !settings.setupSkipped -> XBOX_LOGIN
            settings.xbox && settings.xboxConsole == null && !settings.setupSkipped -> XBOX_CONSOLE
            settings.xbox -> if (!settings.onboarded) TARGET else MAIN
            // "Şimdilik geç" ile atlandıysa PS5'siz ana ekrana gidilir (ör. Play incelemesi); eşleme Ayarlar'dan.
            settings.accountId == null && !settings.setupSkipped -> PSN
            settings.console == null && !settings.setupSkipped -> PAIR
            !settings.onboarded -> TARGET
            else -> MAIN
        }
    }
}

/** Ekran geçişinin süresi (ms) ve kayma payı (genişliğin 1/n'i). */
private const val NAV_MS = 280
private const val NAV_SHIFT = 8

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Uygulama hep koyu; sistem açık temadayken de durum çubuğu simgeleri açık renk kalsın.
        enableEdgeToEdge(SystemBarStyle.dark(Color.TRANSPARENT), SystemBarStyle.dark(Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        val settings = Services.settings
        // Tanıtım popup'ı: uygulama ön plana her geldiğinde (soğuk açılışta hemen, sonra en çok günde bir) promo.json'a
        // arka planda bakılır; ağ hatası sessizdir. Kurulum ya da ilk tur bitmediyse bu açılışta hazırlanmaz.
        lifecycle.addObserver(androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_START)
                PromoController.refresh(applicationContext, Services.scope, setupDone = Routes.next() == Routes.MAIN && settings.tourShown)
        })
        setContent {
            CouchSubsTheme {
                val navigation = rememberNavController()
                val currentEntry by navigation.currentBackStackEntryAsState()
                val status by LiveState.status.collectAsState()
                TvPairingDialog(status.pairing)
                LaunchedEffect(status.running) {
                    if (status.running && settings.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                // Masaüstündeki gibi: uygulama açılınca ve TV her bağlandığında TV'deki CouchSubs sürümüne bakılır;
                // eskiyse ana ekran "TV uygulamasını güncelle" önerir.
                val tvConnected = status.connectedTvs > 0
                LaunchedEffect(tvConnected) { TvAppUpdate.check(applicationContext) }
                DisposableEffect(navigation) {
                    val listener = androidx.navigation.NavController.OnDestinationChangedListener { _, destination, _ ->
                        destination.route?.let { Telemetry.screen(it.substringBefore('/')) }
                    }
                    navigation.addOnDestinationChangedListener(listener)
                    onDispose { navigation.removeOnDestinationChangedListener(listener) }
                }
                // Ekranlar arası geçiş: yeni ekran sağdan biraz kayarak ve solarak gelir, geri dönüşte tersi (~280 ms).
                // Sistemde animasyonlar kapalıysa Compose süreleri kendisi sıfırlar.
                NavHost(
                    navigation, startDestination = Routes.next(),
                    enterTransition = { slideIntoContainer(SlideDirection.Start, tween(NAV_MS), initialOffset = { it / NAV_SHIFT }) + fadeIn(tween(NAV_MS)) },
                    exitTransition = { slideOutOfContainer(SlideDirection.Start, tween(NAV_MS), targetOffset = { it / NAV_SHIFT }) + fadeOut(tween(NAV_MS)) },
                    popEnterTransition = { slideIntoContainer(SlideDirection.End, tween(NAV_MS), initialOffset = { it / NAV_SHIFT }) + fadeIn(tween(NAV_MS)) },
                    popExitTransition = { slideOutOfContainer(SlideDirection.End, tween(NAV_MS), targetOffset = { it / NAV_SHIFT }) + fadeOut(tween(NAV_MS)) },
                ) {
                    composable(Routes.WELCOME) {
                        WelcomeScreen(onDemo = { startDemo(navigation) }) {
                            settings.welcomeSeen = true
                            Services.applyMeasurement()
                            advance(navigation)
                        }
                    }
                    composable(Routes.PSN) {
                        PsnLoginScreen(onBack = back(navigation), onSkip = skip(navigation)) {
                            // Ana ekrandan eşlemeye gelindiyse girişten sonra eşleme ekranı açılır.
                            if (settings.console == null && navigation.previousBackStackEntry != null)
                                navigation.navigate(Routes.PAIR) { popUpTo(Routes.PSN) { inclusive = true } }
                            else advance(navigation)
                        }
                    }
                    composable(Routes.PLATFORM) { PlatformScreen(onBack = back(navigation)) { advance(navigation) } }
                    composable(Routes.XBOX_LOGIN) {
                        XboxLoginScreen(onBack = back(navigation), onSkip = skip(navigation)) {
                            if (settings.xboxConsole == null && navigation.previousBackStackEntry != null)
                                navigation.navigate(Routes.XBOX_CONSOLE) { popUpTo(Routes.XBOX_LOGIN) { inclusive = true } }
                            else advance(navigation)
                        }
                    }
                    composable(Routes.XBOX_CONSOLE) {
                        XboxConsoleScreen(onBack = back(navigation), onSkip = skip(navigation),
                            onSignIn = { navigation.navigate(Routes.XBOX_LOGIN) }) { advance(navigation) }
                    }
                    composable(Routes.PAIR) { PairScreen(onBack = back(navigation), onSkip = skip(navigation)) { advance(navigation) } }
                    composable(Routes.TARGET) {
                        val onboarding = navigation.previousBackStackEntry == null
                        TargetScreen(onBack = back(navigation), onTvInstall = { navigation.navigate(Routes.TV_INSTALL) }) {
                            if (onboarding) Telemetry.event(Telemetry.ONBOARDING_DONE, "target" to settings.target.name.lowercase())
                            advance(navigation)
                        }
                    }
                    composable(Routes.MAIN) {
                        MainScreen(
                            status = status,
                            onStart = ::startTranslation,
                            onStop = { TranslationService.stop(this@MainActivity) },
                            onDemo = { startDemo(navigation) },
                            onExitDemo = { exitDemo(navigation) },
                            onPhoneView = { startActivity(Intent(this@MainActivity, PhoneSubtitleActivity::class.java)) },
                            onTarget = { navigation.navigate(Routes.TARGET) },
                            onPairing = { pairing(navigation) },
                            onPacks = { navigation.navigate(Routes.PACKS) },
                            onProfile = { navigation.navigate(Routes.PROFILE) },
                            onSettings = { navigation.navigate(Routes.SETTINGS) },
                            onHistory = { navigation.navigate(Routes.HISTORY) },
                            onTvUpdate = { tv ->
                                TvAppUpdate.pending = tv
                                navigation.navigate(Routes.TV_INSTALL)
                            },
                            onHome = currentEntry?.destination?.route == Routes.MAIN,
                        )
                    }
                    composable(Routes.PACKS) {
                        PacksScreen(onBack = { pop(navigation) }, packInUse = status.packInUse)
                    }
                    composable(Routes.PROFILE) {
                        ProfileScreen(
                            onBack = { pop(navigation) },
                            onSettings = { navigation.navigate(Routes.SETTINGS) },
                            onPairing = { pairing(navigation) },
                            onTarget = { navigation.navigate(Routes.TARGET) },
                            onPsn = { navigation.navigate(Routes.PSN) },
                        )
                    }
                    composable(Routes.SETTINGS) {
                        SettingsScreen(onBack = { pop(navigation) }, onPacks = { navigation.navigate(Routes.PACKS) },
                            onTarget = { navigation.navigate(Routes.TARGET) }, onPairing = { pairing(navigation) },
                            onTvInstall = { navigation.navigate(Routes.TV_INSTALL) },
                            onPlatform = { navigation.navigate(Routes.PLATFORM) }, onDemo = { startDemo(navigation) })
                    }
                    composable(Routes.HISTORY) { HistoryScreen(onBack = { pop(navigation) }) }
                    composable(Routes.TV_INSTALL) {
                        // Kurulum bitince "Ana ekrana geç": kurulumun 3. adımından gelindiyse kurulum biter (TvAppUpdate.installed).
                        TvInstallScreen(onBack = { pop(navigation) }) {
                            if (Routes.next() == Routes.MAIN) navigation.navigate(Routes.MAIN) { popUpTo(0) { inclusive = true } }
                            else pop(navigation)
                        }
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
        // Ayarlar'dan konsol türü değişince eksik adım (ör. Microsoft girişi) açılır.
        if (next != Routes.MAIN && navigation.previousBackStackEntry != null && next in setOf(Routes.XBOX_LOGIN, Routes.XBOX_CONSOLE, Routes.PSN, Routes.PAIR)) {
            navigation.navigate(next) { popUpTo(navigation.currentDestination?.route ?: next) { inclusive = true } }
            return
        }
        if (next == Routes.MAIN && navigation.previousBackStackEntry != null) {
            pop(navigation)
            return
        }
        navigation.navigate(next) { popUpTo(0) { inclusive = true } }
    }

    /**
     * Bir ekran geri döner; yığında önceki ekran yoksa hiçbir şey yapmaz. Kapanma animasyonu sürerken geri düğmesine
     * ikinci kez dokunulunca düz `popBackStack()` ana ekranı da yığından atar, ekran boş kalırdı (iPhone'daki
     * `Route` yığınının `pop`'uyla aynı kural).
     */
    private fun pop(navigation: NavHostController) {
        if (navigation.previousBackStackEntry != null) navigation.popBackStack()
    }

    /** Ana ekrandan açılmış adımda geri düğmesi; kurulumda (yığında önceki ekran yok) düğme görünmez. */
    private fun back(navigation: NavHostController): (() -> Unit)? =
        if (navigation.previousBackStackEntry != null) ({ pop(navigation) }) else null

    /** Kurulumda (yığında önceki ekran yok) "Şimdilik geç": PSN ve PS5 adımları atlanır, PS5'siz ana ekrana geçilir. */
    private fun skip(navigation: NavHostController): (() -> Unit)? =
        if (navigation.previousBackStackEntry == null) ({
            Services.settings.setupSkipped = true
            advance(navigation)
        }) else null

    /** PS5 eşleme: PSN girişi yoksa (kurulum atlandıysa) önce giriş, ardından eşleme. */
    private fun pairing(navigation: NavHostController) {
        val settings = Services.settings
        if (settings.xbox) navigation.navigate(if (!Services.xboxAuth.signedIn) Routes.XBOX_LOGIN else Routes.XBOX_CONSOLE)
        else navigation.navigate(if (settings.accountId == null) Routes.PSN else Routes.PAIR)
    }

    /**
     * Deneme modu (iPhone ve Mac ile aynı): kurulumun hangi adımından açılırsa açılsın çeviri ekranı örnek karelerle
     * açılır; çalışan çeviri önce durdurulur.
     */
    private fun startDemo(navigation: NavHostController) {
        if (LiveState.status.value.running) TranslationService.stop(this)
        // Durdurma isteği hizmete önce ulaşsın; yeni oturum ardından deneme kaynağıyla açılır.
        window.decorView.postDelayed({ TranslationService.startDemo(this) }, if (LiveState.status.value.running) 600L else 0L)
        navigation.navigate(Routes.MAIN) { popUpTo(0) { inclusive = true } }
    }

    /** Deneme modundan çıkar; kurulum bitmemişse eksik adıma dönülür. */
    private fun exitDemo(navigation: NavHostController) {
        TranslationService.stop(this)
        val next = Routes.next()
        if (next != Routes.MAIN) navigation.navigate(next) { popUpTo(0) { inclusive = true } }
    }

    private fun startTranslation() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        TranslationService.start(this)
        if (Services.settings.target == SubtitleTarget.PHONE) startActivity(Intent(this, PhoneSubtitleActivity::class.java))
    }
}
