// SPDX-License-Identifier: AGPL-3.0-only
// Kurulum akışı (tuval: Telefon-Karsilama, -PSN, -PS5, -Hedef): izin → karşılama (3 sayfa) → PSN girişi (ikinci
// hesap) → PS5 eşleme → altyazı nerede. Uygulamada hesap yoktur.
package com.couchsubs.mobile.ui

import android.annotation.SuppressLint
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.remoteplay.ConsoleDiscovery
import com.couchsubs.mobile.remoteplay.ConsoleInfo
import com.couchsubs.mobile.remoteplay.PsnAccount
import com.couchsubs.mobile.remoteplay.Registration
import com.couchsubs.mobile.remoteplay.RegistrationException
import com.couchsubs.mobile.remoteplay.RegistrationFailure
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.tv.FoundTv
import com.couchsubs.mobile.tv.TvBrand
import com.couchsubs.mobile.tv.TvDiscovery
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Karşılama: üç sayfa, yatay kaydırma, nokta göstergesi; otomatik geçiş yok. */
@Composable
fun WelcomeScreen(onDone: () -> Unit) {
    val pager = rememberPagerState { 3 }
    val scope = rememberCoroutineScope()
    val last = pager.currentPage == 2
    ScreenScaffold(scroll = false, top = {
        TopBar { if (!last) GhostButton(stringResource(R.string.skip), onClick = onDone) }
    }, bottom = {
        Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
            repeat(3) { index ->
                val on = pager.currentPage == index
                Box(Modifier.size(if (on) 10.dp else 8.dp).background(if (on) Tokens.Color.accent else Tokens.Color.borderStrong, CircleShape))
            }
        }
        PrimaryButton(stringResource(if (last) R.string.welcome_start else R.string.next)) {
            if (last) onDone() else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
        }
    }) {
        HorizontalPager(pager, Modifier.fillMaxWidth().weight(1f)) { page ->
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap, Alignment.Bottom)) {
                when (page) {
                    0 -> {
                        Tile(Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.welcome1_sample_tr), style = Tokens.Type.subtitleCurrent, color = Tokens.Color.accentText)
                            Text(stringResource(R.string.welcome1_sample_en), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                        Heading(stringResource(R.string.welcome1_title), stringResource(R.string.welcome1_body))
                    }
                    1 -> {
                        Tile(Modifier.fillMaxWidth()) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                                GameMonogram("GTA")
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                                    Text("Grand Theft Auto V", style = Tokens.Type.headline, color = Tokens.Color.text)
                                    Text(stringResource(R.string.welcome2_gta), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                                }
                                Pill(stringResource(R.string.packs_free))
                            }
                        }
                        TwoColumns(
                            { PackTile("RDR", "Red Dead 2", stringResource(R.string.welcome2_rdr_lines), it) },
                            { PackTile("MAF", "Mafia", stringResource(R.string.welcome2_maf_lines), it) },
                        )
                        Heading(stringResource(R.string.welcome2_title), stringResource(R.string.welcome2_body))
                    }
                    else -> {
                        TwoColumns(
                            { StatusTile(Icons.Filled.Home, stringResource(R.string.welcome3_tv_label), stringResource(R.string.welcome3_tv), it) },
                            { StatusTile(Icons.Filled.Phone, stringResource(R.string.welcome3_phone_label), stringResource(R.string.welcome3_phone), it) },
                        )
                        Tile(Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.welcome3_wifi), style = Tokens.Type.headline, color = Tokens.Color.text)
                            Text(stringResource(R.string.welcome3_wifi_body), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                        Heading(stringResource(R.string.welcome3_title), stringResource(R.string.welcome3_body))
                    }
                }
            }
        }
    }
}

/** Sony'nin giriş sayfası uygulama içi WebView'da; yönlendirme yakalanır, parola yalnız Sony'ye gider. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun PsnLoginScreen(onBack: (() -> Unit)? = null, onSkip: (() -> Unit)? = null, onDone: () -> Unit) {
    var opened by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var why by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    if (!opened) {
        ScreenScaffold(top = { TopBar(onBack = onBack) { SkipAction(onSkip) } }, bottom = {
            GhostButton(stringResource(R.string.psn_why)) { why = true }
            PrimaryButton(stringResource(R.string.psn_open)) {
                // Her girişte temiz oturum: önceki çerezler (ör. kendi hesabın) karışmasın.
                CookieManager.getInstance().removeAllCookies(null)
                opened = true
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
            problem?.let { NoteTile(stringResource(R.string.psn_failed, it)) }
        }
        if (why) InfoDialog(stringResource(R.string.psn_why), stringResource(R.string.psn_why_body)) { why = false }
        return
    }
    AndroidView(modifier = Modifier.fillMaxSize().safeDrawingPadding(), factory = { context ->
        WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val url = request.url.toString()
                    if (!PsnAccount.isRedirect(url)) return false
                    scope.launch {
                        try {
                            Services.settings.accountId = withContext(Dispatchers.IO) { PsnAccount.accountIdFromRedirect(url) }
                            onDone()
                        } catch (error: Exception) {
                            problem = error.message
                            opened = false
                        }
                    }
                    return true
                }
            }
            loadUrl(PsnAccount.authorizeUrl)
        }
    })
}

/** Kurulumda PSN ve PS5 adımlarının sağ üstünde "Şimdilik geç" (PS5'siz de uygulama gezilebilsin). */
@Composable
private fun SkipAction(onSkip: (() -> Unit)?) {
    if (onSkip != null) GhostButton(stringResource(R.string.skip_for_now), onClick = onSkip)
}

@Composable
fun InfoDialog(title: String, body: String, onDismiss: () -> Unit) {
    AlertDialog(onDismissRequest = onDismiss, containerColor = Tokens.Color.surface2,
        title = { Text(title, style = Tokens.Type.headline, color = Tokens.Color.text) },
        text = { Text(body, style = Tokens.Type.body, color = Tokens.Color.secondary) },
        confirmButton = { TextButton(onDismiss) { Text(stringResource(R.string.ok), style = Tokens.Type.headline, color = Tokens.Color.accentText) } })
}

@Composable
fun PairScreen(onBack: (() -> Unit)? = null, onSkip: (() -> Unit)? = null, onDone: () -> Unit) {
    val settings = Services.settings
    var consoles by remember { mutableStateOf<List<ConsoleInfo>?>(null) }
    var host by remember { mutableStateOf(settings.console?.host ?: "") }
    var code by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val failures = registrationErrors()
    LaunchedEffect(Unit) {
        consoles = withContext(Dispatchers.IO) { ConsoleDiscovery.discover(null, 3000) }
        if (host.isEmpty()) consoles?.firstOrNull()?.let { host = it.host }
        if (consoles.isNullOrEmpty()) manual = true
    }
    val pin = Registration.parsePin(code)
    ScreenScaffold(top = { TopBar(onBack = onBack) { SkipAction(onSkip) } }, bottom = {
        if (!manual) GhostButton(stringResource(R.string.pair_not_found)) { manual = true }
        PrimaryButton(stringResource(R.string.pair_button), enabled = !working && pin != null && host.isNotEmpty()) {
            val accountId = settings.accountId ?: return@PrimaryButton
            working = true
            problem = null
            scope.launch {
                try {
                    settings.console = withContext(Dispatchers.IO) { Registration.register(host, accountId, pin!!) }
                    onDone()
                } catch (error: RegistrationException) {
                    problem = failures(error.failure) + (error.detail?.let { " ($it)" } ?: "")
                } catch (error: Exception) {
                    problem = error.message
                } finally {
                    working = false
                }
            }
        }
    }) {
        Heading(stringResource(R.string.pair_title), stringResource(R.string.pair_body), stringResource(R.string.setup_step, 2))
        when (val list = consoles) {
            null -> Tile(Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_searching), style = Tokens.Type.body, color = Tokens.Color.secondary) }
            else -> list.forEach { console ->
                Tile(Modifier.fillMaxWidth(), style = if (host == console.host) TileStyle.ACTIVE else TileStyle.NORMAL, onClick = { host = console.host }) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        TileIcon(Icons.Filled.Check, Tokens.Color.success)
                        Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                            Text(stringResource(R.string.pair_found, console.name), style = Tokens.Type.headline, color = Tokens.Color.text)
                            Text(stringResource(R.string.pair_same_wifi, console.host), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                    }
                }
            }
        }
        if (manual) Field(host, { host = it.trim() }, stringResource(R.string.pair_address), keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
        Tile(Modifier.fillMaxWidth()) {
            TileLabel(stringResource(R.string.pair_code))
            // Görünmez alan rakamları alır; kutular gösterir.
            Box {
                CodeCells(code.filter { it.isDigit() })
                BasicTextField(code, { code = it.filter { c -> c.isDigit() }.take(8) }, Modifier.matchParentSizeCompat().alpha(0.01f),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
            }
            Text(stringResource(R.string.pair_code_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        problem?.let { NoteTile(stringResource(R.string.pair_failed, it)) }
        if (working) Text(stringResource(R.string.pair_working), style = Tokens.Type.body, color = Tokens.Color.secondary)
    }
}

private fun Modifier.matchParentSizeCompat() = this.fillMaxWidth().height(48.dp)

/** Kayıt hatalarının Türkçesi (Windows'taki iletilerle aynı anlam). */
@Composable
fun registrationErrors(): (RegistrationFailure) -> String {
    val context = LocalContext.current
    return { failure ->
        context.getString(when (failure) {
            RegistrationFailure.WRONG_ACCOUNT -> R.string.regist_wrong_account
            RegistrationFailure.WRONG_CODE -> R.string.regist_wrong_code
            RegistrationFailure.IN_USE -> R.string.regist_in_use
            RegistrationFailure.VERSION_MISMATCH -> R.string.regist_version
            RegistrationFailure.CONSOLE_CRASHED -> R.string.regist_crashed
            RegistrationFailure.BAD_ADDRESS -> R.string.regist_bad_address
            RegistrationFailure.NO_ANSWER -> R.string.regist_no_answer
            RegistrationFailure.NO_REPLY -> R.string.regist_no_reply
            RegistrationFailure.FAILED -> R.string.regist_failed
        })
    }
}

@Composable
fun TargetScreen(onBack: (() -> Unit)? = null, onDone: () -> Unit) {
    val context = LocalContext.current
    val settings = Services.settings
    var target by remember { mutableStateOf(settings.target) }
    var tvs by remember { mutableStateOf<List<FoundTv>?>(null) }
    LaunchedEffect(Unit) { tvs = withContext(Dispatchers.IO) { runCatching { TvDiscovery.search() }.getOrDefault(emptyList()) } }
    ScreenScaffold(top = { TopBar(onBack = onBack) }, bottom = {
        PrimaryButton(stringResource(R.string.next_continue)) {
            settings.target = target
            tvs?.firstOrNull()?.let { settings.tvName = it.name }
            settings.onboarded = true
            onDone()
        }
    }) {
        Heading(stringResource(R.string.target_title), stringResource(R.string.target_body), if (onBack == null) stringResource(R.string.setup_step, 3) else null)
        Tile(Modifier.fillMaxWidth(), style = if (target == SubtitleTarget.TV) TileStyle.ACTIVE else TileStyle.NORMAL, onClick = { target = SubtitleTarget.TV }) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                TileIcon(Icons.Filled.Home)
                Text(stringResource(R.string.target_tv), style = Tokens.Type.headline, color = Tokens.Color.text, modifier = Modifier.weight(1f))
                if (target == SubtitleTarget.TV) SelectedCheck()
            }
            when (val found = tvs) {
                null -> Text(stringResource(R.string.target_searching), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                else -> if (found.isEmpty()) Text(stringResource(R.string.target_tvs_none), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                else found.forEach { tv ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(tv.name, style = Tokens.Type.body, color = Tokens.Color.text)
                            Text(brandName(tv.brand), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                        StatusLabel(stringResource(R.string.target_tv_on_network))
                    }
                }
            }
            Text(stringResource(R.string.target_tv_body), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        TwoColumns(
            { StatusTile(Icons.Filled.Phone, stringResource(R.string.target_phone_note), stringResource(R.string.target_phone), it,
                style = if (target == SubtitleTarget.PHONE) TileStyle.ACTIVE else TileStyle.NORMAL,
                corner = { if (target == SubtitleTarget.PHONE) SelectedCheck() }, onClick = { target = SubtitleTarget.PHONE }) },
            { StatusTile(Icons.Filled.Info, stringResource(R.string.target_unlisted_note), stringResource(R.string.target_unlisted), it,
                onClick = { open(context, context.getString(R.string.url_tvs)) }) },
        )
    }
}

fun brandName(brand: TvBrand) = when (brand) {
    TvBrand.LG -> "LG"
    TvBrand.SAMSUNG -> "Samsung"
    TvBrand.ANDROID_TV -> "Android TV"
}
