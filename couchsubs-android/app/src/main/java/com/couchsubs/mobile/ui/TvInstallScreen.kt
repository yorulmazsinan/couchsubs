// SPDX-License-Identifier: AGPL-3.0-only
// TV uygulamasını bilgisayarsız, bu telefondan kurmak ve güncellemek (Samsung, LG, Android TV). Ayarlar'dan, altyazı
// hedefi ekranından ve ana ekrandaki güncelleme önerisinden açılır.
package com.couchsubs.mobile.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.viewinterop.AndroidView
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.remoteplay.PsnPageProblem
import com.couchsubs.mobile.tv.InstalledTv
import com.couchsubs.mobile.tv.TvAddress
import com.couchsubs.mobile.tv.TvAppStatus
import com.couchsubs.mobile.tv.TvAppUpdate
import com.couchsubs.mobile.tv.TvBrand
import com.couchsubs.mobile.tv.TvDiscovery
import com.couchsubs.mobile.tv.samsung.AdbKey
import com.couchsubs.mobile.tv.samsung.InstallLog
import com.couchsubs.mobile.tv.samsung.InstallStep
import com.couchsubs.mobile.tv.samsung.SamsungCertificates
import com.couchsubs.mobile.tv.samsung.SamsungInstallError
import com.couchsubs.mobile.tv.samsung.SamsungInstallException
import com.couchsubs.mobile.tv.samsung.SamsungInstaller
import com.couchsubs.mobile.tv.samsung.SamsungLogin
import com.couchsubs.mobile.tv.samsung.SamsungRefusal
import com.couchsubs.mobile.tv.samsung.SamsungTvInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress

private const val TAG = "CouchSubsTvInstall"

/** Ağda görülen Samsung TV ve 8001'den okunan durumu (yoksa null). */
private data class SamsungCandidate(val host: String, val name: String, val info: SamsungTvInfo?)

private sealed interface InstallState {
    data object Idle : InstallState
    data class Working(val step: InstallStep) : InstallState
    data class Done(val version: String, val installed: Boolean) : InstallState
    data class Failed(val error: SamsungInstallError?, val detail: String?, val refusal: SamsungRefusal = SamsungRefusal.Unknown) : InstallState
}

/**
 * Kurulum ekranı: üstteki seçimle marka değişir (Samsung, LG, Android TV); her markanın akışı ayrıdır. Marka önce
 * güncellenecek TV'den, sonra bu telefonun kurduğu TV'den, sonra son seçimden gelir; hiçbiri yoksa ağda bulunan ilk
 * TV'nin markası seçilir.
 */
@Composable
fun TvInstallScreen(onBack: () -> Unit, onDone: () -> Unit = onBack) {
    val settings = Services.settings
    // Ana ekrandaki "TV uygulamasını güncelle": bu TV seçilir ve kurulum kendiliğinden başlar.
    val preset = remember { TvAppUpdate.takePending() }
    var brand by remember { mutableStateOf(preset?.brand ?: settings.installedTv?.brand ?: settings.tvInstallBrand) }
    val brands = listOf(TvBrand.SAMSUNG, TvBrand.LG, TvBrand.ANDROID_TV)
    val picker: @Composable () -> Unit = {
        Segmented(listOf(stringResource(R.string.tvinstall_brand_samsung), stringResource(R.string.tvinstall_brand_lg),
            stringResource(R.string.tvinstall_brand_android)),
            brands.indexOf(brand).coerceAtLeast(0)) {
            brand = brands[it]
            settings.tvInstallBrand = brands[it]
        }
    }
    if (brand == null) {
        LaunchedEffect(Unit) {
            val found = withContext(Dispatchers.IO) { runCatching { TvDiscovery.search() }.getOrDefault(emptyList()) }
            brand = found.firstOrNull { it.brand != TvBrand.ANDROID_TV }?.brand ?: found.firstOrNull()?.brand ?: TvBrand.SAMSUNG
        }
        ScreenScaffold(top = { TopBar(onBack = onBack) }) {
            Heading(stringResource(R.string.tvinstall_title), stringResource(R.string.tvinstall_any_body))
            Tile(Modifier.fillMaxWidth()) { StatusLabel(stringResource(R.string.tvinstall_searching), live = true) }
        }
        return
    }
    val forBrand = preset?.takeIf { it.brand == brand }
    when (brand) {
        TvBrand.ANDROID_TV -> AndroidTvInstallScreen(onBack, onDone, picker, forBrand)
        TvBrand.LG -> LgInstallScreen(onBack, onDone, picker, forBrand)
        else -> SamsungInstallScreen(onBack, onDone, picker, forBrand)
    }
}

/** Ayarlar'daki TV uygulaması satırının değeri: kurulu TV ve sürüm ya da bekleyen güncelleme. */
@Composable
internal fun tvAppSummary(): String? {
    val status by TvAppUpdate.status.collectAsState()
    (status as? TvAppStatus.Outdated)?.let { return stringResource(R.string.tvapp_update_short, it.bundled) }
    val tv = Services.settings.installedTv ?: return null
    return listOfNotNull(brandName(tv.brand), tv.version?.takeIf { it.isNotEmpty() }).joinToString(" · ")
}

/** Ana ekranda: TV'deki uygulama telefondakinden eskiyse tek dokunuşla güncelleme önerisi. */
@Composable
internal fun TvAppUpdateCard(onUpdate: (InstalledTv) -> Unit) {
    val status by TvAppUpdate.status.collectAsState()
    val outdated = status as? TvAppStatus.Outdated ?: return
    Tile(Modifier.fillMaxWidth(), style = TileStyle.ACTIVE) {
        Text(stringResource(R.string.tvapp_update_title), style = Tokens.Type.headline, color = Tokens.Color.text)
        Text(stringResource(R.string.tvapp_update_body, brandName(outdated.tv.brand), outdated.installed, outdated.bundled),
            style = Tokens.Type.body, color = Tokens.Color.secondary)
        PrimaryButton(stringResource(R.string.tvapp_update_button), Modifier.fillMaxWidth()) { onUpdate(outdated.tv) }
    }
}

@Composable
private fun SamsungInstallScreen(onBack: () -> Unit, onDone: () -> Unit, brandPicker: @Composable () -> Unit, preset: InstalledTv?) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val phoneIp = remember { phoneAddress(context) }
    var candidates by remember { mutableStateOf<List<SamsungCandidate>?>(null) }
    var host by remember { mutableStateOf(preset?.host ?: Services.settings.installedTv?.takeIf { it.brand == TvBrand.SAMSUNG }?.host ?: "") }
    var manual by remember { mutableStateOf(false) }
    var state by remember { mutableStateOf<InstallState>(InstallState.Idle) }
    var login by remember { mutableStateOf<SamsungLogin.Listener?>(null) }
    val working = state is InstallState.Working
    val logFile = remember { File(context.filesDir, "tvinstall.log") }

    LaunchedEffect(Unit) {
        val found = withContext(Dispatchers.IO) { findSamsungTvs(phoneIp) }
        candidates = found
        if (host.isEmpty()) found.firstOrNull()?.let { host = it.host }
        if (found.isEmpty()) manual = true
    }
    // Ekrandan çıkılırsa bekleyen giriş bırakılır (kurulum iş parçacığı giriş hatasıyla biter).
    DisposableEffect(Unit) { onDispose { login?.close() } }

    // TV'de bu kimlikle başka bir uygulama var: kaldırılıp kurulsun mu diye sorulur (onaysız kaldırılmaz).
    var foreignDialog by remember { mutableStateOf(false) }

    fun install(replaceForeign: Boolean = false) {
        val target = host.trim()
        state = InstallState.Working(InstallStep.CONNECTING)
        val main = Handler(Looper.getMainLooper())
        scope.launch {
            state = try {
                val result = withContext(Dispatchers.IO) {
                    val installer = SamsungInstaller(
                        host = target,
                        profilesDirectory = File(context.noBackupFilesDir, "samsung"),
                        adbKey = { AdbKey.loadOrCreate(File(context.noBackupFilesDir, "sdb/adbkey")) },
                        certificates = SamsungCertificates(log = InstallLog(logFile)::write),
                        signIn = {
                            // Giriş sayfası açılır; Samsung jetonu bu telefondaki dinleyiciye gönderince devam edilir.
                            val listener = SamsungLogin.Listener()
                            main.post { login = listener }
                            try {
                                listener.await(10 * 60 * 1000L)
                            } finally {
                                main.post { login = null }
                            }
                        },
                        progress = { step -> main.post { if (state is InstallState.Working) state = InstallState.Working(step) } },
                        log = InstallLog(logFile),
                    )
                    installer.ensureInstalled({ context.assets.open("tv/couchsubs-samsung.wgt").use { it.readBytes() } },
                        BuildConfig.TV_SAMSUNG_VERSION, replaceForeign)
                }
                TvAppUpdate.installed(InstalledTv(TvBrand.SAMSUNG, target, version = result.version))
                InstallState.Done(result.version, result.installed)
            } catch (error: SamsungInstallException) {
                // TV'de 26101 kapalıysa 8001'den geliştirici modu yeniden sorulur: neden ayar mı, yeniden başlatma mı (#524).
                val refusal = if (error.error != SamsungInstallError.UNREACHABLE) SamsungRefusal.Unknown else withContext(Dispatchers.IO) {
                    SamsungTvInfo.fetch(target)?.let { info ->
                        info.refusal(phoneIp, target).also {
                            InstallLog(logFile).write("TV 8001: developerMode=${info.developerMode?.let { on -> if (on) "1" else "0" } ?: "?"}, " +
                                "developerIP=${info.developerIp ?: "?"}, telefon=${phoneIp ?: "?"} → $it")
                        }
                    } ?: SamsungTvInfo(null, null, null, null).refusal(phoneIp, target) // 8001 yanıtsızsa yalnız ağ denetlenir.
                }
                InstallState.Failed(error.error, error.detail, refusal)
            } catch (error: Exception) {
                Log.w(TAG, "TV kurulumu başarısız", error)
                InstallState.Failed(null, error.message ?: error.javaClass.simpleName)
            }
            foreignDialog = (state as? InstallState.Failed)?.error == SamsungInstallError.FOREIGN_APP
        }
    }

    if (foreignDialog) ForeignTvAppDialog(onReplace = {
        foreignDialog = false
        install(replaceForeign = true)
    }, onDismiss = { foreignDialog = false })

    // "TV uygulamasını güncelle"den gelindiyse kurulum hemen başlar (kullanıcı ana ekranda onayladı).
    LaunchedEffect(preset) { if (preset != null && state is InstallState.Idle) install() }

    login?.let { listener ->
        SamsungSignIn(onClose = { listener.close() })
        return
    }

    ScreenScaffold(top = { TopBar(onBack = onBack) }, bottom = {
        if (!manual && !working) GhostButton(stringResource(R.string.tvinstall_not_found)) { manual = true }
        if (state is InstallState.Done) PrimaryButton(stringResource(R.string.tvinstall_go_home), onClick = onDone)
        else PrimaryButton(stringResource(if (state is InstallState.Failed) R.string.tvinstall_retry else R.string.tvinstall_button),
            enabled = !working && host.isNotBlank() && !TvAddress.isPhoneAddress(host, phoneIp)) { install() }
    }) {
        Heading(stringResource(R.string.tvinstall_title), stringResource(R.string.tvinstall_body))
        if (!working) brandPicker()
        NoteTile(stringResource(R.string.tvinstall_supported), Tokens.Color.secondary)

        TileLabel(stringResource(R.string.tvinstall_tvs))
        when (val list = candidates) {
            null -> Tile(Modifier.fillMaxWidth()) { Text(stringResource(R.string.tvinstall_searching), style = Tokens.Type.body, color = Tokens.Color.secondary) }
            else -> {
                if (list.isEmpty()) Tile(Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.tvinstall_none), style = Tokens.Type.body, color = Tokens.Color.secondary)
                }
                list.forEach { tv ->
                    Tile(Modifier.fillMaxWidth(), style = if (host == tv.host) TileStyle.ACTIVE else TileStyle.NORMAL,
                        onClick = { if (!working) host = tv.host }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                            TileIcon(CouchIcons.Tv)
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                                Text(tv.name, style = Tokens.Type.headline, color = Tokens.Color.text)
                                Text(listOfNotNull(tv.info?.model, tv.host).joinToString(" · "), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                                developerState(tv.info, phoneIp)?.let { (text, ok) -> StatusLabel(text, ok = ok) }
                            }
                            if (host == tv.host) SelectedCheck()
                        }
                    }
                }
            }
        }
        if (manual) TvAddressField(host, { host = it.trim() }, phoneIp)

        Tile(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.tvinstall_steps_title), style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(R.string.tvinstall_step1), style = Tokens.Type.body, color = Tokens.Color.secondary)
            Text(stringResource(R.string.tvinstall_step2), style = Tokens.Type.body, color = Tokens.Color.secondary)
            Text(stringResource(R.string.tvinstall_step3), style = Tokens.Type.body, color = Tokens.Color.secondary)
            Text(phoneIp ?: stringResource(R.string.tvinstall_phone_ip_unknown), style = Tokens.Type.title, color = Tokens.Color.accentText)
            Text(stringResource(R.string.tvinstall_step4), style = Tokens.Type.body, color = Tokens.Color.secondary)
        }
        Text(stringResource(R.string.tvinstall_signin_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)

        when (val current = state) {
            InstallState.Idle -> Unit
            is InstallState.Working -> Tile(Modifier.fillMaxWidth()) {
                StatusLabel(stepText(current.step), live = true)
            }
            is InstallState.Done -> Tile(Modifier.fillMaxWidth(), style = TileStyle.ACTIVE) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                    TileIcon(Icons.Filled.Check, Tokens.Color.success)
                    Text(stringResource(if (current.installed) R.string.tvinstall_done else R.string.tvinstall_up_to_date, current.version),
                        style = Tokens.Type.headline, color = Tokens.Color.text)
                }
                // Telefondan kuranların çoğunun bilgisayarı yoktur; TV'nin bekleme ekranı hata sanılıyordu (#113).
                Text(stringResource(R.string.tvinstall_next), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
            is InstallState.Failed -> {
                NoteTile(failureText(current, phoneIp))
                GhostButton(stringResource(R.string.tvinstall_share_log)) { shareLog(context, logFile) }
            }
        }
    }
}

/**
 * TV'nin adresi yazılan alan: etiket adresin TV'de nerede yazdığını söyler, altında bu telefonun adresi durur. İki
 * kullanıcı TV'nin kutusuna telefonun/bilgisayarın adresini yazmıştı (#343); aynısı yazılınca kurulum başlamaz, uyarılır.
 */
@Composable
internal fun TvAddressField(
    value: String, onChange: (String) -> Unit, phoneIp: String?,
    label: String = stringResource(R.string.tvinstall_address),
    placeholder: String? = stringResource(R.string.tvinstall_address_example),
) {
    Field(value, onChange, label, keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri), placeholder = placeholder)
    if (TvAddress.isPhoneAddress(value, phoneIp)) NoteTile(stringResource(R.string.tvinstall_address_is_phone))
    else if (phoneIp != null) Text(stringResource(R.string.tvinstall_address_not_phone, phoneIp), style = Tokens.Type.caption, color = Tokens.Color.secondary)
}

/**
 * Uygulama içinde Samsung'un giriş sayfası; "Tarayıcıda aç" aynı dinleyiciye döner. Sayfa yüklenirken gösterge ve
 * yazı, açılamazsa nedeni, "Yeniden dene" ve "Tarayıcıda aç" görünür (#553: koyu arka planlı boş WebView "siyah ekran"
 * sanılıyordu). WebView'in sayfa süreci bellek yetmediği için kapatılırsa (onRenderProcessGone) bu yakalanır; eskiden
 * yakalanmadığı için Android bütün uygulamayı kapatıyordu ("TV'ye bağlanırken uygulama kapanıyor, bellek hatası").
 * WebView ekrandan çıkınca yok edilir; her denemede yenisi kurulur.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun SamsungSignIn(onClose: () -> Unit) {
    val context = LocalContext.current
    val background = Tokens.Color.bg.toArgb()
    val problems = pageProblems()
    var attempt by remember { mutableIntStateOf(0) }
    var progress by remember { mutableIntStateOf(0) }
    var visible by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<Pair<PsnPageProblem, String?>?>(null) }
    fun fail(problem: PsnPageProblem, detail: String?) {
        Log.w(TAG, "Samsung giriş sayfası açılamadı: $problem ${detail ?: ""}")
        if (failure == null) failure = problem to detail
    }
    fun retry() {
        failure = null
        visible = false
        progress = 0
        attempt++
    }
    BackHandler(onBack = onClose)
    ScreenBackground {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            Box(Modifier.padding(Tokens.Space.screen)) {
                TopBar(stringResource(R.string.tvinstall_signin_title), onClose = onClose) {
                    GhostButton(stringResource(R.string.tvinstall_signin_browser)) { open(context, SamsungLogin.authorizeUrl) }
                }
            }
            if (failure == null && progress < 100) LinearProgressIndicator(
                progress = { progress / 100f }, modifier = Modifier.fillMaxWidth(),
                color = Tokens.Color.accent, trackColor = Tokens.Color.border,
            )
            Box(Modifier.fillMaxWidth().weight(1f)) {
                key(attempt) {
                    // Sayfa hiç görünmezse (WebView takıldı, ağ yanıt vermiyor) süre dolunca hata ekranı çıkar.
                    LaunchedEffect(Unit) {
                        delay(SAMSUNG_PAGE_TIMEOUT_MS)
                        if (!visible) fail(PsnPageProblem.TIMEOUT, null)
                    }
                    AndroidView(modifier = Modifier.fillMaxSize(), factory = { viewContext ->
                        try {
                            WebView(viewContext)
                        } catch (error: RuntimeException) {
                            // WebView kurulu değil ya da o an güncelleniyor.
                            Log.w(TAG, "WebView açılamadı", error)
                            fail(PsnPageProblem.CRASHED, error.javaClass.simpleName)
                            null
                        }?.apply {
                            setBackgroundColor(background)
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            // Giriş https sayfasından http://localhost'a gönderilir.
                            settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                            // Samsung'un hesap sayfaları WebView'in "; wv" imzasıyla sorun çıkarıyor (TizenSdb'nin Android denemesi).
                            settings.userAgentString = settings.userAgentString.replace("; wv", "")
                            CookieManager.getInstance().setAcceptCookie(true)
                            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                            webChromeClient = object : WebChromeClient() {
                                override fun onProgressChanged(view: WebView, newProgress: Int) {
                                    progress = newProgress
                                }
                            }
                            webViewClient = SamsungSignInClient(onVisible = { visible = true }, onFailure = ::fail)
                            loadUrl(SamsungLogin.authorizeUrl)
                        } ?: android.view.View(viewContext)
                    }, onRelease = { view ->
                        // Eskiden WebView hiç yok edilmiyordu: her denemede bir sayfa süreci daha bellekte kalıyordu.
                        if (view is WebView) {
                            view.stopLoading()
                            view.destroy()
                        }
                    })
                }
                if (failure == null && !visible) Column(
                    Modifier.fillMaxSize().background(Tokens.Color.bg).padding(Tokens.Space.screen),
                    verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator(color = Tokens.Color.accent)
                    BodyText(stringResource(R.string.tvinstall_signin_loading))
                    BodyText(stringResource(R.string.tvinstall_signin_loading_hint), align = TextAlign.Center)
                }
                failure?.let { (problem, detail) ->
                    Column(
                        Modifier.fillMaxSize().background(Tokens.Color.bg).padding(Tokens.Space.screen),
                        verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap, Alignment.CenterVertically),
                    ) {
                        Heading(stringResource(R.string.tvinstall_signin_failed), problems(problem) + (detail?.let { " ($it)" } ?: ""))
                        NoteTile(stringResource(R.string.tvinstall_signin_failed_hint), Tokens.Color.secondary)
                        PrimaryButton(stringResource(R.string.psn_retry)) { retry() }
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            GhostButton(stringResource(R.string.tvinstall_signin_browser)) { open(context, SamsungLogin.authorizeUrl) }
                        }
                    }
                }
            }
        }
    }
}

/** Samsung giriş sayfası bu sürede görünmezse hata ekranı. */
private const val SAMSUNG_PAGE_TIMEOUT_MS = 30_000L

/** Samsung giriş sayfasının WebView olayları: ana sayfanın hataları ve sayfa sürecinin kapanması bildirilir. */
private class SamsungSignInClient(
    private val onVisible: () -> Unit,
    private val onFailure: (PsnPageProblem, String?) -> Unit,
) : WebViewClient() {
    private var failed = false

    private fun fail(problem: PsnPageProblem, detail: String?) {
        if (failed) return
        failed = true
        onFailure(problem, detail)
    }

    /** Giriş bitince sayfa telefonun içindeki dinleyiciye (localhost) gönderilir; o adresin hataları giriş hatası değildir. */
    private fun isCallback(url: String) = url.startsWith("http://localhost:${SamsungLogin.CALLBACK_PORT}")

    override fun onPageCommitVisible(view: WebView, url: String) {
        if (!failed) onVisible()
    }

    override fun onPageFinished(view: WebView, url: String) {
        if (!failed) onVisible()
    }

    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
        if (!request.isForMainFrame || isCallback(request.url.toString())) return
        fail(PsnPageProblem.fromWebError(error.errorCode), "${error.errorCode} ${error.description}")
    }

    override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
        if (!request.isForMainFrame || isCallback(request.url.toString())) return
        // Samsung'un sayfası 4xx/5xx ile gelirse içeriği yine görünür; yalnız hiç görünmediyse hata sayılır.
        Log.w(TAG, "Samsung giriş sayfası: HTTP ${response.statusCode} ${request.url.host}")
    }

    @SuppressLint("WebViewClientOnReceivedSslError")
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
        handler.cancel()
        fail(PsnPageProblem.SSL, "SSL ${error.primaryError}")
    }

    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        // true dönülmezse Android bütün uygulamayı kapatır. Bu WebView artık kullanılamaz; "Yeniden dene" yenisini kurar.
        Log.w(TAG, "Samsung giriş sayfasının süreci kapandı (didCrash=${detail.didCrash()})")
        fail(PsnPageProblem.fromRenderGone(detail.didCrash()), null)
        return true
    }
}

/** 8001'deki geliştirici modu bilgisi: açık mı, Host PC IP bu telefon mu? */
@Composable
private fun developerState(info: SamsungTvInfo?, phoneIp: String?): Pair<String, Boolean>? {
    val mode = info?.developerMode ?: return null
    if (!mode) return stringResource(R.string.tvinstall_dev_off) to false
    val ip = info.developerIp
    if (ip != null && phoneIp != null && ip != phoneIp) return stringResource(R.string.tvinstall_dev_other_ip, ip) to false
    return stringResource(R.string.tvinstall_dev_on) to true
}

@Composable
internal fun stepText(step: InstallStep) = stringResource(when (step) {
    InstallStep.PAIRING -> R.string.tvinstall_step_pairing
    InstallStep.APPROVE_ON_TV -> R.string.tvinstall_step_approve
    InstallStep.KEY -> R.string.tvinstall_step_key
    InstallStep.OPEN_PLAY -> R.string.tvinstall_step_play
    InstallStep.CONNECTING -> R.string.tvinstall_step_connecting
    InstallStep.READING -> R.string.tvinstall_step_reading
    InstallStep.SIGN_IN -> R.string.tvinstall_step_signin
    InstallStep.CERTIFICATE -> R.string.tvinstall_step_certificate
    InstallStep.SIGNING -> R.string.tvinstall_step_signing
    InstallStep.INSTALLING -> R.string.tvinstall_step_installing
    InstallStep.UNINSTALLING -> R.string.tvinstall_step_uninstalling
    InstallStep.LAUNCHING -> R.string.tvinstall_step_launching
})

/** Ne yapılacağı (masaüstündeki TvAppMessages ile aynı anlam) ve TV'nin ya da Samsung'un verdiği ayrıntı. */
@Composable
private fun failureText(failure: InstallState.Failed, phoneIp: String?): String {
    val context = LocalContext.current
    val advice = when (failure.error) {
        SamsungInstallError.UNREACHABLE -> when (val refusal = failure.refusal) {
            is SamsungRefusal.DifferentNetworks -> context.getString(R.string.tvinstall_err_other_network, refusal.tv, refusal.phone)
            SamsungRefusal.NotRestarted -> context.getString(R.string.tvinstall_err_not_restarted, phoneIp ?: "?")
            is SamsungRefusal.OtherHostIp -> context.getString(R.string.tvinstall_err_other_ip, refusal.ip, phoneIp ?: "?")
            SamsungRefusal.DeveloperModeOff -> context.getString(R.string.tvinstall_err_dev_off, phoneIp ?: "?")
            SamsungRefusal.Unknown -> context.getString(R.string.tvinstall_err_unreachable, phoneIp ?: "?")
        }
        SamsungInstallError.TOO_OLD -> context.getString(R.string.tvinstall_err_too_old)
        SamsungInstallError.LOGIN_FAILED -> context.getString(R.string.tvinstall_err_login)
        SamsungInstallError.CERTIFICATE_FAILED -> context.getString(R.string.tvinstall_err_certificate)
        SamsungInstallError.NOT_ENOUGH_SPACE -> context.getString(R.string.tvinstall_err_space)
        SamsungInstallError.CERTIFICATE_MISMATCH -> context.getString(R.string.tvinstall_err_mismatch)
        SamsungInstallError.CERTIFICATE_REJECTED -> context.getString(R.string.tvinstall_err_rejected)
        SamsungInstallError.TV_CLOCK_WRONG -> context.getString(R.string.tvinstall_err_clock)
        SamsungInstallError.PACKAGE_BLOCKED -> context.getString(R.string.tvinstall_err_blocked)
        SamsungInstallError.CONNECTION_LOST -> context.getString(R.string.tvinstall_err_connection)
        SamsungInstallError.FOREIGN_APP -> return context.getString(R.string.tvinstall_foreign_body)
        SamsungInstallError.INSTALL_FAILED, null -> context.getString(R.string.tvinstall_err_failed)
    }
    var text = advice
    failure.detail?.takeIf { it.isNotBlank() }?.let { text += "\n\n" + context.getString(R.string.tvinstall_details, it) }
    if (failure.error == SamsungInstallError.INSTALL_FAILED || failure.error == SamsungInstallError.CERTIFICATE_REJECTED)
        text += "\n\n" + context.getString(R.string.tvinstall_maintenance)
    // TV'nin kendi "Samsung sunucusuna bağlanılamıyor (AS400)" uyarısı (Samsung 7 Series 2018, 21 Kas; Windows/Mac/iPhone ile aynı).
    if (failure.error == SamsungInstallError.INSTALL_FAILED || failure.error == SamsungInstallError.CERTIFICATE_REJECTED ||
        failure.error == SamsungInstallError.UNREACHABLE)
        text += "\n\n" + context.getString(R.string.tvinstall_samsung_server)
    return text
}

/** Ağdaki Samsung TV'ler: önce SSDP, yanıt yoksa ağın /24 bölümünde 8001 portu (Mac'teki SamsungTV.search gibi). */
private suspend fun findSamsungTvs(phoneIp: String?): List<SamsungCandidate> = withContext(Dispatchers.IO) {
    val ssdp = runCatching { TvDiscovery.search() }.getOrDefault(emptyList()).filter { it.brand == TvBrand.SAMSUNG }
    val found = ssdp.map { async { SamsungCandidate(it.host, it.name, SamsungTvInfo.fetch(it.host)) } }.awaitAll()
    if (found.isNotEmpty() || phoneIp == null) return@withContext found
    val prefix = phoneIp.substringBeforeLast('.')
    val gate = Semaphore(32)
    (1..254).map { "$prefix.$it" }.filter { it != phoneIp }
        .map { address -> async { gate.withPermit { SamsungTvInfo.fetch(address, timeoutMs = 700)?.let { SamsungCandidate(address, it.name ?: "Samsung TV", it) } } } }
        .awaitAll().filterNotNull()
}

/** Telefonun Wi-Fi'daki IPv4 adresi: TV'nin geliştirici modunda Host PC IP olarak yazılır. */
internal fun phoneAddress(context: Context): String? = try {
    val connectivity = context.getSystemService(ConnectivityManager::class.java)
    val networks = connectivity.allNetworks.map { network ->
        val capabilities = connectivity.getNetworkCapabilities(network)
        NetworkAddressCandidate(
            isWifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true,
            isEthernet = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true,
            isVpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true,
            addresses = connectivity.getLinkProperties(network)?.linkAddresses?.map { it.address }.orEmpty(),
        )
    }
    phoneIpv4Address(networks)
} catch (error: Exception) {
    null
}

internal data class NetworkAddressCandidate(
    val isWifi: Boolean,
    val isEthernet: Boolean,
    val isVpn: Boolean,
    val addresses: List<InetAddress>,
)

internal fun phoneIpv4Address(networks: Iterable<NetworkAddressCandidate>): String? {
    fun addressFor(transport: (NetworkAddressCandidate) -> Boolean): String? = networks.asSequence()
        .filter { transport(it) && !it.isVpn }
        .flatMap { it.addresses.asSequence() }
        .filterIsInstance<Inet4Address>()
        .firstOrNull { !it.isLoopbackAddress }
        ?.hostAddress

    return addressFor { it.isWifi } ?: addressFor { it.isEthernet }
}

internal fun shareLog(context: Context, file: File) {
    val text = runCatching { file.readText().takeLast(60_000) }.getOrDefault("")
    val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, "CouchSubs tvinstall.log")
        .putExtra(Intent.EXTRA_TEXT, text)
    runCatching { context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}
