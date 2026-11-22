// SPDX-License-Identifier: AGPL-3.0-only
// Profil (cihazlar ve tercihler; hesap yok) ve ayarlar (tuval: Telefon-Profil, -Ayarlar).
package com.couchsubs.mobile.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Slider
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.core.SubtitleBackgroundShape
import com.couchsubs.mobile.core.SubtitlePlacement
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.core.TvDisplayMode
import com.couchsubs.mobile.remoteplay.LoginPasscode
import com.couchsubs.mobile.service.TranslationService
import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.settings.EngineChoice
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.translation.AiModel
import com.couchsubs.mobile.translation.AiRequest
import com.couchsubs.mobile.translation.AiProvider
import com.couchsubs.mobile.translation.DeepLKey
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
    var speakerNames by remember { mutableStateOf(settings.showSpeakerNames) }
    var speakerColors by remember { mutableStateOf(settings.speakerColors) }
    var gameAreaPresets by remember { mutableStateOf(settings.gameAreaPresets) }
    var autoScreenText by remember { mutableStateOf(settings.autoScreenText) }
    var kindPhone by remember { mutableStateOf(settings.screenTextPhone) }
    var kindMission by remember { mutableStateOf(settings.screenTextMission) }
    var kindHelp by remember { mutableStateOf(settings.screenTextHelp) }
    var kindMenus by remember { mutableStateOf(settings.screenTextMenus) }
    var kindOther by remember { mutableStateOf(settings.screenTextOther) }
    var setTextApart by remember { mutableStateOf(settings.setTextApart) }
    var fastReading by remember { mutableStateOf(settings.fastSubtitleDetection) }
    var gamePhone by remember { mutableStateOf(settings.autoReadGamePhone) }
    var phoneChatCard by remember { mutableStateOf(settings.phoneChatCard) }
    var misreadWait by remember { mutableStateOf(settings.misreadWaitMs) }
    var partialWait by remember { mutableStateOf(settings.partialWaitMs) }
    var usage by remember { mutableStateOf(settings.usageData) }
    var backgroundPip by remember { mutableStateOf(settings.backgroundPip) }
    LaunchedEffect(Unit) { tvs = withContext(Dispatchers.IO) { runCatching { TvDiscovery.search() }.getOrDefault(emptyList()) } }
    ScreenScaffold(top = { TopBar(stringResource(R.string.profile), onBack = onBack) { SettingsAction(onSettings) } }) {
        TwoColumns(
            { StatusTile(CouchIcons.Gamepad, "PS5", settings.console?.name ?: stringResource(R.string.profile_not_paired), it,
                corner = { if (settings.console != null) StatusLabel(stringResource(R.string.main_paired)) }, chevron = true, onClick = onPairing) },
            { StatusTile(Icons.Filled.Person, stringResource(R.string.profile_psn),
                stringResource(if (settings.accountId != null) R.string.profile_psn_linked_short else R.string.profile_psn_missing), it,
                chevron = true, onClick = onPsn) },
        )
        Tile(Modifier.fillMaxWidth(), onClick = onTarget) {
            TileLabel(stringResource(R.string.profile_tvs))
            Text(targetName(settings), style = Tokens.Type.title, color = Tokens.Color.text)
            when (val found = tvs) {
                null -> Text(stringResource(R.string.target_searching), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                else -> Text(if (found.isEmpty()) stringResource(R.string.target_tvs_none) else found.joinToString { "${it.name} (${brandName(it.brand)})" },
                    style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
        }
        RowList(listOf(
            { RowItem(stringResource(R.string.notify_disconnect)) { Switch(notifyDisconnect, { notifyDisconnect = it; settings.notifyDisconnect = it }) } },
            // iPhone ile aynı ad ve açıklama (orada Resim içinde resim penceresi çeviriyi ayakta tutar).
            { RowItem(stringResource(R.string.settings_background_pip), stringResource(R.string.settings_background_pip_short)) {
                Switch(backgroundPip, { backgroundPip = it; settings.backgroundPip = it })
            } },
            { RowItem(stringResource(R.string.notify_packs)) { Switch(notifyPacks, { notifyPacks = it; settings.notifyNewPacks = it }) } },
        ))
        RowList(listOf(
            { RowItem(stringResource(R.string.settings_pool), stringResource(R.string.settings_pool_short)) {
                Switch(pool, { pool = it; settings.sharePool = it })
            } },
            { RowItem(stringResource(R.string.settings_ask_game), stringResource(R.string.settings_ask_game_short)) {
                Switch(askGame, { askGame = it; settings.askGame = it })
            } },
            { RowItem(stringResource(R.string.settings_speaker_names), stringResource(R.string.settings_speaker_names_short)) {
                Switch(speakerNames, { speakerNames = it; settings.showSpeakerNames = it })
            } },
            { RowItem(stringResource(R.string.settings_speaker_colors), stringResource(R.string.settings_speaker_colors_short)) {
                Switch(speakerColors, { speakerColors = it; settings.speakerColors = it; TranslationService.setSpeakerColors(it) })
            } },
            { RowItem(stringResource(R.string.settings_game_area_presets), stringResource(R.string.settings_game_area_presets_short)) {
                Switch(gameAreaPresets, { gameAreaPresets = it; settings.gameAreaPresets = it })
            } },
            { Column {
                RowItem(stringResource(R.string.settings_auto_screen_text), stringResource(R.string.settings_auto_screen_text_short)) {
                    Switch(autoScreenText, { autoScreenText = it; settings.autoScreenText = it })
                }
                // Türler yalnız ayar açıkken görünür; dört platformda aynı ad ve sıra (bkz. ScreenTextKind).
                if (autoScreenText) Column(Modifier.padding(start = 16.dp)) {
                    Text(stringResource(R.string.settings_screen_text_kinds), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                    RowItem(stringResource(R.string.settings_screen_text_phone)) {
                        Switch(kindPhone, { kindPhone = it; settings.screenTextPhone = it })
                    }
                    RowItem(stringResource(R.string.settings_screen_text_mission)) {
                        Switch(kindMission, { kindMission = it; settings.screenTextMission = it })
                    }
                    RowItem(stringResource(R.string.settings_screen_text_help)) {
                        Switch(kindHelp, { kindHelp = it; settings.screenTextHelp = it })
                    }
                    RowItem(stringResource(R.string.settings_screen_text_menus)) {
                        Switch(kindMenus, { kindMenus = it; settings.screenTextMenus = it })
                    }
                    RowItem(stringResource(R.string.settings_screen_text_other)) {
                        Switch(kindOther, { kindOther = it; settings.screenTextOther = it })
                    }
                    Text(stringResource(R.string.settings_screen_text_manual), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                }
            } },
            { RowItem(stringResource(R.string.settings_set_text_apart), stringResource(R.string.settings_set_text_apart_short)) {
                Switch(setTextApart, { setTextApart = it; settings.setTextApart = it; TranslationService.setTextApart(it) })
            } },
            { RowItem(stringResource(R.string.settings_fast_reading), stringResource(R.string.settings_fast_reading_short)) {
                Switch(fastReading, { fastReading = it; settings.fastSubtitleDetection = it })
            } },
            { RowItem(stringResource(R.string.settings_game_phone)) {
                Switch(gamePhone, { gamePhone = it; settings.autoReadGamePhone = it })
            } },
            // "Ekranı çevir"de telefon mesajları: kapalıyken her balonun üstünde, yerinde (Mac, iPhone, Windows ile aynı).
            { RowItem(stringResource(R.string.settings_phone_chat_card), stringResource(R.string.settings_phone_chat_card_short)) {
                Switch(phoneChatCard, { phoneChatCard = it; settings.phoneChatCard = it })
            } },
            // Windows, Mac ve iPhone'daki iki bekleme kaydırıcısı: aynı ad ve açıklama, 0–1 sn, 0,1 sn adım.
            { Column {
                WaitSlider(stringResource(R.string.settings_misread_wait), stringResource(R.string.settings_misread_wait_note), misreadWait) {
                    misreadWait = it; settings.misreadWaitMs = it
                }
                WaitSlider(stringResource(R.string.settings_partial_wait), stringResource(R.string.settings_partial_wait_note), partialWait) {
                    partialWait = it; settings.partialWaitMs = it
                }
                Text(stringResource(R.string.settings_waits_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                GhostButton(stringResource(R.string.settings_waits_defaults)) {
                    misreadWait = com.couchsubs.mobile.core.SubtitlePipeline.PACK_WAIT_MS
                    partialWait = com.couchsubs.mobile.core.SubtitlePipeline.CLEAN_WAIT_MS
                    settings.misreadWaitMs = misreadWait
                    settings.partialWaitMs = partialWait
                }
            } },
            { RowItem(stringResource(R.string.profile_usage), stringResource(R.string.profile_usage_note)) {
                Switch(usage, { usage = it; Services.setUsageData(it) })
            } },
            { RowItem(stringResource(R.string.profile_privacy), onClick = { open(context, context.getString(R.string.url_privacy)) }) },
            { RowItem(stringResource(R.string.profile_help), onClick = { open(context, context.getString(R.string.url_help)) }) },
        ))
        Text(stringResource(R.string.profile_no_account), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        DeveloperSignature()
    }
}

/** Ayarlar (tuval Telefon-Ayarlar): motor ve anahtar, altyazı görünümü, paketler, hedef, PS5, hakkında. */
@Composable
fun SettingsScreen(onBack: () -> Unit, onPacks: () -> Unit, onTarget: () -> Unit, onPairing: () -> Unit, onTvInstall: () -> Unit = {},
                   onPlatform: () -> Unit = {}, onDemo: () -> Unit = {}) {
    val context = LocalContext.current
    val settings = Services.settings
    var showAbout by remember { mutableStateOf(false) }
    var engine by remember { mutableStateOf(settings.engine) }
    // Anahtar kaydedilmeden önce denenir (iPhone gibi): yalnız kabul edilen anahtar gizli depoya yazılır.
    var key by remember(engine) { mutableStateOf("") }
    var saved by remember(engine) { mutableStateOf(!settings.apiKey(engine).isNullOrBlank()) }
    var checking by remember { mutableStateOf(false) }
    var keyRejected by remember(engine) { mutableStateOf(false) }
    var keyNotStored by remember(engine) { mutableStateOf(false) }
    // Reddedilen DeepL anahtarının nedeni (geçersiz karakter, HTTP kodu, ağ yok); Mac ve iPhone ile aynı metinler.
    var deepLRejection by remember(engine) { mutableStateOf<KeyCheck.DeepLUsage?>(null) }
    val scope = rememberCoroutineScope()
    var scale by remember { mutableStateOf(settings.subtitleScale.toFloat()) }
    var color by remember { mutableStateOf(settings.textColor) }
    var background by remember { mutableStateOf(settings.tvBackground.toFloat()) }
    var shape by remember { mutableStateOf(settings.tvBackgroundShape) }
    var screenOn by remember { mutableStateOf(settings.keepScreenOn) }
    var stackPrevious by remember { mutableStateOf(settings.stackPrevious) }
    var displayMode by remember { mutableStateOf(settings.tvDisplayMode) }
    var placement by remember { mutableStateOf(settings.tvPlacement) }
    var bottomPercent by remember { mutableStateOf(settings.tvBottomPercent.toFloat()) }
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
        // Erişim anahtarı yenilenince ikinci ekran adresi ve QR kodu da yenilenir.
        var keyVersion by remember { mutableStateOf(0) }
        SecondScreenTile(version = keyVersion)
        Tile(Modifier.fillMaxWidth()) {
            // "TV'yi eşle" (iPhone ile aynı): çeviri sürmese de iki dakika eşleşme açılır; TV kod gösterirse bu
            // telefonda açılan "Bu TV eşleşsin mi?" penceresinde onaylanır.
            var pairingOpened by remember { mutableStateOf(false) }
            SecondaryButton(stringResource(R.string.settings_pair_tv)) { pairingOpened = TranslationService.openPairing(context) }
            if (pairingOpened && com.couchsubs.mobile.service.LiveState.status.collectAsState().value.connectedTvs == 0)
                Text(stringResource(R.string.settings_pair_tv_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            // OBS katmanı adresi (Mac ve Windows'taki gibi adres görünür ve kopyalanır; telefonda ayrıca paylaşılır).
            var address by remember { mutableStateOf(TranslationService.viewerAddress()) }
            var addressCopied by remember { mutableStateOf(false) }
            LaunchedEffect(addressCopied) {
                if (addressCopied) {
                    kotlinx.coroutines.delay(1500)
                    addressCopied = false
                }
            }
            address?.let { shown ->
                TileLabel(stringResource(R.string.obs_overlay))
                androidx.compose.foundation.text.selection.SelectionContainer {
                    Text(shown, style = Tokens.Type.caption.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace), color = Tokens.Color.text)
                }
                Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(Tokens.Space.gap)) {
                    SecondaryButton(stringResource(if (addressCopied) R.string.history_copied else R.string.history_copy), Modifier.weight(1f)) {
                        context.getSystemService(android.content.ClipboardManager::class.java)?.setPrimaryClip(android.content.ClipData.newPlainText("CouchSubs", shown))
                        addressCopied = true
                    }
                    SecondaryButton(stringResource(R.string.share), Modifier.weight(1f)) {
                        val send = android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain")
                            .putExtra(android.content.Intent.EXTRA_TEXT, shown)
                        runCatching { context.startActivity(android.content.Intent.createChooser(send, null)) }
                    }
                }
            }
            androidx.compose.material3.TextButton(onClick = {
                TranslationService.renewAccessKey()
                address = TranslationService.viewerAddress()
                keyVersion++
            }){ Text(stringResource(R.string.tv_key_renew)) }
            if (com.couchsubs.mobile.service.LiveState.status.collectAsState().value.legacyTv) Text(stringResource(R.string.tv_legacy_warning))
            TileLabel(stringResource(R.string.settings_engine))
            Segmented(listOf(stringResource(R.string.engine_free_short), "DeepL", "Gemini", stringResource(R.string.engine_other)), segment) { index ->
                choose(when (index) {
                    0 -> EngineChoice.FREE
                    1 -> EngineChoice.DEEPL
                    2 -> EngineChoice.GEMINI
                    else -> if (engine == EngineChoice.CLAUDE || engine == EngineChoice.LOCAL) engine else EngineChoice.OPENAI
                })
            }
            // Diğer: OpenAI, Claude ya da yerel model (aynı ağdaki bilgisayarda Ollama / LM Studio; iPhone ile aynı).
            if (segment == 3) Segmented(listOf("OpenAI", "Claude", stringResource(R.string.engine_local)),
                when (engine) { EngineChoice.CLAUDE -> 1; EngineChoice.LOCAL -> 2; else -> 0 }) {
                choose(when (it) { 1 -> EngineChoice.CLAUDE; 2 -> EngineChoice.LOCAL; else -> EngineChoice.OPENAI })
            }
            // Model seçimi üç hizmette de var (Mac ve Windows ile aynı liste ve varsayılanlar); yerel modelde ad yazılır.
            engine.aiProvider?.takeIf { it != AiProvider.LOCAL }?.let { provider -> androidx.compose.runtime.key(provider) { AiModelChoice(settings, provider) } }
            if (engine == EngineChoice.LOCAL) LocalAiSection(settings)
            if (engine != EngineChoice.FREE && engine != EngineChoice.LOCAL) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TileLabel(stringResource(R.string.settings_key_for, engineName(context)))
                    Spacer(Modifier.weight(1f))
                    AnimatedVisibility(saved, enter = fadeIn(), exit = fadeOut()) { StatusLabel(stringResource(R.string.settings_key_saved)) }
                }
                if (saved) {
                    GhostButton(stringResource(R.string.settings_key_remove)) {
                        settings.setApiKey(engine, null)
                        saved = false
                    }
                    // Mac ve Windows'taki kullanım satırı (#625): kayıtlı DeepL anahtarının bu ayki karakter kullanımı.
                    if (engine == EngineChoice.DEEPL) DeepLUsageNote(settings)
                } else {
                    Field(key, { key = it; keyRejected = false; keyNotStored = false; deepLRejection = null }, stringResource(R.string.settings_key), secret = true)
                    SecondaryButton(stringResource(if (checking) R.string.settings_key_checking else R.string.settings_key_save),
                        enabled = !checking && key.isNotBlank()) {
                        val choice = engine
                        // DeepL anahtarındaki görünmez karakterler (araya giren boşluk, bölünmez boşluk…) her yerden silinir.
                        val typed = if (choice == EngineChoice.DEEPL) DeepLKey.clean(key) else key.trim()
                        checking = true
                        keyRejected = false
                        keyNotStored = false
                        deepLRejection = null
                        scope.launch {
                            val logName = choice.aiProvider?.id ?: "deepl"
                            Backend.breadcrumb("API anahtarı testi başladı: $logName")
                            var deepL: KeyCheck.DeepLUsage? = null
                            val state = withContext(Dispatchers.IO) {
                                val provider = choice.aiProvider
                                if (provider == null) KeyCheck.deepLUsage(typed).also { deepL = it }.state
                                else {
                                    val model = AiModel.selected(AiModel.load(context)[provider.id].orEmpty(), settings.aiModel(provider))
                                    if (model == null) OnlineKeyState.UNREACHABLE else KeyCheck.ai(provider, typed, model)
                                }
                            }
                            if (state != OnlineKeyState.VALID) Backend.breadcrumb("API anahtarı testi sonucu: $logName ${deepL?.logDescription ?: state}")
                            if (!KeyCheck.accepted(state)) deepLRejection = deepL
                            // Hizmet kabul etse de Keystore'a yazılamayan anahtar kayıtlı sayılmaz (Mac ile aynı).
                            val stored = KeyCheck.accepted(state) && withContext(Dispatchers.IO) { settings.storeApiKey(choice, typed) }
                            if (KeyCheck.accepted(state) && !stored) Backend.breadcrumb("API anahtarı gizli depoya kaydedilemedi: $logName")
                            checking = false
                            if (stored) {
                                if (engine == choice) {
                                    saved = true
                                    key = ""
                                }
                            } else if (engine == choice) {
                                if (KeyCheck.accepted(state)) keyNotStored = true else keyRejected = true
                            }
                        }
                    }
                    AnimatedNote(when {
                        keyNotStored -> stringResource(R.string.settings_key_not_stored)
                        keyRejected -> deepLRejection?.let { deepLUsageText(it) } ?: stringResource(R.string.settings_key_rejected)
                        else -> null
                    })
                }
            }
            // Ek talimat (#306) yalnız yapay zekâ motorlarında; DeepL'de yoktur (iPhone ile aynı).
            if (engine.aiProvider != null) AiInstructionField(settings)
            Text(stringResource(R.string.settings_engine_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        // Altyazı görünümü üç karoya bölünür (yazı, arka plan, TV'de); her karonun headline başlığı var.
        Tile(Modifier.fillMaxWidth()) {
            SectionTitle(stringResource(R.string.settings_text_size))
            SliderHeader(stringResource(R.string.settings_size), "%${Math.round(scale)}")
            // %10 adımlarla %40–160 (iPhone ile aynı): 13 değer, aradaki 11 durak.
            Slider(scale, { scale = it; settings.subtitleScale = Math.round(it) },
                valueRange = AppSettings.MIN_SUBTITLE_SCALE.toFloat()..AppSettings.MAX_SUBTITLE_SCALE.toFloat(),
                steps = (AppSettings.MAX_SUBTITLE_SCALE - AppSettings.MIN_SUBTITLE_SCALE) / 10 - 1, colors = couchSliderColors())
            // Önizleme altyazı içeriğidir: boyu ölçeğe göre değişir.
            Text(stringResource(R.string.settings_preview), style = Tokens.Type.subtitleCurrent.copy(fontSize = Tokens.Type.subtitleCurrent.fontSize * (scale / 100f)),
                color = if (color == SubtitleTextColor.YELLOW) Tokens.Color.accentText else Tokens.Color.text)
            Row(verticalAlignment = Alignment.CenterVertically) {
                TileLabel(stringResource(R.string.settings_color))
                Spacer(Modifier.weight(1f))
                Row(Modifier.selectableGroup()) {
                    SubtitleTextColor.entries.forEach { option ->
                        ColorSwatch(option, selected = color == option) {
                            color = option
                            settings.textColor = option
                        }
                    }
                }
            }
            RowItem(stringResource(R.string.settings_stack_previous)) { Switch(stackPrevious, { stackPrevious = it; settings.stackPrevious = it }) }
            Text(stringResource(R.string.settings_stack_previous_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        // TV'deki kutu: %100 tamamen opak olur ve oyundaki İngilizce yazıyı kapatır; bant ekranın iki kenarına uzanır.
        Tile(Modifier.fillMaxWidth()) {
            SectionTitle(stringResource(R.string.settings_section_background))
            SliderHeader(stringResource(R.string.settings_background), "%${background.toInt()}")
            Slider(background, { background = it; settings.tvBackground = it.toInt() }, valueRange = 0f..100f, steps = 19,
                colors = couchSliderColors())
            TileLabel(stringResource(R.string.settings_background_area))
            Segmented(listOf(stringResource(R.string.settings_background_fit), stringResource(R.string.settings_background_band)),
                if (shape == SubtitleBackgroundShape.BAND) 1 else 0) {
                shape = if (it == 1) SubtitleBackgroundShape.BAND else SubtitleBackgroundShape.FIT
                settings.tvBackgroundShape = shape
            }
            Text(stringResource(R.string.settings_background_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        // Yeri seçimi OBS katmanında da geçerlidir ("Yalnız OBS (yayın)"; iPhone ile aynı). Görüntü modu yalnız TV içindir.
        if (settings.target.showsOnTv || settings.target == SubtitleTarget.OBS) Tile(Modifier.fillMaxWidth()) {
            SectionTitle(stringResource(R.string.settings_section_tv))
            // TV'de çevirinin yeri (Mac ve Windows'taki Yeri seçimi, iPhone ile aynı): üstünde/altında seçilince oyundaki
            // İngilizce altyazı da görünür; sabit yerde yükseklik kaydırıcıyla ayarlanır, bırakınca TV'de örnek altyazı çıkar.
            val placements = listOf(SubtitlePlacement.COVER, SubtitlePlacement.ABOVE, SubtitlePlacement.BELOW, SubtitlePlacement.FIXED)
            TileLabel(stringResource(R.string.settings_placement))
            Segmented(listOf(stringResource(R.string.settings_placement_cover), stringResource(R.string.settings_placement_above),
                stringResource(R.string.settings_placement_below), stringResource(R.string.settings_placement_fixed)),
                placements.indexOf(placement).coerceAtLeast(0)) {
                placement = placements[it]
                settings.tvPlacement = placement
            }
            if (placement == SubtitlePlacement.FIXED) {
                SliderHeader(stringResource(R.string.settings_position_height), "%${bottomPercent.toInt()}")
                Slider(bottomPercent, { bottomPercent = it; settings.tvBottomPercent = it.toInt() }, valueRange = 0f..85f,
                    onValueChangeFinished = { TranslationService.testSubtitle(context, context.getString(R.string.test_subtitle_text)) },
                    colors = couchSliderColors())
                Text(stringResource(R.string.settings_placement_fixed_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            } else {
                Text(stringResource(R.string.settings_placement_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
            // Yalnız Android TV uygulaması kullanır: bazı TV'lerde (ör. TCL) uygulama içindeki PS5 görüntüsü siyah kalıyor.
            // Katman'da TV, PS5'i kendi HDMI girişinde gösterir (Mac ve Windows'taki Görüntü modu seçimi, iPhone ile aynı).
            if (settings.target.showsOnTv) {
                TileLabel(stringResource(R.string.settings_display_mode))
                Segmented(listOf(stringResource(R.string.settings_display_mode_in_app), stringResource(R.string.settings_display_mode_overlay)),
                    if (displayMode == TvDisplayMode.OVERLAY) 1 else 0) {
                    displayMode = if (it == 1) TvDisplayMode.OVERLAY else TvDisplayMode.IN_APP
                    settings.tvDisplayMode = displayMode
                }
                Text(stringResource(R.string.settings_display_mode_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
        }
        RowList(listOf({ RowItem(stringResource(R.string.settings_screen_on)) { Switch(screenOn, { screenOn = it; settings.keepScreenOn = it }) } }))
        // Telefon kilitlenince ne olduğu açıkça yazar; pil kısıtlaması açıksa ayara giden düğme de çıkar.
        Text(stringResource(R.string.settings_screen_on_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        BackgroundLimitNote()
        // Altyazı alanı ve ek alanlar (iPhone ile aynı sırada: görünümden sonra).
        DubbingTile()
        AreaProfileTile()
        GameProfilesTile()
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
        var xboxAudio by remember { mutableStateOf(settings.xboxAudioOnDevice) }
        RowList(listOfNotNull<@Composable () -> Unit>(
            { RowItem(stringResource(R.string.settings_packs), onClick = onPacks) { Pill(stringResource(if (settings.packsEnabled) R.string.main_packs_on else R.string.main_packs_off)) } },
            { RowItem(stringResource(R.string.settings_target), targetName(settings), onClick = onTarget) },
            { RowItem(stringResource(R.string.platform_setting), stringResource(if (settings.xbox) R.string.platform_xbox else R.string.platform_ps), onClick = onPlatform) {
                if (settings.xbox) Pill(stringResource(R.string.beta)) } },
            if (settings.xbox) ({ RowItem("Xbox", settings.xboxConsole?.name ?: stringResource(R.string.profile_not_paired), onClick = onPairing) })
            else ({ RowItem(stringResource(R.string.settings_ps5), settings.console?.name ?: stringResource(R.string.profile_not_paired), onClick = onPairing) }),
            // Yalnız Xbox: uzaktan oynatmada Xbox sesi istemciye verip TV'yi susturabilir (PS5'te ses TV'de kalır).
            if (settings.xbox) ({ RowItem(stringResource(R.string.settings_xbox_audio), stringResource(R.string.settings_xbox_audio_short)) {
                Switch(xboxAudio, { xboxAudio = it; settings.xboxAudioOnDevice = it })
            } }) else null,
            { RowItem(stringResource(R.string.settings_about), BuildConfig.VERSION_NAME, onClick = { showAbout = true }) },
        ))
        if (showAbout) AboutDialog { showAbout = false }
        XboxSignOutRow()
        PsnSignOutRow()
        // TV uygulamasını bu telefondan kurmak ve güncellemek (bilgisayardaki gibi; Samsung, LG, Android TV).
        Tile(Modifier.fillMaxWidth()) {
            TileLabel(stringResource(R.string.settings_tv_app))
            RowItem(stringResource(R.string.tvinstall_entry), tvAppSummary(), onClick = onTvInstall)
        }
        // Deneme modu: konsol olmadan örnek görüntülerle (iPhone ve Mac ile aynı; çeviri sürüyorsa önce durur).
        Tile(Modifier.fillMaxWidth()) {
            TileLabel(stringResource(R.string.demo_mode))
            Text(stringResource(R.string.demo_mode_body), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            // Deneme modu sürerken buradan da çıkılır (iPhone ile aynı).
            val live by com.couchsubs.mobile.service.LiveState.status.collectAsState()
            if (live.running && live.demo) SecondaryButton(stringResource(R.string.demo_mode_exit)) { TranslationService.stop(context) }
            else SecondaryButton(stringResource(R.string.demo_mode_try), onClick = onDemo)
        }
        // Deneme altyazısı: TV'de (ya da telefon ekranında) yazının nasıl göründüğü; iPhone ile aynı.
        var testNote by remember { mutableStateOf<String?>(null) }
        SecondaryButton(stringResource(R.string.settings_test_subtitle)) {
            // Çeviri sürmüyorsa bekleme sunucusu açılır, TV uygulaması bağlanınca altyazı gider (iPhone ile aynı).
            val waiting = TranslationService.connectedTvs() == 0
            testNote = if (!TranslationService.testSubtitle(context, context.getString(R.string.test_subtitle_text)))
                context.getString(R.string.settings_test_needs_start)
            // TV bağlı değilse yazı TV'ye gitmiyordu; TV'deki 6 haneli kodun nereye yazılacağı aranıyordu (kod yazılmaz,
            // bu telefonda açılan "Bu TV eşleşsin mi?" penceresinde onaylanır).
            else if (settings.target.showsOnTv && waiting)
                context.getString(R.string.settings_test_tv_not_connected)
            else null
        }
        AnimatedNote(testNote, Tokens.Color.secondary)
        Text(stringResource(R.string.settings_copyright), style = Tokens.Type.caption, color = Tokens.Color.secondary,
            modifier = Modifier.padding(top = Tokens.Space.inline))
        DeveloperSignature()
    }
}

/**
 * Yapay zekâ modeli: Gemini, OpenAI ve Claude (Mac ve Windows'taki Model seçimi, iPhone ile aynı). Seçenekler ortak
 * ai-models.json'dan gelir, ilki varsayılandır. Kayıt "geminiModel" / "openAIModel" / "claudeModel" adıyla tutulur;
 * Gemini'de dakikalık istek hakkı seçilen modelin sınırıdır.
 */
@Composable
private fun AiModelChoice(settings: AppSettings, provider: AiProvider) {
    val context = LocalContext.current
    val models = remember(provider) { AiModel.load(context)[provider.id].orEmpty() }
    if (models.isEmpty()) return
    var selected by remember(provider) { mutableStateOf(AiModel.selected(models, settings.aiModel(provider))!!.id) }
    TileLabel(stringResource(R.string.settings_model))
    Segmented(models.map { modelLabel(it) }, models.indexOfFirst { it.id == selected }.coerceAtLeast(0)) { index ->
        selected = models[index].id
        settings.setAiModel(provider, selected)
    }
    Text(selected, style = Tokens.Type.caption, color = Tokens.Color.secondary)
}

/**
 * Ek talimat (#306; iPhone, Mac ve Windows ile aynı): yapay zekâ çevirmeninin talimatının sonuna eklenir, boşsa hiçbir
 * şey değişmez. Yazıldıkça kaydedilir; çeviri sürerken de sonraki istekten itibaren yeni talimat kullanılır.
 */
@Composable
private fun AiInstructionField(settings: AppSettings) {
    var text by remember { mutableStateOf(settings.aiInstruction) }
    Field(text, { value ->
        text = value.take(AiRequest.MAX_INSTRUCTION_LENGTH)
        settings.aiInstruction = text
    }, stringResource(R.string.settings_instruction), lines = 3, placeholder = stringResource(R.string.settings_instruction_example))
    Text(stringResource(R.string.settings_instruction_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
}

/** Modelin kısa açıklaması; listedeki açıklama (label) tanınmazsa olduğu gibi gösterilir. */
@Composable
private fun modelLabel(model: AiModel): String = when (model.label) {
    "Fast and cheap (recommended)" -> stringResource(R.string.settings_model_fast)
    "Better quality, a little slower" -> stringResource(R.string.settings_model_quality)
    else -> model.label
}


/**
 * PSN'den çıkış (iPhone signOutPSN ile aynı): çeviri durur; ikinci hesabın kimliği, PS5 eşleşmesi (PS5 o hesaba bağlıdır)
 * ve giriş şifresi bu telefondan silinir. TV ve çeviri ayarları kalır. Yanlış hesapla giren kurulumu baştan almak zorundaydı.
 */
@Composable
private fun PsnSignOutRow() {
    val context = LocalContext.current
    val settings = Services.settings
    var linked by remember { mutableStateOf(settings.accountId != null || settings.console != null) }
    var confirm by remember { mutableStateOf(false) }
    if (settings.xbox || !linked) return
    Tile(Modifier.fillMaxWidth()) {
        RowItem(stringResource(R.string.psn_sign_out), onClick = { confirm = true })
    }
    if (confirm) androidx.compose.material3.AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text(stringResource(R.string.psn_sign_out_title)) },
        text = { Text(stringResource(R.string.psn_sign_out_body)) },
        confirmButton = {
            androidx.compose.material3.TextButton({
                confirm = false
                TranslationService.stop(context)
                settings.accountId = null
                settings.console = null
                settings.loginPasscode = null
                linked = false
            }) { Text(stringResource(R.string.psn_sign_out_confirm), color = Tokens.Color.danger) }
        },
        dismissButton = { androidx.compose.material3.TextButton({ confirm = false }) { Text(stringResource(R.string.cancel)) } },
        containerColor = Tokens.Color.surface2,
    )
}

/** Hakkında (iPhone AboutScreen ile aynı): sürüm, lisans, Remote Play teşekkürü ve kaynak kodu bağlantısı. */
@Composable
private fun AboutDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("CouchSubs ${BuildConfig.VERSION_NAME}") },
        text = {
            Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(Tokens.Space.inline)) {
                Text("Copyright © 2026 Sinan Yorulmaz", style = Tokens.Type.caption, color = Tokens.Color.secondary)
                Text(stringResource(R.string.about_body), style = Tokens.Type.body, color = Tokens.Color.secondary)
                // Uygulamanın günlükleri tek dosyada, kişisel veri maskelenmiş (iPhone'da da aynı; masaüstünde "Günlük
                // dosyasını göster").
                androidx.compose.material3.OutlinedButton({ shareLogs(context) }) { Text(stringResource(R.string.share_logs)) }
                Text(stringResource(R.string.share_logs_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
        },
        confirmButton = {
            androidx.compose.material3.TextButton({ open(context, context.getString(R.string.url_source)) }) { Text(stringResource(R.string.about_source)) }
        },
        dismissButton = { androidx.compose.material3.TextButton(onDismiss) { Text(stringResource(R.string.close)) } },
        containerColor = Tokens.Color.surface2,
    )
}

/** Xbox seçiliyken ve giriş yapılmışken Microsoft hesabından çıkış (jeton Keystore'dan silinir). */
@Composable
private fun XboxSignOutRow() {
    val settings = Services.settings
    var signedIn by remember { mutableStateOf(Services.xboxAuth.signedIn) }
    if (!settings.xbox || !signedIn) return
    Tile(Modifier.fillMaxWidth()) {
        RowItem(stringResource(R.string.xbox_sign_out), onClick = {
            Services.xboxAuth.signOut()
            signedIn = false
        })
    }
}

/**
 * Yazı rengi seçeneği: 32 dp renk dairesi, 48 dp dokunma alanı. Seçiliyken daireden 4 dp boşlukla ayrılan 2 dp sarı halka;
 * boşluk sayesinde sarı dairenin çevresinde de görünür. Ekran okuyucu rengin adını seçenek düğmesi olarak okur.
 */
@Composable
private fun ColorSwatch(option: SubtitleTextColor, selected: Boolean, onSelect: () -> Unit) {
    val yellow = option == SubtitleTextColor.YELLOW
    val name = stringResource(if (yellow) R.string.settings_color_yellow else R.string.settings_color_white)
    Box(
        Modifier.size(Tokens.Control.touch).clip(CircleShape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .semantics { contentDescription = name },
        contentAlignment = Alignment.Center,
    ) {
        if (selected) Box(Modifier.size(44.dp).border(2.dp, Tokens.Color.accent, CircleShape))
        Box(Modifier.size(32.dp).background(if (yellow) Tokens.Color.accent else Tokens.Color.text, CircleShape)
            .border(1.dp, Tokens.Color.borderStrong, CircleShape))
    }
}

/**
 * DeepL anahtarının bu ayki kullanımı: "Bu ay: 500.000 karakterin 12.345 kadarı kullanıldı." (Mac, Windows ve iPhone ile
 * aynı metin). Ayarlar açılınca ve anahtar kaydedilince sorulur; sorgu karakter kotasından yemez.
 */
@Composable
private fun DeepLUsageNote(settings: AppSettings) {
    var usage by remember { mutableStateOf<KeyCheck.DeepLUsage?>(null) }
    LaunchedEffect(Unit) {
        val key = settings.apiKey(EngineChoice.DEEPL)
        usage = if (key.isNullOrBlank()) null else withContext(Dispatchers.IO) { KeyCheck.deepLUsage(key) }
    }
    usage?.let { Text(deepLUsageText(it), style = Tokens.Type.caption, color = Tokens.Color.secondary) }
}

@Composable
private fun deepLUsageText(usage: KeyCheck.DeepLUsage): String = when {
    // Mac/iPhone'daki DeepLUsageText ve Windows'taki ShowDeepLStatus ile aynı metinler.
    usage.state == OnlineKeyState.VALID && usage.limit >= KeyCheck.UNLIMITED ->
        stringResource(R.string.deepl_usage_unlimited, "%,d".format(usage.used))
    usage.state == OnlineKeyState.VALID && usage.limit <= 0 -> stringResource(R.string.deepl_usage_unknown)
    usage.state == OnlineKeyState.VALID -> stringResource(R.string.deepl_usage, "%,d".format(usage.used), "%,d".format(usage.limit))
    usage.state == OnlineKeyState.QUOTA_EXCEEDED -> stringResource(R.string.deepl_quota_used_up)
    usage.state == OnlineKeyState.INVALID && usage.reason == KeyCheck.Reason.MALFORMED_KEY -> stringResource(R.string.deepl_key_malformed)
    usage.state == OnlineKeyState.INVALID -> stringResource(R.string.deepl_key_not_accepted)
    usage.state == OnlineKeyState.BUSY -> stringResource(R.string.deepl_rate_limited)
    usage.reason == KeyCheck.Reason.HTTP_STATUS -> stringResource(R.string.deepl_server_error, usage.code)
    else -> stringResource(R.string.deepl_unreachable)
}

/** Altyazı hedefinin adı: TV'nin adı, "Bu telefon" ya da ikisi birden (iPhone ile aynı). */
/** Bekleme süresi kaydırıcısı: 0–1 sn, 0,1 sn adım; değer milisaniye olarak verilir. */
@Composable
private fun WaitSlider(title: String, note: String, ms: Int, onChange: (Int) -> Unit) {
    val max = com.couchsubs.mobile.core.SubtitlePipeline.WAIT_SLIDER_MAX_MS
    val seconds = ms.coerceIn(0, max) / 1000f
    Column {
        SliderHeader(title, "${String.format(java.util.Locale.getDefault(), "%.1f", seconds)} ${stringResource(R.string.unit_seconds)}")
        Slider(seconds, { onChange(Math.round(it * 10) * 100) }, valueRange = 0f..max / 1000f, steps = max / 100 - 1,
            colors = couchSliderColors())
        Text(note, style = Tokens.Type.caption, color = Tokens.Color.secondary)
    }
}

@Composable
fun targetName(settings: AppSettings): String {
    val tv = settings.tvName ?: stringResource(R.string.main_target_tv)
    return when (settings.target) {
        SubtitleTarget.TV -> tv
        SubtitleTarget.PHONE -> stringResource(R.string.main_target_phone)
        SubtitleTarget.BOTH -> stringResource(R.string.main_target_both, tv)
        SubtitleTarget.OBS -> stringResource(R.string.target_obs)
    }
}
