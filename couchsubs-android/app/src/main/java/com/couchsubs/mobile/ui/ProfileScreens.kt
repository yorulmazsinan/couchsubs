// SPDX-License-Identifier: AGPL-3.0-only
// Profil (cihazlar ve tercihler; hesap yok) ve ayarlar (tuval: Telefon-Profil, -Ayarlar).
package com.couchsubs.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.core.SubtitleBackgroundShape
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.remoteplay.LoginPasscode
import com.couchsubs.mobile.service.TranslationService
import com.couchsubs.mobile.settings.EngineChoice
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.translation.AiModel
import com.couchsubs.mobile.translation.KeyCheck
import com.couchsubs.mobile.translation.OnlineKeyState
import com.couchsubs.mobile.translation.aiProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.couchsubs.mobile.tv.FoundTv
import com.couchsubs.mobile.tv.TvDiscovery


/**
 * Profil (tuval Telefon-Profil, hesapsız): cihazlar (PS5, TV'ler), ikinci PSN hesabı, bildirimler, ortak havuz,
 * kullanım verisi ve gizlilik. Uygulamada hesap ya da giriş yoktur.
 */
@Composable
fun ProfileScreen(onBack: () -> Unit, onSettings: () -> Unit, onPairing: () -> Unit, onTarget: () -> Unit, onPsn: () -> Unit) {
    val context = LocalContext.current
    val settings = Services.settings
    var tvs by remember { mutableStateOf<List<FoundTv>?>(null) }
    var notifyDisconnect by remember { mutableStateOf(settings.notifyDisconnect) }
    var notifyPacks by remember { mutableStateOf(settings.notifyNewPacks) }
    var pool by remember { mutableStateOf(settings.sharePool) }
    var askGame by remember { mutableStateOf(settings.askGame) }
    var usage by remember { mutableStateOf(settings.usageData) }
    LaunchedEffect(Unit) { tvs = withContext(Dispatchers.IO) { runCatching { TvDiscovery.search() }.getOrDefault(emptyList()) } }
    ScreenScaffold(top = { TopBar(stringResource(R.string.profile), onBack = onBack) { SettingsAction(onSettings) } }) {
        TwoColumns(
            { StatusTile(Icons.Filled.Home, "PS5", settings.console?.name ?: stringResource(R.string.profile_not_paired), it,
                corner = { if (settings.console != null) StatusLabel(stringResource(R.string.main_paired)) }, onClick = onPairing) },
            { StatusTile(Icons.Filled.Person, stringResource(R.string.profile_psn),
                stringResource(if (settings.accountId != null) R.string.profile_psn_linked_short else R.string.profile_psn_missing), it,
                onClick = onPsn) },
        )
        Tile(Modifier.fillMaxWidth(), onClick = onTarget) {
            TileLabel(stringResource(R.string.profile_tvs))
            Text(if (settings.target == SubtitleTarget.TV) settings.tvName ?: stringResource(R.string.main_target_tv) else stringResource(R.string.main_target_phone),
                style = Tokens.Type.title, color = Tokens.Color.text)
            when (val found = tvs) {
                null -> Text(stringResource(R.string.target_searching), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                else -> Text(if (found.isEmpty()) stringResource(R.string.target_tvs_none) else found.joinToString { "${it.name} (${brandName(it.brand)})" },
                    style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
        }
        RowList(listOf(
            { RowItem(stringResource(R.string.notify_disconnect)) { Switch(notifyDisconnect, { notifyDisconnect = it; settings.notifyDisconnect = it }) } },
            { RowItem(stringResource(R.string.notify_packs)) { Switch(notifyPacks, { notifyPacks = it; settings.notifyNewPacks = it }) } },
        ))
        RowList(listOf(
            { RowItem(stringResource(R.string.settings_pool), stringResource(R.string.settings_pool_short)) {
                Switch(pool, { pool = it; settings.sharePool = it })
            } },
            { RowItem(stringResource(R.string.settings_ask_game), stringResource(R.string.settings_ask_game_short)) {
                Switch(askGame, { askGame = it; settings.askGame = it })
            } },
            { RowItem(stringResource(R.string.profile_usage), stringResource(R.string.profile_usage_note)) {
                Switch(usage, { usage = it; Services.setUsageData(it) })
            } },
            { RowItem(stringResource(R.string.profile_privacy), onClick = { open(context, context.getString(R.string.url_privacy)) }) },
            { RowItem(stringResource(R.string.profile_help), onClick = { open(context, context.getString(R.string.url_help)) }) },
        ))
        Text(stringResource(R.string.profile_no_account), style = Tokens.Type.caption, color = Tokens.Color.secondary)
    }
}

/** Ayarlar (tuval Telefon-Ayarlar): motor ve anahtar, altyazı görünümü, paketler, hedef, PS5, hakkında. */
@Composable
fun SettingsScreen(onBack: () -> Unit, onPacks: () -> Unit, onTarget: () -> Unit, onPairing: () -> Unit, onTvInstall: () -> Unit = {}) {
    val context = LocalContext.current
    val settings = Services.settings
    var engine by remember { mutableStateOf(settings.engine) }
    // Anahtar kaydedilmeden önce denenir (iPhone gibi): yalnız kabul edilen anahtar gizli depoya yazılır.
    var key by remember(engine) { mutableStateOf("") }
    var saved by remember(engine) { mutableStateOf(!settings.apiKey(engine).isNullOrBlank()) }
    var checking by remember { mutableStateOf(false) }
    var keyRejected by remember(engine) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var scale by remember { mutableStateOf(settings.subtitleScale.toFloat()) }
    var color by remember { mutableStateOf(settings.textColor) }
    var background by remember { mutableStateOf(settings.tvBackground.toFloat()) }
    var shape by remember { mutableStateOf(settings.tvBackgroundShape) }
    var screenOn by remember { mutableStateOf(settings.keepScreenOn) }
    var stackPrevious by remember { mutableStateOf(settings.stackPrevious) }
    var passcode by remember { mutableStateOf(settings.loginPasscode ?: "") }
    // Tuvaldeki dört seçenek: Ücretsiz, DeepL, Gemini, Diğer (OpenAI / Claude).
    val segment = when (engine) {
        EngineChoice.FREE -> 0
        EngineChoice.DEEPL -> 1
        EngineChoice.GEMINI -> 2
        else -> 3
    }
    fun choose(choice: EngineChoice) {
        engine = choice
        settings.engine = choice
    }
    ScreenScaffold(top = { TopBar(stringResource(R.string.settings), onBack = onBack) }) {
        Tile(Modifier.fillMaxWidth()) {
            TileLabel(stringResource(R.string.settings_engine))
            Segmented(listOf(stringResource(R.string.engine_free_short), "DeepL", "Gemini", stringResource(R.string.engine_other)), segment) { index ->
                choose(when (index) {
                    0 -> EngineChoice.FREE
                    1 -> EngineChoice.DEEPL
                    2 -> EngineChoice.GEMINI
                    else -> if (engine == EngineChoice.CLAUDE) EngineChoice.CLAUDE else EngineChoice.OPENAI
                })
            }
            if (segment == 3) Segmented(listOf("OpenAI", "Claude"), if (engine == EngineChoice.CLAUDE) 1 else 0) {
                choose(if (it == 1) EngineChoice.CLAUDE else EngineChoice.OPENAI)
            }
            if (engine != EngineChoice.FREE) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TileLabel(stringResource(R.string.settings_key_for, engineName(context)))
                    Spacer(Modifier.weight(1f))
                    if (saved) StatusLabel(stringResource(R.string.settings_key_saved))
                }
                if (saved) {
                    GhostButton(stringResource(R.string.settings_key_remove)) {
                        settings.setApiKey(engine, null)
                        saved = false
                    }
                } else {
                    Field(key, { key = it; keyRejected = false }, stringResource(R.string.settings_key), secret = true)
                    SecondaryButton(stringResource(if (checking) R.string.settings_key_checking else R.string.settings_key_save),
                        enabled = !checking && key.isNotBlank()) {
                        val choice = engine
                        val typed = key.trim()
                        checking = true
                        keyRejected = false
                        scope.launch {
                            val state = withContext(Dispatchers.IO) {
                                val provider = choice.aiProvider
                                if (provider == null) KeyCheck.deepL(typed)
                                else {
                                    val models = AiModel.load(context)[provider.id].orEmpty()
                                    val model = models.firstOrNull { it.id == settings.aiModel } ?: models.firstOrNull()
                                    if (model == null) OnlineKeyState.UNREACHABLE else KeyCheck.ai(provider, typed, model)
                                }
                            }
                            checking = false
                            if (KeyCheck.accepted(state)) {
                                settings.setApiKey(choice, typed)
                                if (engine == choice) {
                                    saved = true
                                    key = ""
                                }
                            } else if (engine == choice) keyRejected = true
                        }
                    }
                    if (keyRejected) NoteTile(stringResource(R.string.settings_key_rejected))
                }
            }
            Text(stringResource(R.string.settings_engine_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        Tile(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TileLabel(stringResource(R.string.settings_text_size))
                Spacer(Modifier.weight(1f))
                Text("%${scale.toInt()}", style = Tokens.Type.headline, color = Tokens.Color.text)
            }
            Slider(scale, { scale = it; settings.subtitleScale = it.toInt() }, valueRange = 80f..160f, steps = 7,
                colors = SliderDefaults.colors(thumbColor = Tokens.Color.text, activeTrackColor = Tokens.Color.accent,
                    inactiveTrackColor = Tokens.Color.borderStrong, activeTickColor = Color.Transparent, inactiveTickColor = Color.Transparent))
            // Önizleme altyazı içeriğidir: boyu ölçeğe göre değişir.
            Text(stringResource(R.string.settings_preview), style = Tokens.Type.subtitleCurrent.copy(fontSize = Tokens.Type.subtitleCurrent.fontSize * (scale / 100f)),
                color = if (color == SubtitleTextColor.YELLOW) Tokens.Color.accentText else Tokens.Color.text)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                TileLabel(stringResource(R.string.settings_color))
                Spacer(Modifier.weight(1f))
                SubtitleTextColor.entries.forEach { option ->
                    val swatch = if (option == SubtitleTextColor.YELLOW) Tokens.Color.accent else Tokens.Color.text
                    Box(Modifier.size(32.dp).background(swatch, CircleShape)
                        .border(2.dp, if (color == option) Tokens.Color.accent else Tokens.Color.borderStrong, CircleShape)
                        .clickable { color = option; settings.textColor = option })
                }
            }
            // TV'deki kutu: %100 tamamen opak olur ve oyundaki İngilizce yazıyı kapatır; bant ekranın iki kenarına uzanır.
            Row(verticalAlignment = Alignment.CenterVertically) {
                TileLabel(stringResource(R.string.settings_background))
                Spacer(Modifier.weight(1f))
                Text("%${background.toInt()}", style = Tokens.Type.headline, color = Tokens.Color.text)
            }
            Slider(background, { background = it; settings.tvBackground = it.toInt() }, valueRange = 0f..100f, steps = 19,
                colors = SliderDefaults.colors(thumbColor = Tokens.Color.text, activeTrackColor = Tokens.Color.accent,
                    inactiveTrackColor = Tokens.Color.borderStrong, activeTickColor = Color.Transparent, inactiveTickColor = Color.Transparent))
            TileLabel(stringResource(R.string.settings_background_area))
            Segmented(listOf(stringResource(R.string.settings_background_fit), stringResource(R.string.settings_background_band)),
                if (shape == SubtitleBackgroundShape.BAND) 1 else 0) {
                shape = if (it == 1) SubtitleBackgroundShape.BAND else SubtitleBackgroundShape.FIT
                settings.tvBackgroundShape = shape
            }
            Text(stringResource(R.string.settings_background_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            RowItem(stringResource(R.string.settings_stack_previous)) { Switch(stackPrevious, { stackPrevious = it; settings.stackPrevious = it }) }
            Text(stringResource(R.string.settings_stack_previous_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            RowItem(stringResource(R.string.settings_screen_on)) { Switch(screenOn, { screenOn = it; settings.keepScreenOn = it }) }
        }
        // Altyazı alanı ve ek alanlar (iPhone ile aynı sırada: görünümden sonra).
        AreaTile()
        ExtraAreasTile()
        // İkinci hesabın PS5 giriş şifresi: yalnız 4 hane gizli depoya (Keystore) yazılır; silinince kaldırılır.
        Tile(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TileLabel(stringResource(R.string.settings_passcode))
                Spacer(Modifier.weight(1f))
                if (LoginPasscode.normalized(passcode) != null) StatusLabel(stringResource(R.string.settings_key_saved))
            }
            Field(passcode, { value ->
                passcode = value.filter { it in '0'..'9' }.take(LoginPasscode.LENGTH)
                settings.loginPasscode = passcode
            }, stringResource(R.string.settings_passcode_field), secret = true,
                keyboard = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
            Text(stringResource(R.string.settings_passcode_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        RowList(listOf(
            { RowItem(stringResource(R.string.settings_packs), onClick = onPacks) { Pill(stringResource(if (settings.packsEnabled) R.string.main_packs_on else R.string.main_packs_off)) } },
            { RowItem(stringResource(R.string.settings_target), if (settings.target == SubtitleTarget.TV) settings.tvName ?: stringResource(R.string.main_target_tv)
                else stringResource(R.string.main_target_phone), onClick = onTarget) },
            { RowItem(stringResource(R.string.settings_ps5), settings.console?.name ?: stringResource(R.string.profile_not_paired), onClick = onPairing) },
            { RowItem(stringResource(R.string.settings_about), BuildConfig.VERSION_NAME, onClick = { open(context, context.getString(R.string.url_source)) }) },
        ))
        // TV uygulamasını bu telefondan kurmak ve güncellemek (bilgisayardaki gibi; Samsung, LG, Android TV).
        Tile(Modifier.fillMaxWidth()) {
            TileLabel(stringResource(R.string.settings_tv_app))
            RowItem(stringResource(R.string.tvinstall_entry), tvAppSummary(), onClick = onTvInstall)
        }
        // Deneme altyazısı: TV'de (ya da telefon ekranında) yazının nasıl göründüğü; iPhone ile aynı.
        var testNote by remember { mutableStateOf<String?>(null) }
        SecondaryButton(stringResource(R.string.settings_test_subtitle)) {
            testNote = if (TranslationService.sendTestSubtitle(context.getString(R.string.test_subtitle_text))) null
                else context.getString(R.string.settings_test_needs_start)
        }
        testNote?.let { NoteTile(it, Tokens.Color.secondary) }
        Text(stringResource(R.string.settings_copyright), style = Tokens.Type.caption, color = Tokens.Color.secondary,
            modifier = Modifier.padding(top = Tokens.Space.inline))
    }
}

