// SPDX-License-Identifier: AGPL-3.0-only
// Yer tutucu ekranlar: akış ve tesisat çalışsın diye ince tutuldu. Onaylanan tasarım (docs/TASARIM.md, design/tokens.json)
// gelince yeniden yapılacak; değerler Theme.kt'deki Tokens'tan gelir.
package com.couchsubs.mobile.ui

import android.annotation.SuppressLint
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.viewinterop.AndroidView
import com.couchsubs.mobile.R
import com.couchsubs.mobile.core.GamePackLibrary
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.remoteplay.ConsoleDiscovery
import com.couchsubs.mobile.remoteplay.ConsoleInfo
import com.couchsubs.mobile.remoteplay.PsnAccount
import com.couchsubs.mobile.remoteplay.Registration
import com.couchsubs.mobile.remoteplay.RegistrationException
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.settings.EngineChoice
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.tv.FoundTv
import com.couchsubs.mobile.tv.TvDiscovery
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
private fun Page(title: String, content: @Composable () -> Unit) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            Modifier.safeDrawingPadding().padding(Tokens.Space.xl).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Tokens.Space.l),
        ) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            content()
        }
    }
}

@Composable
private fun Primary(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick, Modifier.fillMaxWidth().height(Tokens.Size.primaryActionHeight), enabled = enabled) { Text(text) }
}

@Composable
private fun Body(text: String) = Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
fun WelcomeScreen(onNext: () -> Unit) = Page("CouchSubs") {
    Text(stringResource(R.string.welcome_title), style = MaterialTheme.typography.titleMedium)
    Body(stringResource(R.string.welcome_body))
    Primary(stringResource(R.string.welcome_start), onClick = onNext)
}

/** Sony'nin giriş sayfası uygulama içi WebView'da; yönlendirme yakalanır, parola yalnız Sony'ye gider. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun PsnLoginScreen(settings: AppSettings, onDone: () -> Unit) {
    var opened by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    if (!opened) {
        Page(stringResource(R.string.psn_title)) {
            Body(stringResource(R.string.psn_body))
            problem?.let { Text(stringResource(R.string.psn_failed, it), color = MaterialTheme.colorScheme.error) }
            Primary(stringResource(R.string.psn_open)) {
                // Her girişte temiz oturum: önceki çerezler (ör. kendi hesabınız) karışmasın.
                CookieManager.getInstance().removeAllCookies(null)
                opened = true
            }
        }
        return
    }
    AndroidView(modifier = Modifier.fillMaxSize().safeDrawingPadding(), factory = { context ->
        WebView(context).apply {
            this.settings.javaScriptEnabled = true
            this.settings.domStorageEnabled = true
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val url = request.url.toString()
                    if (!PsnAccount.isRedirect(url)) return false
                    scope.launch {
                        try {
                            val id = withContext(Dispatchers.IO) { PsnAccount.accountIdFromRedirect(url) }
                            settings.accountId = id
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

@Composable
fun PairScreen(settings: AppSettings, onDone: () -> Unit) {
    var consoles by remember { mutableStateOf<List<ConsoleInfo>?>(null) }
    var host by remember { mutableStateOf(settings.console?.host ?: "") }
    var code by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        consoles = withContext(Dispatchers.IO) { ConsoleDiscovery.discover(null, 3000) }
        if (host.isEmpty()) consoles?.firstOrNull()?.let { host = it.host }
    }
    Page(stringResource(R.string.pair_title)) {
        Body(stringResource(R.string.pair_body))
        when (val list = consoles) {
            null -> Body(stringResource(R.string.pair_searching))
            else -> if (list.isEmpty()) Body(stringResource(R.string.pair_none))
            else list.forEach { console ->
                Row(Modifier.fillMaxWidth().clickable { host = console.host }, verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = host == console.host, onClick = { host = console.host })
                    Text("${console.name}  ·  ${console.host}")
                }
            }
        }
        OutlinedTextField(host, { host = it.trim() }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.pair_address)) },
            singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.pair_code)) },
            singleLine = true, textStyle = MaterialTheme.typography.titleLarge, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
        problem?.let { Text(stringResource(R.string.pair_failed, it), color = MaterialTheme.colorScheme.error) }
        if (working) Body(stringResource(R.string.pair_working))
        val pin = Registration.parsePin(code)
        Primary(stringResource(R.string.pair_button), enabled = !working && pin != null && host.isNotEmpty()) {
            val accountId = settings.accountId ?: return@Primary
            working = true
            problem = null
            scope.launch {
                try {
                    val registered = withContext(Dispatchers.IO) { Registration.register(host, accountId, pin!!) }
                    settings.console = registered
                    onDone()
                } catch (error: RegistrationException) {
                    problem = error.failure.name + (error.detail?.let { " ($it)" } ?: "")
                } catch (error: Exception) {
                    problem = error.message
                } finally {
                    working = false
                }
            }
        }
    }
}

@Composable
fun TargetScreen(settings: AppSettings, onDone: () -> Unit) {
    var target by remember { mutableStateOf(settings.target) }
    var tvs by remember { mutableStateOf<List<FoundTv>?>(null) }
    LaunchedEffect(Unit) {
        tvs = withContext(Dispatchers.IO) { runCatching { TvDiscovery.search() }.getOrDefault(emptyList()) }
    }
    Page(stringResource(R.string.target_title)) {
        Choice(target == SubtitleTarget.TV, stringResource(R.string.target_tv), stringResource(R.string.target_tv_body)) { target = SubtitleTarget.TV }
        if (target == SubtitleTarget.TV) {
            val found = tvs
            if (found != null) Body(if (found.isEmpty()) stringResource(R.string.target_tvs_none) else stringResource(R.string.target_tvs_found))
            found?.forEach { Text("• ${it.name} (${it.host})") }
        }
        Choice(target == SubtitleTarget.PHONE, stringResource(R.string.target_phone), stringResource(R.string.target_phone_body)) { target = SubtitleTarget.PHONE }
        Primary(stringResource(R.string.finish)) {
            settings.target = target
            onDone()
        }
    }
}

@Composable
private fun Choice(selected: Boolean, title: String, body: String, onClick: () -> Unit) {
    Card(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(Modifier.padding(Tokens.Space.l), verticalAlignment = Alignment.CenterVertically) {
            RadioButton(selected, onClick)
            Column {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Body(body)
            }
        }
    }
}

@Composable
fun MainScreen(
    status: LiveStatus,
    target: SubtitleTarget,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onPhoneView: () -> Unit,
    onSettings: () -> Unit,
) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.safeDrawingPadding().padding(Tokens.Space.xl), verticalArrangement = Arrangement.spacedBy(Tokens.Space.l)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("CouchSubs", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                OutlinedButton(onSettings) { Text(stringResource(R.string.settings)) }
            }
            Body(if (status.running) status.phase else stringResource(R.string.main_idle))
            if (status.running && target == SubtitleTarget.TV) Body(stringResource(R.string.main_tvs, status.connectedTvs))
            status.packInUse?.let { Text(stringResource(R.string.main_pack, it), color = MaterialTheme.colorScheme.onSecondaryContainer) }
            status.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (status.running) {
                Button(onStop, Modifier.fillMaxWidth().height(Tokens.Size.primaryActionHeight),
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError)) {
                    Text(stringResource(R.string.stop))
                }
                OutlinedButton(onPhoneView, Modifier.fillMaxWidth()) { Text(stringResource(R.string.main_phone_view)) }
            } else Primary(stringResource(R.string.start), onClick = onStart)
            Text(stringResource(R.string.main_recent), style = MaterialTheme.typography.titleMedium)
            LazyColumn(verticalArrangement = Arrangement.spacedBy(Tokens.Space.m)) {
                items(status.recent) { pair ->
                    Column {
                        Text(pair.translation, style = MaterialTheme.typography.bodyLarge)
                        Text(pair.source, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
fun SettingsScreen(settings: AppSettings, onBack: () -> Unit, onRepair: () -> Unit) {
    val context = LocalContext.current
    var engine by remember { mutableStateOf(settings.engine) }
    var key by remember(engine) { mutableStateOf(settings.apiKey(engine) ?: "") }
    var packsOn by remember { mutableStateOf(settings.packsEnabled) }
    var disabled by remember { mutableStateOf(settings.disabledPacks) }
    var size by remember { mutableStateOf(settings.phoneTextSize.toFloat()) }
    var color by remember { mutableStateOf(settings.textColor) }
    var pool by remember { mutableStateOf(settings.sharePool) }
    var screenOn by remember { mutableStateOf(settings.keepScreenOn) }
    var packs by remember { mutableStateOf<List<GamePackLibrary.Info>>(emptyList()) }
    LaunchedEffect(Unit) {
        packs = withContext(Dispatchers.IO) {
            val assets = context.assets
            GamePackLibrary({ (assets.list("packs") ?: emptyArray()).map { it to assets.open("packs/$it").use { s -> s.readBytes() } } },
                java.io.File(context.filesDir, "packs")).infos
        }
    }
    Page(stringResource(R.string.settings)) {
        OutlinedButton(onBack) { Text(stringResource(R.string.back)) }
        Text(stringResource(R.string.settings_engine), style = MaterialTheme.typography.titleMedium)
        EngineChoice.entries.forEach { choice ->
            Row(Modifier.fillMaxWidth().clickable { engine = choice; settings.engine = choice }, verticalAlignment = Alignment.CenterVertically) {
                RadioButton(engine == choice, { engine = choice; settings.engine = choice })
                Text(if (choice == EngineChoice.FREE) stringResource(R.string.engine_free) else choice.name.lowercase().replaceFirstChar { it.uppercase() })
            }
        }
        if (engine != EngineChoice.FREE) {
            OutlinedTextField(key, { key = it; settings.setApiKey(engine, it) }, Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.settings_key)) }, singleLine = true, visualTransformation = PasswordVisualTransformation())
        }
        Toggle(stringResource(R.string.settings_packs), stringResource(R.string.settings_packs_body), packsOn) { packsOn = it; settings.packsEnabled = it }
        if (packsOn) packs.forEach { info ->
            Toggle("${info.title} (${info.entries})", null, info.id !in disabled) { on ->
                disabled = if (on) disabled - info.id else disabled + info.id
                settings.disabledPacks = disabled
            }
        }
        Text(stringResource(R.string.settings_text_size), style = MaterialTheme.typography.titleMedium)
        Slider(size, { size = it; settings.phoneTextSize = it.toInt() }, valueRange = 22f..64f)
        Text(stringResource(R.string.settings_color), style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.l), verticalAlignment = Alignment.CenterVertically) {
            SubtitleTextColor.entries.forEach { option ->
                RadioButton(color == option, { color = option; settings.textColor = option })
                Text(stringResource(if (option == SubtitleTextColor.WHITE) R.string.color_white else R.string.color_yellow))
            }
        }
        Toggle(stringResource(R.string.settings_pool), stringResource(R.string.settings_pool_body), pool) { pool = it; settings.sharePool = it }
        Toggle(stringResource(R.string.settings_screen_on), null, screenOn) { screenOn = it; settings.keepScreenOn = it }
        Spacer(Modifier.height(Tokens.Space.s))
        OutlinedButton(onRepair, Modifier.fillMaxWidth()) { Text(stringResource(R.string.settings_repair)) }
    }
}

@Composable
private fun Toggle(title: String, body: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            body?.let { Body(it) }
        }
        Switch(checked, onChange)
    }
}
