// SPDX-License-Identifier: AGPL-3.0-only
// Kurulumun PSN adımı (tuval: Telefon-PSN). Sony'nin giriş sayfası uygulama içi WebView'da açılır; yönlendirme
// yakalanır, parola yalnız Sony'ye gider. "Tarayıcıda aç" (adresi yapıştırma) ve "Kapat" hep ekrandadır; sayfa
// LOAD_TIMEOUT_MS içinde giriş formunu çizmezse nedeni ve "Yeniden dene" gösterilir. "Google ile giriş" seçilince
// (Google WebView'da girişi reddeder) giriş kendiliğinden tarayıcıya geçer. Tarayıcıdan dönünce panodaki yönlendirme
// adresi kendiliğinden alınır; ekran durumu uygulama arka planda kapatılsa da korunur.
package com.couchsubs.mobile.ui

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebStorage
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
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.viewinterop.AndroidView
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.remoteplay.PsnAccount
import com.couchsubs.mobile.remoteplay.PsnAccountException
import com.couchsubs.mobile.remoteplay.PsnLoginFailure
import com.couchsubs.mobile.remoteplay.PsnLoadWatch
import com.couchsubs.mobile.remoteplay.PsnPageProblem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

private const val TAG = "CouchSubsPsn"

private enum class PsnMode { INTRO, WEB, BROWSER, MANUAL }

@Composable
fun PsnLoginScreen(onBack: (() -> Unit)? = null, onSkip: (() -> Unit)? = null, onDone: () -> Unit) {
    // Tarayıcıdayken Android uygulamayı kapatabilir ya da etkinliği yeniden kurabilir; dönünce yapıştırma ekranı
    // yerinde kalsın diye kaydedilir (eskiden giriş ekranına dönülüyordu, adresi yapıştıracak yer kalmıyordu).
    var mode by rememberSaveable { mutableStateOf(PsnMode.INTRO) }
    var viaGoogle by rememberSaveable { mutableStateOf(false) }
    // Son denenen yönlendirme: panoda kalan eski (kullanılmış) kod kendiliğinden yeniden denenmez.
    var tried by rememberSaveable { mutableStateOf<String?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var why by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    // Önceki girişin verisi giriş ekranı görünür görünmez silinir: kullanıcı "Giriş"e basana kadar WebView ısınır ve
    // temizlik biter. Eskiden temizlik sayfa açılmadan hemen önce yapılıyordu; ilk açılışta (WebView soğukken) 2 sn'de
    // bitmiyor, sayfa yine açılıyor, geç biten temizlik Sony'nin ilk yönlendirmede koyduğu çerezleri ve sayfa verisini
    // siliyordu: giriş sayfası boş kalıyor, ancak "Tarayıcıda aç" ile girilebiliyordu (GitHub #54). Ekranın kapsamında
    // çalışır: "Giriş"e basılınca yarıda kesilmez.
    var earlyCleanup by remember { mutableStateOf<Deferred<Result<Unit>>?>(null) }
    LaunchedEffect(mode) {
        if (mode == PsnMode.INTRO) earlyCleanup = scope.async { PsnWebData.clear() }
    }

    // Yönlendirme (uygulama içinden ya da tarayıcıdan yapıştırılan) hesap kimliğine çevrilir.
    // Yönlendirmeden sonra hesap kimliği Sony'den alınırken üst sınır var: eskiden ağ takılınca bekleme göstergesinde
    // dakikalarca kalınıyordu (yönlendirme yakalanınca sayfanın süre sayacı da durur). Süre dolunca ya da Sony reddedince
    // nedeni anlaşılır biçimde yazılır ve "Yeniden dene" görünür.
    fun finish(redirect: String) {
        tried = redirect
        scope.launch {
            val failure = try {
                // Bloklayan istek iptal edilemez: beklemeyi bırakabilmek için uygulama kapsamında çalışır.
                val work = Services.scope.async(Dispatchers.IO) { PsnAccount.accountIdFromRedirect(redirect) }
                val id = withTimeoutOrNull(PsnLoadWatch.TOKEN_TIMEOUT_MS) { work.await() }
                if (id == null) {
                    work.cancel()
                    context.getString(R.string.psn_error_timeout)
                } else {
                    Services.settings.accountId = id
                    // Kod tek kullanımlıktır: panoda kalırsa sonraki girişte yeniden denenmesin.
                    clearClipIf(context, redirect)
                    onDone()
                    null
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: PsnAccountException) {
                Log.w(TAG, "PSN girişi tamamlanmadı", error)
                loginFailureText(context, error)
            } catch (error: Exception) {
                Log.w(TAG, "PSN girişi tamamlanmadı", error)
                error.message ?: error.javaClass.simpleName
            }
            if (failure != null) {
                problem = failure
                mode = PsnMode.INTRO
            }
        }
    }

    fun openBrowser(google: Boolean = false) {
        viaGoogle = google
        mode = PsnMode.BROWSER
        openInBrowser(context)
    }

    BackHandler(enabled = mode != PsnMode.INTRO) { mode = PsnMode.INTRO }
    when (mode) {
        PsnMode.INTRO -> {
            ScreenScaffold(top = { TopBar(onBack = onBack) { SkipAction(onSkip) } }, bottom = {
                GhostButton(stringResource(R.string.psn_why)) { why = true }
                // Giriş yarıda kaldıysa ana düğme "Yeniden dene" olur (yeni giriş açar; kullanılmış kod yeniden denenmez).
                PrimaryButton(stringResource(if (problem != null) R.string.psn_retry else R.string.psn_open)) {
                    problem = null
                    mode = PsnMode.WEB
                }
            }) {
                Heading(stringResource(R.string.psn_title), stringResource(R.string.psn_body), stringResource(R.string.setup_step, 1))
                TwoColumns(
                    { StatusTile(Icons.Filled.Person, stringResource(R.string.psn_free_note), stringResource(R.string.psn_free), it) },
                    { StatusTile(CouchIcons.Gamepad, stringResource(R.string.psn_you_play_note), stringResource(R.string.psn_you_play), it) },
                )
                Tile(Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        TileIcon(Icons.Filled.Lock)
                        Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                            Text(stringResource(R.string.psn_password_safe), style = Tokens.Type.headline, color = Tokens.Color.text)
                            Text(stringResource(R.string.psn_password_safe_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                    }
                }
                // Kol ikinci hesaba atanırsa ana hesapla açılan oyun onu kendi kolu saymaz (GitHub #231).
                NoteTile(stringResource(R.string.psn_main_account))
                GhostButton(stringResource(R.string.psn_manual)) {
                    problem = null
                    mode = PsnMode.MANUAL
                }
                problem?.let {
                    NoteTile(stringResource(R.string.psn_failed, it))
                    GhostButton(stringResource(R.string.psn_browser)) { openBrowser() }
                }
            }
            if (why) InfoDialog(stringResource(R.string.psn_why), stringResource(R.string.psn_why_body)) { why = false }
        }
        PsnMode.WEB -> PsnWebLogin(
            earlyCleanup = earlyCleanup,
            onRedirect = ::finish,
            onClose = { mode = PsnMode.INTRO },
            onBrowser = { openBrowser() },
            onManual = { problem = null; mode = PsnMode.MANUAL },
            onGoogle = { openBrowser(google = true) },
        )
        PsnMode.BROWSER -> PsnBrowserLogin(
            viaGoogle = viaGoogle,
            tried = tried,
            onRedirect = ::finish,
            onReopen = { openInBrowser(context) },
            onClose = { mode = PsnMode.INTRO },
        )
        PsnMode.MANUAL -> PsnManualLogin(
            onSave = { id ->
                Services.settings.accountId = id
                Log.i(TAG, "PSN hesap kimliği elle girildi")
                onDone()
            },
            onClose = { mode = PsnMode.INTRO },
        )
    }
}

/** Sony'nin giriş sonucunun kullanıcıya anlatımı (eskiden "PSN sign-in failed: NETWORK" gibi ham metin görünüyordu). */
private fun loginFailureText(context: Context, error: PsnAccountException): String {
    val text = when (error.failure) {
        PsnLoginFailure.NO_CODE -> context.getString(R.string.psn_error_no_code)
        PsnLoginFailure.REFUSED -> context.getString(R.string.psn_error_refused)
        PsnLoginFailure.RATE_LIMITED -> context.getString(R.string.psn_error_rate_limited)
        PsnLoginFailure.HTTP -> context.getString(R.string.psn_error_http, error.status?.toString() ?: "?")
        PsnLoginFailure.NETWORK -> context.getString(R.string.psn_problem_offline)
        PsnLoginFailure.BAD_RESPONSE -> context.getString(R.string.psn_error_bad_response)
    }
    return error.detail?.takeIf { error.failure == PsnLoginFailure.REFUSED && it.isNotBlank() }?.let { "$text ($it)" } ?: text
}

private fun clipboard(context: Context) = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

/** Panodaki ilk öğenin metni; pano okunamazsa (odak yok, üretici kısıtı) null. */
private fun readClip(context: Context): String? = try {
    clipboard(context)?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
} catch (error: RuntimeException) {
    Log.w(TAG, "Pano okunamadı", error)
    null
}

/** Panoda hâlâ bu yönlendirme varsa silinir (Android 9+). */
private fun clearClipIf(context: Context, redirect: String) {
    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.P) return
    if (readClip(context)?.let(PsnAccount::redirectFromText) != redirect) return
    try {
        clipboard(context)?.clearPrimaryClip()
    } catch (error: RuntimeException) {
        Log.w(TAG, "Pano silinemedi", error)
    }
}

private fun openInBrowser(context: Context) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PsnAccount.authorizeUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (error: ActivityNotFoundException) {
        Log.w(TAG, "Tarayıcı bulunamadı", error)
    }
}

/**
 * Uygulama içi giriş: WebView + yükleme göstergesi + hata durumu. "Tarayıcıda aç" ve "Kapat" en baştan, yükleme
 * sürerken de ekrandadır; zaman aşımı ekran açıldığı anda başlar ve WebView'in olaylarını beklemez (PsnLoadWatch).
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun PsnWebLogin(
    earlyCleanup: Deferred<Result<Unit>>?,
    onRedirect: (String) -> Unit,
    onClose: () -> Unit,
    onBrowser: () -> Unit,
    onManual: () -> Unit,
    onGoogle: () -> Unit,
) {
    // Her "Yeniden dene" yeni bir WebView kurar (çöken sayfa süreci de böyle atılır).
    var attempt by remember { mutableIntStateOf(0) }
    var progress by remember { mutableIntStateOf(0) }
    var visible by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<Pair<PsnPageProblem, String?>?>(null) }
    var cookiesReady by remember { mutableStateOf(false) }
    // Yönlendirme yakalandı, hesap kimliği Sony'den alınıyor.
    var completing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val background = Tokens.Color.bg.toArgb()
    val failures = pageProblems()

    fun retry() {
        failure = null
        visible = false
        progress = 0
        cookiesReady = false
        attempt++
    }

    fun fail(problem: PsnPageProblem, detail: String?) {
        Log.w(TAG, "Giriş sayfası açılamadı: $problem ${detail ?: ""}")
        if (failure == null) failure = problem to detail
    }

    ScreenBackground {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            Box(Modifier.padding(Tokens.Space.screen)) { TopBar(stringResource(R.string.psn_open), onClose = onClose) }
            if (failure == null && progress < 100) LinearProgressIndicator(
                progress = { progress / 100f }, modifier = Modifier.fillMaxWidth(),
                color = Tokens.Color.accent, trackColor = Tokens.Color.border,
            )
            Box(Modifier.fillMaxWidth().weight(1f)) {
                key(attempt) {
                    val watch = remember { PsnLoadWatch(SystemClock.elapsedRealtime()) }
                    // Bağımsız sayaç: WebView hiç kurulmasa, yüklemeye hiç başlamasa ya da Sony'nin sayfası kendi
                    // yükleme simgesinde takılsa da süre dolunca hata ekranı çıkar.
                    LaunchedEffect(Unit) {
                        delay(PsnLoadWatch.LOAD_TIMEOUT_MS)
                        watch.problemAt(SystemClock.elapsedRealtime())?.let { problem ->
                            fail(problem, if (watch.pageFinished) null else if (cookiesReady) "no page" else "no webview")
                        }
                    }
                    // Her girişte temiz oturum: önceki çerezler (ör. kendi hesabın) karışmasın. Silme eşzamansızdır; sayfa
                    // bittikten sonra açılır (yoksa Sony'nin ilk yönlendirmede koyduğu çerezler yolda silinir). İlk denemede
                    // temizlik giriş ekranında başlamıştır; "Yeniden dene"de (WebView artık sıcak) yeniden yapılır. Bazı
                    // telefonlarda geri çağrı hiç dönmez: en çok COOKIE_WAIT_MS beklenir, sonra sayfa yine açılır.
                    LaunchedEffect(Unit) {
                        val cleanup = earlyCleanup.takeIf { attempt == 0 } ?: scope.async { PsnWebData.clear() }
                        val result = withTimeoutOrNull(PsnLoadWatch.COOKIE_WAIT_MS) { cleanup.await() }
                        val error = result?.exceptionOrNull()
                        if (error != null) {
                            // WebView kurulu değil ya da güncelleniyor: CookieManager açılamaz.
                            fail(PsnPageProblem.CRASHED, error.javaClass.simpleName)
                            return@LaunchedEffect
                        }
                        if (result == null) Log.w(TAG, "Çerez silme ${PsnLoadWatch.COOKIE_WAIT_MS} ms'de dönmedi; sayfa yine açılıyor")
                        cookiesReady = true
                    }
                    if (cookiesReady) AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { context ->
                            try {
                                WebView(context)
                            } catch (error: RuntimeException) {
                                Log.w(TAG, "WebView açılamadı", error)
                                fail(PsnPageProblem.CRASHED, error.javaClass.simpleName)
                                null
                            }?.apply {
                                setBackgroundColor(background)
                                settings.javaScriptEnabled = true
                                settings.domStorageEnabled = true
                                // Sony'nin girişi sonyentertainmentnetwork.com, sony.com ve playstation.com arasında gidip
                                // gelir; WebView üçüncü taraf çerezleri varsayılan olarak reddeder (masaüstü tarayıcılar kabul eder).
                                CookieManager.getInstance().setAcceptCookie(true)
                                CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                                webChromeClient = object : WebChromeClient() {
                                    override fun onProgressChanged(view: WebView, newProgress: Int) {
                                        progress = newProgress
                                    }

                                    override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                                        if (message.messageLevel() == ConsoleMessage.MessageLevel.ERROR)
                                            Log.w(TAG, "Sayfa: ${message.message()} (${message.sourceId()}:${message.lineNumber()})")
                                        return true
                                    }
                                }
                                webViewClient = LoginClient(
                                    watch = watch,
                                    onRedirect = { url ->
                                        // Hesap kimliği alınırken sayfa yerine bekleme göstergesi.
                                        visible = false
                                        completing = true
                                        onRedirect(url)
                                    },
                                    onVisible = { visible = true },
                                    onGoogle = {
                                        Log.i(TAG, "Google ile giriş seçildi; giriş tarayıcıya taşınıyor")
                                        onGoogle()
                                    },
                                    onFailure = ::fail,
                                    schedule = { delayMs, block -> scope.launch { delay(delayMs); block() } },
                                )
                                Log.i(TAG, "Giriş sayfası açılıyor (WebView ${WebView.getCurrentWebViewPackage()?.versionName})")
                                loadUrl(PsnAccount.authorizeUrl)
                            } ?: View(context)
                        },
                        onRelease = { view ->
                            if (view is WebView) {
                                (view.webViewClient as? LoginClient)?.cancel()
                                view.stopLoading()
                                view.destroy()
                            }
                        },
                    )
                }
                if (failure == null && !visible) Column(
                    Modifier.fillMaxSize().background(Tokens.Color.bg).padding(Tokens.Space.screen),
                    verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator(color = Tokens.Color.accent)
                    BodyText(stringResource(if (completing) R.string.psn_completing else R.string.psn_loading))
                    if (!completing) BodyText(stringResource(R.string.psn_loading_hint), align = TextAlign.Center)
                }
                failure?.let { (problem, detail) ->
                    Column(
                        Modifier.fillMaxSize().background(Tokens.Color.bg).padding(Tokens.Space.screen),
                        verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap, Alignment.CenterVertically),
                    ) {
                        Heading(stringResource(R.string.psn_page_failed), failures(problem) + (detail?.let { " ($it)" } ?: ""))
                        NoteTile(stringResource(R.string.psn_page_failed_hint), Tokens.Color.secondary)
                        PrimaryButton(stringResource(R.string.psn_retry)) { retry() }
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            GhostButton(stringResource(R.string.psn_browser), onClick = onBrowser)
                        }
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            GhostButton(stringResource(R.string.psn_manual), onClick = onManual)
                        }
                    }
                }
            }
            // Çıkış yolları her zaman ekranda: sayfa hiç gelmese de kullanıcı tarayıcıya geçebilir ya da kapatabilir.
            if (failure == null) Row(
                Modifier.fillMaxWidth().padding(horizontal = Tokens.Space.screen),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                GhostButton(stringResource(R.string.psn_browser), onClick = onBrowser)
                GhostButton(stringResource(R.string.close), color = Tokens.Color.secondary, onClick = onClose)
            }
        }
    }
}

/** Uygulama içi girişin WebView verisi (çerezler, sayfa depoları). */
private object PsnWebData {
    /**
     * Sayfa depolarını (localStorage, IndexedDB, service worker) ve çerezleri siler. Çerez silme bitene
     * kadar bekler; sayfa depolarının silinmesinin geri çağrısı yoktur, bu yüzden sayfa yüklenmeden önce yapılmalıdır.
     * Hata (WebView kurulu değil ya da güncelleniyor) sonuçta döner, iş parçacığını düşürmez.
     */
    suspend fun clear(): Result<Unit> = try {
        WebStorage.getInstance().deleteAllData()
        val cookies = CookieManager.getInstance()
        suspendCancellableCoroutine { done -> cookies.removeAllCookies { if (done.isActive) done.resume(Unit) } }
        Result.success(Unit)
    } catch (error: CancellationException) {
        throw error
    } catch (error: RuntimeException) {
        Log.w(TAG, "WebView verisi silinemedi", error)
        Result.failure(error)
    }
}

/** WebView olayları; yönlendirme yakalanır, ana sayfanın hataları beyaz ekran yerine bildirilir. */
private class LoginClient(
    private val watch: PsnLoadWatch,
    private val onRedirect: (String) -> Unit,
    private val onVisible: () -> Unit,
    private val onGoogle: () -> Unit,
    private val onFailure: (PsnPageProblem, String?) -> Unit,
    private val schedule: (Long, () -> Unit) -> Job,
) : WebViewClient() {
    private var redirected = false
    private var cancelled = false
    private var shown = false
    private var readyPoll: Job? = null

    fun cancel() {
        cancelled = true
        readyPoll?.cancel()
    }

    private fun capture(url: String): Boolean {
        if (!PsnAccount.isRedirect(url)) return false
        if (!redirected) {
            redirected = true
            watch.onRedirect()
            cancel()
            onRedirect(url)
        }
        return true
    }

    /** Google WebView'da girişi reddeder ("disallowed_useragent"); sayfa açılmadan giriş tarayıcıya taşınır. */
    private fun leaveForGoogle(url: String): Boolean {
        if (!PsnAccount.isGoogleSignIn(url)) return false
        if (!redirected && !cancelled) {
            cancel()
            onGoogle()
        }
        return true
    }

    private fun fail(problem: PsnPageProblem, detail: String?) {
        if (redirected || cancelled) return
        cancel()
        onFailure(problem, detail)
    }

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
        request.isForMainFrame && (capture(request.url.toString()) || leaveForGoogle(request.url.toString()))

    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
        // shouldOverrideUrlLoading her yönlendirmede (ör. POST'tan sonraki) çağrılmaz; sayfa başlarken de bakılır.
        if (capture(url) || leaveForGoogle(url)) {
            view.stopLoading()
            return
        }
        Log.i(TAG, "Sayfa başladı: ${Uri.parse(url).host}")
    }

    override fun onPageCommitVisible(view: WebView, url: String) {
        if (redirected || cancelled) return
        shown = true
        onVisible()
        // Bir alt kaynak takılırsa onPageFinished gecikir; form görünür olur olmaz da bakılır.
        if (readyPoll == null) poll(view)
    }

    override fun onPageFinished(view: WebView, url: String) {
        if (redirected || cancelled || PsnAccount.isRedirect(url)) return
        Log.i(TAG, "Sayfa bitti: ${Uri.parse(url).host}")
        watch.onPageFinished()
        if (!shown) {
            shown = true
            onVisible()
        }
        // Sony'nin sayfası tek sayfalık bir uygulamadır: betikleri çalışmazsa sayfa "yüklenir" ama boş kalır ya da kendi
        // yükleme simgesinde takılır. Giriş formu çizilene kadar bakılır; çizilmezse PsnLoadWatch süre dolunca bildirir.
        if (readyPoll == null) poll(view)
    }

    private fun poll(view: WebView) {
        readyPoll = schedule(PsnLoadWatch.READY_POLL_MS) {
            if (redirected || cancelled || watch.ready) return@schedule
            view.evaluateJavascript(PsnLoadWatch.INTERACTIVE_SCRIPT) { count ->
                watch.onInteractiveCount(count)
                if (watch.ready) Log.i(TAG, "Giriş formu çizildi") else if (!cancelled) poll(view)
            }
        }
    }

    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
        if (!request.isForMainFrame || PsnAccount.isRedirect(request.url.toString())) return
        fail(PsnPageProblem.fromWebError(error.errorCode), "${error.errorCode} ${error.description}")
    }

    override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
        val url = request.url.toString()
        if (PsnAccount.isRedirect(url)) return
        if (request.isForMainFrame) fail(PsnPageProblem.HTTP, "HTTP ${response.statusCode}")
        else Log.w(TAG, "Kaynak yüklenemedi: HTTP ${response.statusCode} ${request.url.host}${request.url.path}")
    }

    @SuppressLint("WebViewClientOnReceivedSslError")
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
        handler.cancel()
        fail(PsnPageProblem.SSL, "SSL ${error.primaryError}")
    }

    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        // true dönülmezse uygulama da kapanır; WebView "Yeniden dene" ile yeniden kurulur.
        fail(PsnPageProblem.fromRenderGone(detail.didCrash()), null)
        return true
    }
}

/**
 * Tarayıcıda giriş: Sony girişten sonra tarayıcıyı yönlendirme adresine götürür. O adres Sony'nin alanında olduğundan
 * (App Link kurulamaz) tarayıcı uygulamaya kendiliğinden dönmez; kullanıcı adresi kopyalar. Uygulamaya dönülünce
 * panoda yönlendirme adresi varsa kendiliğinden alınır ve giriş tamamlanır; yoksa adres elle yapıştırılır.
 */
@Composable
private fun PsnBrowserLogin(
    viaGoogle: Boolean,
    tried: String?,
    onRedirect: (String) -> Unit,
    onReopen: () -> Unit,
    onClose: () -> Unit,
) {
    var text by rememberSaveable { mutableStateOf("") }
    val redirect = PsnAccount.redirectFromText(text)
    val context = LocalContext.current
    // Android 10'dan beri pano yalnız pencere odaktayken okunabilir: tarayıcıdan dönüp pencere odak alınca bakılır.
    val focused = LocalWindowInfo.current.isWindowFocused
    LaunchedEffect(focused) {
        if (!focused) return@LaunchedEffect
        val found = readClip(context)?.let(PsnAccount::redirectFromText)?.takeIf { it != tried } ?: return@LaunchedEffect
        Log.i(TAG, "Panoda yönlendirme adresi bulundu")
        text = found
        onRedirect(found)
    }
    ScreenScaffold(top = { TopBar(onBack = onClose) }, bottom = {
        GhostButton(stringResource(R.string.psn_browser_reopen), onClick = onReopen)
        PrimaryButton(stringResource(R.string.next), enabled = redirect != null) { redirect?.let(onRedirect) }
    }) {
        Heading(stringResource(R.string.psn_browser_title), stringResource(R.string.psn_browser_body))
        if (viaGoogle) NoteTile(stringResource(R.string.psn_browser_google), Tokens.Color.secondary)
        Field(text, { text = it }, stringResource(R.string.psn_browser_field), keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
        if (text.isNotBlank() && redirect == null) NoteTile(stringResource(R.string.psn_browser_wrong))
    }
}

/**
 * Elle hesap kimliği girişi: Sony girişi açılamıyorsa ya da kullanıcının elinde chiaki-ng / masaüstü CouchSubs'tan
 * alınmış 12 karakterli base64 hesap kimliği varsa doğrudan kaydedilir.
 */
@Composable
private fun PsnManualLogin(
    onSave: (ByteArray) -> Unit,
    onClose: () -> Unit,
) {
    var text by rememberSaveable { mutableStateOf("") }
    var showError by rememberSaveable { mutableStateOf(false) }
    val accountId = PsnAccount.accountIdFromBase64(text)
    val looksInvalid = (showError || text.filterNot(Char::isWhitespace).length >= 12) && accountId == null
    ScreenScaffold(top = { TopBar(onBack = onClose) }, bottom = {
        PrimaryButton(stringResource(R.string.psn_manual_save), enabled = text.isNotBlank()) {
            if (accountId != null) onSave(accountId) else showError = true
        }
    }) {
        Heading(stringResource(R.string.psn_manual_title), stringResource(R.string.psn_manual_body))
        Field(
            value = text,
            onChange = { text = it; showError = false },
            label = stringResource(R.string.psn_manual_field),
            keyboard = KeyboardOptions(keyboardType = KeyboardType.Ascii),
            placeholder = "AbCdEfGhIjk=",
            mono = true,
        )
        if (looksInvalid) NoteTile(stringResource(R.string.psn_manual_wrong))
    }
}

@Composable
internal fun pageProblems(): (PsnPageProblem) -> String {
    val context = LocalContext.current
    return { problem ->
        context.getString(when (problem) {
            PsnPageProblem.OFFLINE -> R.string.psn_problem_offline
            PsnPageProblem.TIMEOUT -> R.string.psn_problem_timeout
            PsnPageProblem.SSL -> R.string.psn_problem_ssl
            PsnPageProblem.HTTP -> R.string.psn_problem_http
            PsnPageProblem.BLANK -> R.string.psn_problem_blank
            PsnPageProblem.CRASHED -> R.string.psn_problem_crashed
            PsnPageProblem.OUT_OF_MEMORY -> R.string.webview_out_of_memory
            PsnPageProblem.OTHER -> R.string.psn_problem_other
        })
    }
}
