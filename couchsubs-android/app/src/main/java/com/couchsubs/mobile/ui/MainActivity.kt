// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import android.graphics.Color
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Telemetry
import com.couchsubs.mobile.promo.PromoController
import com.couchsubs.mobile.promo.PromoPolicy
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
    /** Kurulumda TV adımından sonra: PS5 TV'nin hangi girişine takılı (Mac ve iPhone ile aynı adım). */
    const val HDMI = "hdmi"

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
/** Geçiş animasyonları kapalıyken kullanılan kısa solma (ms). */
private const val FADE_MS = 120

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val settings = Services.settings
        // Ayarlar › Temel › Görünüm ve Geçiş Animasyonları (Mac ve iPhone ile aynı; varsayılan koyu ve açık).
        Tokens.appearance = settings.appearance
        Tokens.transitionAnimations = settings.transitionAnimations
        applySystemBars(Tokens.dark)
        // Tanıtım popup'ı: uygulama ön plana her geldiğinde (soğuk açılışta hemen, sonra en çok günde bir) promo.json'a
        // arka planda bakılır; ağ hatası sessizdir. Kurulum ya da ilk tur bitmediyse bu açılışta hazırlanmaz.
        lifecycle.addObserver(androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_START)
                PromoController.refresh(applicationContext, Services.scope, setupDone = Routes.next() == Routes.MAIN && settings.tourShown)
        })
        setContent {
            CouchSubsTheme(forceDark = inPip) {
                // Görünüm değişince durum ve gezinme çubuğu simgeleri de zemine uyar (koyu zeminde açık, açık zeminde koyu).
                val dark = Tokens.dark
                LaunchedEffect(dark) { applySystemBars(dark) }
                val navigation = rememberNavController()
                val currentEntry by navigation.currentBackStackEntryAsState()
                val status by LiveState.status.collectAsState()
                // Hareket kapısı: çeviri sürerken sürekli animasyonlar durur (yalnız canlı nabız kalır).
                LaunchedEffect(status.running) { Tokens.translating = status.running }
                // Perde: üç sekme (Ana Ekran · Geçmiş · Ayarlar); her sekmenin kökü ana ekran yolunda (Routes.MAIN).
                var tab by rememberSaveable { mutableStateOf(PhoneTab.HOME) }
                fun select(chosen: PhoneTab) {
                    // Aynı sekmeye yeniden dokunmak o sekmenin köküne döner; üstte açık sayfa varsa kapanır.
                    if (currentEntry?.destination?.route != Routes.MAIN) navigation.popBackStack(Routes.MAIN, inclusive = false)
                    tab = chosen
                }
                homeTab = { tab = PhoneTab.HOME }
                /** Uygulama sayfaları: alt reklam şeridi (çeviri ve deneme modunda yok) ve cam sekme çubuğu. */
                @Composable
                fun AppPage(active: PhoneTab?, content: @Composable () -> Unit) {
                    CompositionLocalProvider(
                        LocalTabBar provides TabBarState(active ?: tab, ::select),
                        LocalAdBand provides PromoPolicy.adBandVisible(appPage = true, translating = status.running, demo = status.demo),
                        content = content,
                    )
                }
                LaunchedEffect(status.running) {
                    if (status.running && settings.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                // "Arka planda sürdür": çeviri sürerken uygulamadan çıkınca küçük pencere açılır (Android 12+'da sistem açar).
                LaunchedEffect(status.running) { BackgroundPip.update(this@MainActivity, BackgroundPip.wanted(this@MainActivity, status)) }
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
                // Ayarlar › Temel › Geçiş Animasyonları kapalıysa yalnız kısa solma (Mac ve iPhone ile aynı).
                val motion = Tokens.transitionAnimations
                NavHost(
                    navigation, startDestination = Routes.next(),
                    enterTransition = { if (motion) slideIntoContainer(SlideDirection.Start, tween(NAV_MS), initialOffset = { it / NAV_SHIFT }) + fadeIn(tween(NAV_MS)) else fadeIn(tween(FADE_MS)) },
                    exitTransition = { if (motion) slideOutOfContainer(SlideDirection.Start, tween(NAV_MS), targetOffset = { it / NAV_SHIFT }) + fadeOut(tween(NAV_MS)) else fadeOut(tween(FADE_MS)) },
                    popEnterTransition = { if (motion) slideIntoContainer(SlideDirection.End, tween(NAV_MS), initialOffset = { it / NAV_SHIFT }) + fadeIn(tween(NAV_MS)) else fadeIn(tween(FADE_MS)) },
                    popExitTransition = { if (motion) slideOutOfContainer(SlideDirection.End, tween(NAV_MS), targetOffset = { it / NAV_SHIFT }) + fadeOut(tween(NAV_MS)) else fadeOut(tween(FADE_MS)) },
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
                        // Kurulum adımı değilse uygulama sayfasıdır (iPhone: hedef sayfası reklam şeridi ve sekme çubuğuyla).
                        if (!onboarding) AppPage(null) { TargetRoute(navigation, onboarding) }
                        else TargetRoute(navigation, onboarding)
                    }
                    composable(Routes.HDMI) { HdmiInputScreen { advance(navigation) } }
                    composable(Routes.MAIN) {
                        AppPage(null) {
                        when (tab) {
                        PhoneTab.HISTORY -> HistoryScreen(onBack = null)
                        PhoneTab.SETTINGS -> SettingsScreen(onBack = null, onPacks = { navigation.navigate(Routes.PACKS) },
                            onTarget = { navigation.navigate(Routes.TARGET) }, onPairing = { pairing(navigation) },
                            onTvInstall = { navigation.navigate(Routes.TV_INSTALL) },
                            onPlatform = { navigation.navigate(Routes.PLATFORM) }, onDemo = { startDemo(navigation) },
                            onPsn = { psn(navigation) })
                        PhoneTab.HOME -> MainScreen(
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
                        }
                    }
                    composable(Routes.PACKS) {
                        AppPage(null) { PacksScreen(onBack = { pop(navigation) }, packInUse = status.packInUse) }
                    }
                    // Profil Ayarlar'a katıldı (hesap kartları, cihazlar, bildirimler); eski bağlantılar Ayarlar'ı açar.
                    for (route in listOf(Routes.PROFILE, Routes.SETTINGS)) composable(route) {
                        AppPage(PhoneTab.SETTINGS) {
                            SettingsScreen(onBack = { pop(navigation) }, onPacks = { navigation.navigate(Routes.PACKS) },
                                onTarget = { navigation.navigate(Routes.TARGET) }, onPairing = { pairing(navigation) },
                                onTvInstall = { navigation.navigate(Routes.TV_INSTALL) },
                                onPlatform = { navigation.navigate(Routes.PLATFORM) }, onDemo = { startDemo(navigation) },
                                onPsn = { psn(navigation) })
                        }
                    }
                    composable(Routes.HISTORY) { AppPage(PhoneTab.HISTORY) { HistoryScreen(onBack = { pop(navigation) }) } }
                    composable(Routes.TV_INSTALL) {
                        // Kurulum bitince "Ana ekrana geç": kurulumun 3. adımından gelindiyse kurulum biter (TvAppUpdate.installed).
                        TvInstallScreen(onBack = { pop(navigation) }) {
                            if (Routes.next() == Routes.MAIN) {
                                homeTab()
                                navigation.navigate(Routes.MAIN) { popUpTo(0) { inclusive = true } }
                            }
                            else pop(navigation)
                        }
                    }
                }
                // TV'nin eşleştirme isteği: onay penceresi ve her ekranın üstünde onay satırı (iPhone ile aynı).
                TvPairingPrompt(status.pairing)
                // Küçük pencerede (Resim içinde resim) yalnız oyun görüntüsü ve canlı altyazı; gezinme yığını altta durur.
                if (inPip) PipSubtitleView(status)
            }
        }
    }

    /** Kurulumun hedef adımı ya da Ayarlar'dan açılan hedef seçimi. */
    @Composable
    private fun TargetRoute(navigation: NavHostController, onboarding: Boolean) {
        val settings = Services.settings
        TargetScreen(onBack = back(navigation), onTvInstall = { navigation.navigate(Routes.TV_INSTALL) }) {
            if (onboarding) Telemetry.event(Telemetry.ONBOARDING_DONE, "target" to settings.target.name.lowercase())
            // Kurulumda TV seçildiyse (Android TV değil) TV girişi sorulur (Mac ve iPhone ile aynı adım).
            if (onboarding && settings.asksTvInput) navigation.navigate(Routes.HDMI) { popUpTo(0) { inclusive = true } }
            else advance(navigation)
        }
    }

    /** Ana ekrana dönerken (TV kurulumu bitti, deneme modu açıldı) Ana Ekran sekmesini seçer. */
    private var homeTab: () -> Unit = {}

    /** Ayarlar'daki PSN hesabı kartı: giriş sayfası (Xbox seçiliyse Microsoft girişi). */
    private fun psn(navigation: NavHostController) {
        navigation.navigate(if (Services.settings.xbox) Routes.XBOX_LOGIN else Routes.PSN)
    }

    override fun onStart() {
        super.onStart()
        Tokens.foreground = true
        // #1303: arka plandayken TV bağlantısı koptuysa ana ekranda "CouchSubs'ı açık tutun" (iPhone ile aynı).
        com.couchsubs.mobile.service.TvAwayAlert.returned(this)
    }

    override fun onStop() {
        super.onStop()
        // Uygulama arka plandayken sürekli animasyonlar durur (hareket kapısı).
        Tokens.foreground = false
        // Yapılandırma değişikliğinde (döndürme) ekran yeniden kurulur: bu arka plana geçiş değildir.
        if (!isChangingConfigurations) com.couchsubs.mobile.service.TvAwayAlert.left()
    }

    /** Durum ve gezinme çubuğu: koyu görünümde açık simgeler, açık görünümde koyu simgeler. */
    private fun applySystemBars(dark: Boolean) {
        val style = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
        enableEdgeToEdge(style, style)
    }

    /** Küçük pencerede (Resim içinde resim) mi; Compose içeriği buna göre çizilir. */
    private var inPip by mutableStateOf(false)

    /** Öne gelen ekran, gösterilemeyen (ya da arka plandayken gelen) eşleştirme isteğini yeniden gösterir. */
    override fun onResume() {
        super.onResume()
        TranslationService.syncPairing()
        // Profil'de "Arka planda sürdür" değişmiş olabilir.
        BackgroundPip.update(this, BackgroundPip.wanted(this, LiveState.status.value))
    }

    /** Android 11 ve öncesi: ana ekrana dönülürken küçük pencere burada açılır. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        BackgroundPip.onUserLeave(this, BackgroundPip.wanted(this, LiveState.status.value))
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
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
        homeTab()
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
        // Yalnız "Bu telefonda" seçiliyken kendiliğinden açılır; "İkisi de"de "Telefonda göster" düğmesiyle (iPhone ile aynı).
        if (Services.settings.target == SubtitleTarget.PHONE) startActivity(Intent(this, PhoneSubtitleActivity::class.java))
    }
}
