// SPDX-License-Identifier: AGPL-3.0-only
// Deneysel: TV uygulamasını bilgisayarsız, bu telefondan kurmak (şimdilik Samsung). Ayarlar › Deneysel'den açılır.
package com.couchsubs.mobile.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
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
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.viewinterop.AndroidView
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
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
import com.couchsubs.mobile.tv.samsung.SamsungTvInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.net.Inet4Address

private const val TAG = "CouchSubsTvInstall"

/** Ağda görülen Samsung TV ve 8001'den okunan durumu (yoksa null). */
private data class SamsungCandidate(val host: String, val name: String, val info: SamsungTvInfo?)

private sealed interface InstallState {
    data object Idle : InstallState
    data class Working(val step: InstallStep) : InstallState
    data class Done(val version: String, val installed: Boolean) : InstallState
    data class Failed(val error: SamsungInstallError?, val detail: String?) : InstallState
}

/** Kurulum ekranı: üstteki seçimle marka değişir (Samsung, Android TV); her markanın akışı ayrıdır. */
@Composable
fun TvInstallScreen(onBack: () -> Unit) {
    var brand by remember { mutableStateOf(Services.settings.tvInstallBrand) }
    val brands = listOf(TvBrand.SAMSUNG, TvBrand.ANDROID_TV)
    val picker: @Composable () -> Unit = {
        Segmented(listOf(stringResource(R.string.tvinstall_brand_samsung), stringResource(R.string.tvinstall_brand_android)),
            brands.indexOf(brand).coerceAtLeast(0)) {
            brand = brands[it]
            Services.settings.tvInstallBrand = brand
        }
    }
    when (brand) {
        TvBrand.ANDROID_TV -> AndroidTvInstallScreen(onBack, picker)
        else -> SamsungInstallScreen(onBack, picker)
    }
}

@Composable
private fun SamsungInstallScreen(onBack: () -> Unit, brandPicker: @Composable () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val phoneIp = remember { phoneAddress(context) }
    var candidates by remember { mutableStateOf<List<SamsungCandidate>?>(null) }
    var host by remember { mutableStateOf("") }
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

    fun install() {
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
                        BuildConfig.TV_SAMSUNG_VERSION)
                }
                InstallState.Done(result.version, result.installed)
            } catch (error: SamsungInstallException) {
                InstallState.Failed(error.error, error.detail)
            } catch (error: Exception) {
                Log.w(TAG, "TV kurulumu başarısız", error)
                InstallState.Failed(null, error.message ?: error.javaClass.simpleName)
            }
        }
    }

    login?.let { listener ->
        SamsungSignIn(onClose = { listener.close() })
        return
    }

    ScreenScaffold(top = { TopBar(onBack = onBack) }, bottom = {
        if (!manual && !working) GhostButton(stringResource(R.string.tvinstall_not_found)) { manual = true }
        PrimaryButton(stringResource(if (state is InstallState.Failed) R.string.tvinstall_retry else R.string.tvinstall_button),
            enabled = !working && host.isNotBlank()) { install() }
    }) {
        Heading(stringResource(R.string.tvinstall_title), stringResource(R.string.tvinstall_body))
        if (!working) brandPicker()
        NoteTile(stringResource(R.string.tvinstall_experimental), Tokens.Color.secondary)

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
                            TileIcon(Icons.Filled.Home)
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
        if (manual) Field(host, { host = it.trim() }, stringResource(R.string.tvinstall_address),
            keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))

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
            }
            is InstallState.Failed -> {
                NoteTile(failureText(current, phoneIp))
                GhostButton(stringResource(R.string.tvinstall_share_log)) { shareLog(context, logFile) }
            }
        }
    }
}

/** Uygulama içinde Samsung'un giriş sayfası; "Tarayıcıda aç" aynı dinleyiciye döner. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun SamsungSignIn(onClose: () -> Unit) {
    val context = LocalContext.current
    val background = Tokens.Color.bg.toArgb()
    BackHandler(onBack = onClose)
    ScreenBackground {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            Box(Modifier.padding(Tokens.Space.screen)) {
                TopBar(stringResource(R.string.tvinstall_signin_title), onClose = onClose) {
                    GhostButton(stringResource(R.string.tvinstall_signin_browser)) { open(context, SamsungLogin.authorizeUrl) }
                }
            }
            AndroidView(modifier = Modifier.fillMaxWidth().weight(1f), factory = { viewContext ->
                WebView(viewContext).apply {
                    setBackgroundColor(background)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    // Giriş https sayfasından http://localhost'a gönderilir.
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                    // Samsung'un hesap sayfaları WebView'in "; wv" imzasıyla sorun çıkarıyor (TizenSdb'nin Android denemesi).
                    settings.userAgentString = settings.userAgentString.replace("; wv", "")
                    CookieManager.getInstance().setAcceptCookie(true)
                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                    webViewClient = WebViewClient()
                    loadUrl(SamsungLogin.authorizeUrl)
                }
            })
        }
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
        SamsungInstallError.UNREACHABLE -> context.getString(R.string.tvinstall_err_unreachable, phoneIp ?: "?")
        SamsungInstallError.TOO_OLD -> context.getString(R.string.tvinstall_err_too_old)
        SamsungInstallError.LOGIN_FAILED -> context.getString(R.string.tvinstall_err_login)
        SamsungInstallError.CERTIFICATE_FAILED -> context.getString(R.string.tvinstall_err_certificate)
        SamsungInstallError.NOT_ENOUGH_SPACE -> context.getString(R.string.tvinstall_err_space)
        SamsungInstallError.CERTIFICATE_MISMATCH -> context.getString(R.string.tvinstall_err_mismatch)
        SamsungInstallError.CERTIFICATE_REJECTED -> context.getString(R.string.tvinstall_err_rejected)
        SamsungInstallError.TV_CLOCK_WRONG -> context.getString(R.string.tvinstall_err_clock)
        SamsungInstallError.PACKAGE_BLOCKED -> context.getString(R.string.tvinstall_err_blocked)
        SamsungInstallError.CONNECTION_LOST -> context.getString(R.string.tvinstall_err_connection)
        SamsungInstallError.INSTALL_FAILED, null -> context.getString(R.string.tvinstall_err_failed)
    }
    var text = advice
    failure.detail?.takeIf { it.isNotBlank() }?.let { text += "\n\n" + context.getString(R.string.tvinstall_details, it) }
    if (failure.error == SamsungInstallError.INSTALL_FAILED || failure.error == SamsungInstallError.CERTIFICATE_REJECTED)
        text += "\n\n" + context.getString(R.string.tvinstall_maintenance)
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
    connectivity.getLinkProperties(connectivity.activeNetwork)?.linkAddresses
        ?.map { it.address }?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }?.hostAddress
} catch (error: Exception) {
    null
}

internal fun shareLog(context: Context, file: File) {
    val text = runCatching { file.readText().takeLast(60_000) }.getOrDefault("")
    val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, "CouchSubs tvinstall.log")
        .putExtra(Intent.EXTRA_TEXT, text)
    runCatching { context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}
