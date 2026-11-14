// SPDX-License-Identifier: AGPL-3.0-only
// Kurulumun PSN adımı (tuval: Telefon-PSN). Sony'nin giriş sayfası uygulama içi WebView'da açılır; yönlendirme
// yakalanır, parola yalnız Sony'ye gider. "Tarayıcıda aç" (adresi yapıştırma) ve "Kapat" hep ekrandadır; sayfa
// LOAD_TIMEOUT_MS içinde giriş formunu çizmezse nedeni ve "Yeniden dene" gösterilir.
package com.couchsubs.mobile.ui

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
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
import androidx.compose.material.icons.filled.PlayArrow
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.viewinterop.AndroidView
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.remoteplay.PsnAccount
import com.couchsubs.mobile.remoteplay.PsnLoadWatch
import com.couchsubs.mobile.remoteplay.PsnPageProblem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

private const val TAG = "CouchSubsPsn"

private enum class PsnMode { INTRO, WEB, BROWSER }

@Composable
fun PsnLoginScreen(onBack: (() -> Unit)? = null, onSkip: (() -> Unit)? = null, onDone: () -> Unit) {
    var mode by remember { mutableStateOf(PsnMode.INTRO) }
    var problem by remember { mutableStateOf<String?>(null) }
    var why by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    // Yönlendirme (uygulama içinden ya da tarayıcıdan yapıştırılan) hesap kimliğine çevrilir.
    fun finish(redirect: String) {
        scope.launch {
            try {
                Services.settings.accountId = withContext(Dispatchers.IO) { PsnAccount.accountIdFromRedirect(redirect) }
                onDone()
            } catch (error: Exception) {
                Log.w(TAG, "PSN girişi tamamlanmadı", error)
                problem = error.message
                mode = PsnMode.INTRO
            }
        }
    }

    fun openBrowser() {
        mode = PsnMode.BROWSER
        openInBrowser(context)
    }

    BackHandler(enabled = mode != PsnMode.INTRO) { mode = PsnMode.INTRO }
    when (mode) {
        PsnMode.INTRO -> {
            ScreenScaffold(top = { TopBar(onBack = onBack) { SkipAction(onSkip) } }, bottom = {
                GhostButton(stringResource(R.string.psn_why)) { why = true }
                PrimaryButton(stringResource(R.string.psn_open)) {
                    problem = null
                    mode = PsnMode.WEB
                }
            }) {
                Heading(stringResource(R.string.psn_title), stringResource(R.string.psn_body), stringResource(R.string.setup_step, 1))
                TwoColumns(
                    { StatusTile(Icons.Filled.Person, stringResource(R.string.psn_free_note), stringResource(R.string.psn_free), it) },
                    { StatusTile(Icons.Filled.PlayArrow, stringResource(R.string.psn_you_play_note), stringResource(R.string.psn_you_play), it) },
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
                problem?.let {
                    NoteTile(stringResource(R.string.psn_failed, it))
                    GhostButton(stringResource(R.string.psn_browser)) { openBrowser() }
                }
            }
            if (why) InfoDialog(stringResource(R.string.psn_why), stringResource(R.string.psn_why_body)) { why = false }
        }
        PsnMode.WEB -> PsnWebLogin(
            onRedirect = ::finish,
            onClose = { mode = PsnMode.INTRO },
            onBrowser = ::openBrowser,
        )
        PsnMode.BROWSER -> PsnBrowserLogin(
            onRedirect = ::finish,
            onReopen = { openInBrowser(context) },
            onClose = { mode = PsnMode.INTRO },
        )
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
private fun PsnWebLogin(onRedirect: (String) -> Unit, onClose: () -> Unit, onBrowser: () -> Unit) {
    // Her "Yeniden dene" yeni bir WebView kurar (çöken sayfa süreci de böyle atılır).
    var attempt by remember { mutableIntStateOf(0) }
    var progress by remember { mutableIntStateOf(0) }
    var visible by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<Pair<PsnPageProblem, String?>?>(null) }
    var cookiesReady by remember { mutableStateOf(false) }
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
                    // bittikten sonra açılır (yoksa Sony'nin ilk yönlendirmede koyduğu çerezler yolda silinir), ama bazı
                    // telefonlarda geri çağrı hiç dönmez: en çok COOKIE_WAIT_MS beklenir, sonra sayfa yine açılır.
                    LaunchedEffect(Unit) {
                        try {
                            WebStorage.getInstance().deleteAllData()
                            val cleared = withTimeoutOrNull(PsnLoadWatch.COOKIE_WAIT_MS) {
                                suspendCancellableCoroutine { done ->
                                    CookieManager.getInstance().removeAllCookies { if (done.isActive) done.resume(it) }
                                }
                            }
                            if (cleared == null) Log.w(TAG, "Çerez silme ${PsnLoadWatch.COOKIE_WAIT_MS} ms'de dönmedi; sayfa yine açılıyor")
                            cookiesReady = true
                        } catch (error: RuntimeException) {
                            // WebView kurulu değil ya da güncelleniyor: CookieManager açılamaz.
                            Log.w(TAG, "WebView açılamadı", error)
                            fail(PsnPageProblem.CRASHED, error.javaClass.simpleName)
                        }
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
                                        onRedirect(url)
                                    },
                                    onVisible = { visible = true },
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
                    BodyText(stringResource(R.string.psn_loading))
                    BodyText(stringResource(R.string.psn_loading_hint), align = TextAlign.Center)
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

/** WebView olayları; yönlendirme yakalanır, ana sayfanın hataları beyaz ekran yerine bildirilir. */
private class LoginClient(
    private val watch: PsnLoadWatch,
    private val onRedirect: (String) -> Unit,
    private val onVisible: () -> Unit,
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

    private fun fail(problem: PsnPageProblem, detail: String?) {
        if (redirected || cancelled) return
        cancel()
        onFailure(problem, detail)
    }

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
        request.isForMainFrame && capture(request.url.toString())

    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
        // shouldOverrideUrlLoading her yönlendirmede (ör. POST'tan sonraki) çağrılmaz; sayfa başlarken de bakılır.
        if (capture(url)) {
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
        fail(PsnPageProblem.CRASHED, if (detail.didCrash()) "crash" else "oom")
        return true
    }
}

/** Tarayıcıda giriş: Sony girişten sonra tarayıcıyı yönlendirme adresine götürür; kullanıcı o adresi yapıştırır. */
@Composable
private fun PsnBrowserLogin(onRedirect: (String) -> Unit, onReopen: () -> Unit, onClose: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val redirect = PsnAccount.redirectFromText(text)
    ScreenScaffold(top = { TopBar(onBack = onClose) }, bottom = {
        GhostButton(stringResource(R.string.psn_browser_reopen), onClick = onReopen)
        PrimaryButton(stringResource(R.string.next), enabled = redirect != null) { redirect?.let(onRedirect) }
    }) {
        Heading(stringResource(R.string.psn_browser_title), stringResource(R.string.psn_browser_body))
        Field(text, { text = it }, stringResource(R.string.psn_browser_field), keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
        if (text.isNotBlank() && redirect == null) NoteTile(stringResource(R.string.psn_browser_wrong))
    }
}

@Composable
private fun pageProblems(): (PsnPageProblem) -> String {
    val context = LocalContext.current
    return { problem ->
        context.getString(when (problem) {
            PsnPageProblem.OFFLINE -> R.string.psn_problem_offline
            PsnPageProblem.TIMEOUT -> R.string.psn_problem_timeout
            PsnPageProblem.SSL -> R.string.psn_problem_ssl
            PsnPageProblem.HTTP -> R.string.psn_problem_http
            PsnPageProblem.BLANK -> R.string.psn_problem_blank
            PsnPageProblem.CRASHED -> R.string.psn_problem_crashed
            PsnPageProblem.OTHER -> R.string.psn_problem_other
        })
    }
}
