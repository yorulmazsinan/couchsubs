// SPDX-License-Identifier: AGPL-3.0-only
// Ayarlar'ın bölüm sayfaları: Mac'in yeni arayüzündeki bölümler (Temel, Altyazı Görünümü, Gelişmiş, Altyazı Alanı, Oyun
// Paketleri, Türkçe Dublaj, Çıkış Ekranları, Konsol ve Kaynak) aynı ad, seçenek, varsayılan ve sırayla (iPhone ile aynı;
// Klavye Kısayolları telefonda yok). Kurulumdaki TV girişi (HDMI) adımı da burada.
package com.couchsubs.mobile.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.core.NameColorMode
import com.couchsubs.mobile.core.OverlayCover
import com.couchsubs.mobile.core.SpeakerColors
import com.couchsubs.mobile.core.SubtitleBackgroundShape
import com.couchsubs.mobile.core.SubtitlePalette
import com.couchsubs.mobile.core.SubtitlePipeline
import com.couchsubs.mobile.core.SubtitlePlacement
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.core.TranslationPace
import com.couchsubs.mobile.core.TvDisplayMode
import com.couchsubs.mobile.remoteplay.ConsoleIpEntry
import com.couchsubs.mobile.remoteplay.LoginPasscode
import com.couchsubs.mobile.service.LiveState
import com.couchsubs.mobile.service.TranslationService
import com.couchsubs.mobile.settings.AppAppearance
import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.settings.EngineChoice
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.translation.AiModel
import com.couchsubs.mobile.translation.AiProvider
import com.couchsubs.mobile.translation.DeepLKey
import com.couchsubs.mobile.translation.KeyCheck
import com.couchsubs.mobile.translation.OnlineKeyState
import com.couchsubs.mobile.translation.aiProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Ayarlar'ın bölümleri (Mac SettingsSection ile aynı sıra, ad ve iki kelimelik alt yazı). */
enum class SettingsSection(val title: Int, val hint: Int) {
    BASICS(R.string.set_basics, R.string.set_basics_hint),
    APPEARANCE(R.string.set_appearance, R.string.set_appearance_hint),
    ADVANCED(R.string.set_advanced, R.string.set_advanced_hint),
    AREA(R.string.set_area, R.string.set_area_hint),
    PACKS(R.string.set_packs, R.string.set_packs_hint),
    DUBBING(R.string.set_dubbing, R.string.set_dubbing_hint),
    OUTPUTS(R.string.set_outputs, R.string.set_outputs_hint),
    CONSOLE(R.string.set_console, R.string.set_console_hint),
}

/** Bir bölümün sayfası: başlıkta bölümün adı, geri bölüm listesine döner. */
@Composable
fun SettingsPage(
    section: SettingsSection, onBack: () -> Unit, onOpen: (SettingsSection) -> Unit, onPacks: () -> Unit, onTarget: () -> Unit,
    onPairing: () -> Unit, onTvInstall: () -> Unit, onPlatform: () -> Unit, onDemo: () -> Unit,
) {
    ScreenScaffold(top = { TopBar(stringResource(section.title), onBack = onBack) }) {
        when (section) {
            SettingsSection.BASICS -> BasicsPage { onOpen(SettingsSection.APPEARANCE) }
            SettingsSection.APPEARANCE -> AppearancePage()
            SettingsSection.ADVANCED -> AdvancedPage()
            SettingsSection.AREA -> AreaPage()
            SettingsSection.PACKS -> PacksPage(onPacks)
            SettingsSection.DUBBING -> DubbingTile()
            SettingsSection.OUTPUTS -> OutputsPage(onTarget, onTvInstall)
            SettingsSection.CONSOLE -> ConsolePage(onPairing, onPlatform, onDemo)
        }
    }
}


/** Ayar birimi: başlık, altında denetim, en altta isteğe bağlı açıklama (Mac DSUnit gibi). */
@Composable
private fun SettingUnit(title: String?, note: String? = null, control: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
        title?.let { Text(it, style = Tokens.Type.headline, color = Tokens.Color.text) }
        control()
        note?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
    }
}

// MARK: Temel

@Composable
private fun BasicsPage(onEditAppearance: () -> Unit) {
    val settings = Services.settings
    var misread by remember { mutableStateOf(settings.misreadWaitMs) }
    var partial by remember { mutableStateOf(settings.partialWaitMs) }
    var startupSound by remember { mutableStateOf(settings.startupSound) }
    var transitions by remember { mutableStateOf(settings.transitionAnimations) }
    var appearance by remember { mutableStateOf(settings.appearance) }
    Tile(Modifier.fillMaxWidth()) {
        SectionTitle(stringResource(R.string.set_translation))
        val pace = TranslationPace.of(misread, partial)
        SettingUnit(stringResource(R.string.set_speed), stringResource(when (pace) {
            TranslationPace.FAST -> R.string.set_speed_fast_note
            TranslationPace.BALANCED -> R.string.set_speed_balanced_note
            TranslationPace.ACCURATE -> R.string.set_speed_accurate_note
            null -> R.string.settings_waits_note
        })) {
            val paces = TranslationPace.entries
            Segmented(listOf(stringResource(R.string.set_speed_fast), stringResource(R.string.set_speed_balanced), stringResource(R.string.set_speed_accurate)),
                pace?.let { paces.indexOf(it) } ?: -1) { index ->
                val chosen = paces[index]
                misread = chosen.misreadMs; partial = chosen.partialMs
                settings.misreadWaitMs = chosen.misreadMs; settings.partialWaitMs = chosen.partialMs
            }
        }
        // Bilgi (denetim değil): başlık üstte, değer altında, açıklama en altta.
        SettingUnit(stringResource(R.string.set_translation_language), stringResource(R.string.set_translation_language_note)) {
            Text(java.util.Locale.forLanguageTag(settings.targetLanguage).let { it.getDisplayLanguage(java.util.Locale.getDefault()) }
                .replaceFirstChar { it.titlecase(java.util.Locale.getDefault()) }, style = Tokens.Type.body, color = Tokens.Color.text)
        }
    }
    Tile(Modifier.fillMaxWidth()) {
        SectionTitle(stringResource(R.string.set_sound))
        SwitchRow(stringResource(R.string.set_startup_sound), stringResource(R.string.set_startup_sound_note), startupSound) {
            startupSound = it; settings.startupSound = it
        }
        SwitchRow(stringResource(R.string.set_transitions), stringResource(R.string.set_transitions_note), transitions) {
            transitions = it; settings.transitionAnimations = it; Tokens.transitionAnimations = it
        }
        SettingUnit(stringResource(R.string.set_look)) {
            val options = listOf(AppAppearance.LIGHT, AppAppearance.DARK, AppAppearance.SYSTEM)
            Segmented(listOf(stringResource(R.string.set_look_light), stringResource(R.string.set_look_dark), stringResource(R.string.set_look_system)),
                options.indexOf(appearance)) { index ->
                appearance = options[index]; settings.appearance = appearance; Tokens.appearance = appearance
            }
        }
    }
    Tile(Modifier.fillMaxWidth()) {
        SectionTitle(stringResource(R.string.settings_text_size))
        SubtitlePreview(lines = 1)
        Text(stringResource(R.string.set_look_card_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        SecondaryButton(stringResource(R.string.set_edit_look), onClick = onEditAppearance)
    }
}

// MARK: Altyazı Görünümü

/** Önizlemedeki örnek satırlar (Mac SubtitleSample ile aynı). */
private val sampleLines = listOf("Jason" to "Tamam. Gidelim.", "Lucia" to "Yakınımda kal. Bunu birlikte yapacağız.", "Cal" to "Bir sürü silah sesi duyuyorum!")

private fun color(hex: String?): Color? = SubtitlePalette.rgb(hex)?.let { Color(it.first.toFloat(), it.second.toFloat(), it.third.toFloat()) }

/** Görünüm sayfasının durumu: her değişiklik kaydedilir ve TV'ye gider (style olayı; ayar dinleyicisi gönderir). */
private class LookState(val settings: AppSettings) {
    var version by mutableStateOf(0)
    fun change(action: AppSettings.() -> Unit) {
        settings.action()
        // Konuşan rengi yalnız adı boyar (yeni arayüz; Mac ve iPhone ile aynı).
        settings.nameOnly = true
        version++
    }
}

/** TV önizlemesi: oyun sahnesi üstünde altyazı kutuları, ayarların renk ve boyuyla (Mac SubtitlePreviewBox gibi). */
@Composable
private fun SubtitlePreview(lines: Int, version: Int = 0) {
    val settings = Services.settings
    val style = remember(version) { settings.style }
    val showNames = remember(version) { settings.showSpeakerNames }
    val speakerColors = remember(version) { settings.speakerColors }
    val display = SubtitlePalette.display(style.fontSize)
    val text = color(SubtitlePalette.textHex(style)) ?: Color.White
    val plate = color(style.backgroundColor) ?: Color.Black
    // Perde önizlemesi: sıcak oyun sahnesi, 16:9, 20 köşe, ekran çerçevesi (tasarim.json screenFrame).
    val shape = RoundedCornerShape(Tokens.Radius.preview)
    Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(shape).border(4.dp, Tokens.Color.screenFrame, shape)) {
    PerdeScene()
    Column(
        Modifier.fillMaxSize().padding(Tokens.Space.gap),
        verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair, Alignment.Bottom), horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val shown = sampleLines.take(lines)
        shown.forEachIndexed { index, (who, line) ->
            // Zemin TV'deki gibi (OverlayCover.boxOpacity; Mac ve iPhone önizlemesi aynı): "Örtsün"de en alttaki (en yeni)
            // satır her koyulukta tam opak, önceki satırlar koyuluğun %83'ü. Eskiden hepsi koyulukla çiziliyordu.
            val background = plate.copy(alpha = OverlayCover.boxOpacity(style.background, style.placement == SubtitlePlacement.COVER,
                current = index == shown.size - 1).toFloat())
            val name = when {
                !speakerColors || style.nameColorMode == NameColorMode.TEXT -> text
                style.nameColorMode == NameColorMode.SINGLE -> color(style.nameHex ?: SubtitlePalette.names[0].hex) ?: text
                else -> color(style.characterColors[who.lowercase()] ?: SubtitlePalette.names[(index + 1) % SubtitlePalette.names.size].hex) ?: text
            }
            Text(buildAnnotatedString {
                if (showNames) withStyle(SpanStyle(color = name)) { append("$who: ") }
                withStyle(SpanStyle(color = if (speakerColors && style.nameColorMode == NameColorMode.LINE) name else text)) { append(line) }
            }, style = Tokens.Type.body.copy(fontSize = (display * 0.5f).sp, lineHeight = (display * 0.62f).sp,
                fontWeight = if (style.bold) FontWeight.Bold else FontWeight.SemiBold,
                shadow = if (style.background == 0) Shadow(Color.Black.copy(alpha = 0.85f), blurRadius = 3f) else null),
                textAlign = TextAlign.Center,
                modifier = Modifier.background(background, RoundedCornerShape(4.dp)).padding(horizontal = Tokens.Space.inline, vertical = Tokens.Space.hair))
        }
    }
    }
}

/** Renk yuvarlakları: seçiliyken sarı halka; "Zeminsiz" çizgili. Ekran okuyucu rengin adını okur. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SwatchRow(swatches: List<SubtitlePalette.Swatch>, selected: String?, size: Int = 32, pick: (SubtitlePalette.Swatch) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.hair), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
        swatches.forEach { swatch ->
            val on = swatch.hex == selected
            val label = swatchName(swatch.name)
            Box(Modifier.size(Tokens.Control.touch).clip(CircleShape)
                .selectable(selected = on, role = Role.RadioButton) { pick(swatch) }
                .semantics { contentDescription = label },
                contentAlignment = Alignment.Center) {
                if (on) Box(Modifier.size((size + 10).dp).border(2.dp, Tokens.Color.accent, CircleShape))
                val fill = color(swatch.hex)
                Box(Modifier.size(size.dp).clip(CircleShape).background(fill ?: Tokens.Color.surface2)
                    .border(1.dp, Tokens.Color.borderStrong, CircleShape), contentAlignment = Alignment.Center) {
                    if (fill == null) Box(Modifier.size(width = (size * 1.2).dp, height = 2.dp).background(Tokens.Color.danger))
                }
            }
        }
    }
}

/** Renk adının ekrandaki karşılığı (Mac kataloğundaki İngilizce adlar). */
@Composable
private fun swatchName(name: String): String = stringResource(when (name) {
    "Black" -> R.string.set_color_black
    "Navy" -> R.string.set_color_navy
    "Dark Gray" -> R.string.set_color_dark_gray
    "Brown" -> R.string.set_color_brown
    "White" -> R.string.settings_color_white
    "Cream" -> R.string.set_color_cream
    "No Background" -> R.string.set_color_no_background
    "Yellow" -> R.string.settings_color_yellow
    "Light Blue" -> R.string.set_color_light_blue
    "Amber" -> R.string.set_color_amber
    "Turquoise" -> R.string.set_color_turquoise
    "Pink" -> R.string.set_color_pink
    "Purple" -> R.string.set_color_purple
    "Green" -> R.string.set_color_green
    "Orange" -> R.string.set_color_orange
    "Red" -> R.string.set_color_red
    else -> R.string.set_color_blue
})

@Composable
private fun AppearancePage() {
    val context = LocalContext.current
    val settings = Services.settings
    val look = remember { LookState(settings) }
    val version = look.version
    val style = remember(version) { settings.style }
    fun test() { TranslationService.testSubtitle(context, context.getString(R.string.test_subtitle_text)) }
    Tile(Modifier.fillMaxWidth()) {
        SectionTitle(stringResource(R.string.set_tv_preview))
        SubtitlePreview(lines = 3, version = version)
        AnimatedVisibility(SubtitlePalette.lowContrast(style), enter = fadeIn(), exit = fadeOut()) {
            Text(stringResource(R.string.set_low_contrast), style = Tokens.Type.caption, color = Tokens.Color.danger)
        }
        Text(stringResource(R.string.set_applies_everywhere), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        SecondaryButton(stringResource(R.string.set_send_test)) { test() }
    }
    Tile(Modifier.fillMaxWidth()) {
        // Yazı Boyutu: 16–50 px (TV'deki boy SubtitlePalette ile eşlenir); sürüklerken TV'de deneme altyazısı.
        var size by remember { mutableStateOf(SubtitlePalette.display(settings.fontSize).toFloat()) }
        // Çubuk kartın iç genişliğini tam kaplar; 16 ve 50 çubuğun uçlarıyla hizalı.
        SliderRow(stringResource(R.string.set_text_size), stringResource(R.string.set_px, size.toInt()), size, { value ->
            size = value
            look.change { fontSize = SubtitlePalette.fontSize(value.toInt()) }
        }, valueRange = 16f..50f, steps = 33, ends = "16" to "50", onValueChangeFinished = { test() })
        // Zemin Rengi: zeminsiz seçilince koyuluk 0; renk seçilince zemin yoksa Orta.
        val backgroundSelected = if (style.background == 0) null else style.backgroundColor
        val backgroundSwatch = SubtitlePalette.backgrounds.firstOrNull { it.hex == backgroundSelected }
        SettingUnit(stringResource(R.string.set_background_color), backgroundSwatch?.let { stringResource(R.string.set_selected, swatchName(it.name)) }) {
            SwatchRow(SubtitlePalette.backgrounds, backgroundSelected) { swatch ->
                look.change {
                    val hex = swatch.hex
                    if (hex != null) {
                        backgroundColor = hex
                        if (tvBackground == 0) tvBackground = SubtitlePalette.darkness[1]
                    } else tvBackground = 0
                }
                test()
            }
        }
        // "Örtsün"de en yeni satır her koyulukta tam opak; ayar bunu söylemeyince "koyuluk ayarlanamıyor" sanılıyordu
        // (X ve Google Play, beta.107). Mac ve iPhone aynı not.
        val darknessNote = if (OverlayCover.darknessFixedByCover(style.placement, style.background)) stringResource(R.string.set_darkness_cover_note) else null
        SettingUnit(stringResource(R.string.set_darkness), darknessNote) {
            val level = SubtitlePalette.darknessLevel(style.background)
            Segmented(listOf(stringResource(R.string.set_look_light), stringResource(R.string.set_darkness_medium), stringResource(R.string.set_look_dark)),
                level?.let { SubtitlePalette.darkness.indexOf(it) } ?: -1) { index ->
                if (style.background == 0) return@Segmented
                look.change { tvBackground = SubtitlePalette.darkness[index] }
                test()
            }
        }
        val textSelected = SubtitlePalette.textHex(style)
        val textSwatch = SubtitlePalette.texts.firstOrNull { it.hex == textSelected }
        SettingUnit(stringResource(R.string.set_text_color), textSwatch?.let { stringResource(R.string.set_selected, swatchName(it.name)) }) {
            SwatchRow(SubtitlePalette.texts, textSelected) { swatch ->
                look.change {
                    textHex = swatch.hex
                    textColor = if (swatch.hex == "#FFE066") SubtitleTextColor.YELLOW else SubtitleTextColor.WHITE
                }
                test()
            }
        }
        // Karakter Adı: Yazıyla Aynı (konuşan rengi kapalı), Tek Renk ya da Karaktere Göre (Mac ve iPhone ile aynı).
        val mode = if (!settings.speakerColors) NameColorMode.TEXT else if (style.nameColorMode == NameColorMode.TEXT) NameColorMode.SPEAKER else style.nameColorMode
        SettingUnit(stringResource(R.string.set_character_name), if (mode == NameColorMode.TEXT) stringResource(R.string.set_name_same_note) else null) {
            val modes = listOf(NameColorMode.TEXT, NameColorMode.SINGLE, NameColorMode.SPEAKER, NameColorMode.LINE)
            Segmented(listOf(stringResource(R.string.set_name_same), stringResource(R.string.set_name_single), stringResource(R.string.set_name_speaker),
                stringResource(R.string.set_name_line)),
                modes.indexOf(mode)) { index ->
                val chosen = modes[index]
                look.change {
                    nameColorMode = chosen
                    speakerColors = chosen != NameColorMode.TEXT
                }
                TranslationService.setSpeakerColors(chosen != NameColorMode.TEXT)
                test()
            }
            when (mode) {
                NameColorMode.TEXT -> {}
                NameColorMode.SINGLE -> SwatchRow(SubtitlePalette.names, style.nameHex ?: SubtitlePalette.names[0].hex) { swatch ->
                    look.change { nameHex = swatch.hex }
                    test()
                }
                NameColorMode.SPEAKER, NameColorMode.LINE -> CharacterColors(style.characterColors) { key, hex ->
                    look.change { characterColors = characterColors + (key to hex) }
                    test()
                }
            }
        }
        var names by remember { mutableStateOf(settings.showSpeakerNames) }
        SwitchRow(stringResource(R.string.set_show_speaker_name), checked = names) { names = it; look.change { showSpeakerNames = it } }
    }
}

/** "Karaktere Göre": bu oturumda görülen (ve rengi seçilmiş) karakterler, en çok 12; her birinin rengi seçilir. */
@Composable
private fun CharacterColors(chosen: Map<String, String>, pick: (String, String) -> Unit) {
    val known = SpeakerColors.session.known
    val keys = (known.map { it.first } + chosen.keys.sorted()).distinct().take(12)
    keys.forEach { key ->
        val current = chosen[key] ?: known.firstOrNull { it.first == key }?.second
        Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
            Text(key.replaceFirstChar { it.titlecase(java.util.Locale.getDefault()) }, style = Tokens.Type.headline,
                color = color(current) ?: Tokens.Color.text)
            SwatchRow(SubtitlePalette.names, current?.uppercase(), size = 24) { swatch -> swatch.hex?.let { pick(key, it) } }
        }
    }
    Text(stringResource(if (keys.isEmpty()) R.string.set_characters_empty else R.string.set_characters_more),
        style = Tokens.Type.caption, color = Tokens.Color.secondary)
}

// MARK: Gelişmiş

@Composable
private fun AdvancedPage() {
    val settings = Services.settings
    EngineTile(settings)
    var autoScreenText by remember { mutableStateOf(settings.autoScreenText) }
    var kindMission by remember { mutableStateOf(settings.screenTextMission) }
    var kindHelp by remember { mutableStateOf(settings.screenTextHelp) }
    var kindMenus by remember { mutableStateOf(settings.screenTextMenus) }
    var kindOther by remember { mutableStateOf(settings.screenTextOther) }
    var kindBeside by remember { mutableStateOf(settings.screenTextBeside) }
    var gamePhone by remember { mutableStateOf(settings.readsGamePhone) }
    var setTextApart by remember { mutableStateOf(settings.setTextApart) }
    var fastReading by remember { mutableStateOf(settings.fastSubtitleDetection) }
    var misreadWait by remember { mutableStateOf(settings.misreadWaitMs) }
    var partialWait by remember { mutableStateOf(settings.partialWaitMs) }
    // Ekran yazıları ve altyazı okuma: dört platformda aynı başlık, aynı ad ve sıra (Mac, Windows, iPhone).
    Tile(Modifier.fillMaxWidth(), style = TileStyle.NORMAL) {
        SectionTitle(stringResource(R.string.set_screen_text))
        SwitchRow(stringResource(R.string.set_auto_screen), stringResource(R.string.set_auto_screen_note), autoScreenText) {
            autoScreenText = it; settings.autoScreenText = it
        }
        // Türler yalnız ayar açıkken görünür; dört platformda aynı ad ve sıra (bkz. ScreenTextKind). Telefon türü ayrı satır
        // değil: tek "GTA 6 Telefonunu Çevir" anahtarı onu da yazar (AppSettings.setGamePhone).
        if (autoScreenText) Column(Modifier.padding(start = 16.dp)) {
            Text(stringResource(R.string.settings_screen_text_kinds), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            SwitchRow(stringResource(R.string.settings_screen_text_mission), checked = kindMission) { kindMission = it; settings.screenTextMission = it }
            SwitchRow(stringResource(R.string.settings_screen_text_help), checked = kindHelp) { kindHelp = it; settings.screenTextHelp = it }
            SwitchRow(stringResource(R.string.settings_screen_text_menus), checked = kindMenus) { kindMenus = it; settings.screenTextMenus = it }
            SwitchRow(stringResource(R.string.settings_screen_text_beside), checked = kindBeside) { kindBeside = it; settings.screenTextBeside = it }
            SwitchRow(stringResource(R.string.settings_screen_text_other), checked = kindOther) { kindOther = it; settings.screenTextOther = it }
            Text(stringResource(R.string.settings_screen_text_manual), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        SwitchRow(stringResource(R.string.set_auto_phone), stringResource(R.string.set_auto_phone_note), gamePhone) {
            gamePhone = it; settings.setGamePhone(it)
        }
        SwitchRow(stringResource(R.string.set_apart), stringResource(R.string.settings_set_text_apart_short), setTextApart) {
            setTextApart = it; settings.setTextApart = it; TranslationService.setTextApart(it)
        }
        // Varsayılana Dön: bu karttaki ayarlar (Mac, Windows, iPhone ile aynı küme).
        SecondaryButton(stringResource(R.string.set_restore)) {
            autoScreenText = false; gamePhone = true; setTextApart = true
            kindMission = true; kindHelp = true; kindMenus = false; kindOther = false; kindBeside = false
            settings.autoScreenText = false; settings.setGamePhone(true); settings.setTextApart = true
            settings.screenTextMission = true; settings.screenTextHelp = true
            settings.screenTextMenus = false; settings.screenTextOther = false; settings.screenTextBeside = false
            TranslationService.setTextApart(true)
        }
    }
    Tile(Modifier.fillMaxWidth(), style = TileStyle.NORMAL) {
        SectionTitle(stringResource(R.string.set_reading))
        SwitchRow(stringResource(R.string.set_fast_check), stringResource(R.string.settings_fast_reading_short), fastReading) {
            fastReading = it; settings.fastSubtitleDetection = it
        }
        WaitSlider(stringResource(R.string.set_misread), stringResource(R.string.set_misread_note), misreadWait) { misreadWait = it; settings.misreadWaitMs = it }
        WaitSlider(stringResource(R.string.set_partial), stringResource(R.string.set_partial_note), partialWait) { partialWait = it; settings.partialWaitMs = it }
        SecondaryButton(stringResource(R.string.set_restore)) {
            fastReading = false; misreadWait = SubtitlePipeline.PACK_WAIT_MS; partialWait = SubtitlePipeline.CLEAN_WAIT_MS
            settings.fastSubtitleDetection = false; settings.misreadWaitMs = misreadWait; settings.partialWaitMs = partialWait
        }
    }
}

/** Çeviri motoru: Ücretsiz, DeepL, Gemini, Diğer (OpenAI / Claude / yerel model); anahtar denenip kaydedilir (iPhone ile aynı). */
@Composable
private fun EngineTile(settings: AppSettings) {
    val context = LocalContext.current
    var engine by remember { mutableStateOf(settings.engine) }
    // Anahtar kaydedilmeden önce denenir (iPhone gibi): yalnız kabul edilen anahtar gizli depoya yazılır.
    var key by remember(engine) { mutableStateOf("") }
    var saved by remember(engine) { mutableStateOf(!settings.apiKey(engine).isNullOrBlank()) }
    var checking by remember { mutableStateOf(false) }
    var keyRejected by remember(engine) { mutableStateOf(false) }
    var keyNotStored by remember(engine) { mutableStateOf(false) }
    // Reddedilen DeepL anahtarının nedeni (geçersiz karakter, HTTP kodu, ağ yok); Mac ve iPhone ile aynı metinler.
    var deepLRejection by remember(engine) { mutableStateOf<KeyCheck.DeepLUsage?>(null) }
    // Reddedilen yapay zekâ anahtarının nedeni (anahtar geçersiz ya da hizmete ulaşılamadı); Mac, Windows ve iPhone ile aynı metinler.
    var aiRejection by remember(engine) { mutableStateOf<OnlineKeyState?>(null) }
    var paidTier by remember { mutableStateOf(settings.geminiPaidTier) }
    val scope = rememberCoroutineScope()
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
    Tile(Modifier.fillMaxWidth()) {
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
        // Ücretsiz çeviri zayıf kalıyor; ücretsiz Gemini anahtarı en kolay iyileştirme (Mac ve iPhone ile aynı öneri).
        if (engine == EngineChoice.FREE) {
            Text(stringResource(R.string.set_free_gemini), style = Tokens.Type.body, color = Tokens.Color.text)
            SecondaryButton(stringResource(R.string.set_free_gemini_button)) {
                choose(EngineChoice.GEMINI)
                open(context, context.getString(R.string.url_gemini_key))
            }
        }
        // Çevrimiçi motorlar yalnız İngilizce oyunları çevirir (Mac ve iPhone ile aynı uyarı).
        if (engine != EngineChoice.FREE && settings.sourceLanguage != "en")
            Text(stringResource(R.string.set_language_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
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
                Field(key, { key = it; keyRejected = false; keyNotStored = false; deepLRejection = null; aiRejection = null }, stringResource(R.string.settings_key), secret = true)
                SecondaryButton(stringResource(if (checking) R.string.settings_key_checking else R.string.settings_key_save),
                    enabled = !checking && key.isNotBlank()) {
                    val choice = engine
                    // Anahtardaki görünmez karakterler (araya giren boşluk, satır sonu, bölünmez boşluk…) her yerden silinir.
                    val typed = DeepLKey.clean(key)
                    checking = true
                    keyRejected = false
                    keyNotStored = false
                    deepLRejection = null
                    aiRejection = null
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
                        if (!KeyCheck.accepted(state)) {
                            deepLRejection = deepL
                            if (choice.aiProvider != null) aiRejection = state
                        }
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
                    keyRejected -> deepLRejection?.let { deepLUsageText(it) }
                        ?: aiRejection?.let(::onlineIssueReason)?.let { stringResource(it, engineName(context)) }
                        ?: stringResource(R.string.settings_key_rejected)
                    else -> null
                })
            }
        }
        // Ek talimat (#306) yalnız yapay zekâ motorlarında; DeepL'de yoktur (iPhone ile aynı).
        if (engine.aiProvider != null) AiInstructionField(settings)
        // Ücretli Gemini anahtarı: ücretsiz katmanın dakikalık sınırı uygulanmaz (Mac ve iPhone ile aynı).
        if (engine == EngineChoice.GEMINI) SwitchRow(stringResource(R.string.set_gemini_paid), stringResource(R.string.set_gemini_paid_note), paidTier) {
            paidTier = it; settings.geminiPaidTier = it
        }
        Text(stringResource(R.string.settings_engine_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
    }
}

// MARK: Altyazı Alanı

@Composable
private fun AreaPage() {
    val settings = Services.settings
    var phoneMessagesPanel by remember { mutableStateOf(settings.phoneMessagesPanel) }
    var gameAreaPresets by remember { mutableStateOf(settings.gameAreaPresets) }
    var resets by remember { mutableStateOf(0) }
    androidx.compose.runtime.key(resets) { AreaTile() }
    // Alanları Sıfırla: altyazı alanı Alt hazır seçimine döner (Mac ile aynı).
    SecondaryButton(stringResource(R.string.set_reset_areas)) {
        settings.selectAreaPreset(com.couchsubs.mobile.core.AreaPreset.BOTTOM)
        resets++
    }
    // GTA 6 telefon mesajları (otomatik okuma ve "Ekranı çevir"): Yanda Panel (varsayılan) ya da Balonların Üstünde.
    Tile(Modifier.fillMaxWidth()) {
        TileLabel(stringResource(R.string.settings_phone_messages))
        Segmented(listOf(stringResource(R.string.settings_phone_messages_panel), stringResource(R.string.settings_phone_messages_bubbles)),
            if (phoneMessagesPanel) 0 else 1) { index ->
            phoneMessagesPanel = index == 0
            settings.phoneMessagesPanel = index == 0
        }
        Text(stringResource(R.string.settings_phone_messages_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
    }
    ExtraAreasTile()
    AreaProfileTile()
    GameProfilesTile()
    RowList(listOf {
        SwitchRow(stringResource(R.string.settings_game_area_presets), stringResource(R.string.settings_game_area_presets_short), gameAreaPresets) {
            gameAreaPresets = it; settings.gameAreaPresets = it
        }
    })
}

// MARK: Oyun Paketleri

@Composable
private fun PacksPage(onPacks: () -> Unit) {
    val settings = Services.settings
    var packs by remember { mutableStateOf(settings.packsEnabled) }
    var pool by remember { mutableStateOf(settings.sharePool) }
    var usage by remember { mutableStateOf(settings.usageData) }
    var askGame by remember { mutableStateOf(settings.askGame) }
    RowList(listOf(
        { SwitchRow(stringResource(R.string.set_use_packs), stringResource(R.string.set_use_packs_note), packs) { packs = it; settings.packsEnabled = it } },
        { SwitchRow(stringResource(R.string.set_pool), stringResource(R.string.set_pool_note), pool) { pool = it; settings.sharePool = it } },
        { SwitchRow(stringResource(R.string.set_usage), stringResource(R.string.profile_usage_note), usage) { usage = it; Services.setUsageData(it) } },
        { SwitchRow(stringResource(R.string.set_ask_game), stringResource(R.string.settings_ask_game_short), askGame) { askGame = it; settings.askGame = it } },
    ))
    // Kurulu paketler, güncelleme ve içe aktarma (paketler ekranı).
    RowList(listOf { RowItem(stringResource(R.string.settings_packs), onClick = onPacks) })
}

// MARK: Çıkış Ekranları

@Composable
private fun OutputsPage(onTarget: () -> Unit, onTvInstall: () -> Unit) {
    val context = LocalContext.current
    val settings = Services.settings
    var target by remember { mutableStateOf(settings.target) }
    val live by LiveState.status.collectAsState()
    Tile(Modifier.fillMaxWidth()) {
        SectionTitle(stringResource(R.string.set_show_on))
        val targets = listOf(SubtitleTarget.TV, SubtitleTarget.PHONE, SubtitleTarget.BOTH, SubtitleTarget.OBS)
        SettingUnit(null, stringResource(when (target) {
            SubtitleTarget.TV -> R.string.set_out_tv_note
            SubtitleTarget.PHONE -> R.string.set_out_phone_note
            SubtitleTarget.BOTH -> R.string.set_out_both_note
            SubtitleTarget.OBS -> R.string.set_out_obs_note
        })) {
            Segmented(listOf(stringResource(R.string.set_out_tv), stringResource(R.string.set_out_phone), stringResource(R.string.set_out_both),
                stringResource(R.string.set_out_obs)), targets.indexOf(target)) { index ->
                target = targets[index]; settings.target = target
            }
        }
        if (target.showsOnTv) {
            // TV satırı: ad, TV uygulamasının durumu, "Eşli" rozeti; Deneme Altyazısı Gönder ve TV'yi Eşleştir / TV Bağla.
            // Kayıt değişince (TV yeni adreste bulundu, IP girildi, eşleşme kaldırıldı) kart yeniden okunur.
            var tvRevision by remember { mutableStateOf(0) }
            val pairedTv = remember(tvRevision) { settings.installedTv }
            val pairedName = remember(tvRevision) { settings.tvName }
            val hasTv = pairedTv != null || pairedName != null
            val waitingText = pairedTvWaitingText()
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                TileIcon(CouchIcons.Tv)
                Column(Modifier.weight(1f)) {
                    Text(pairedName ?: "TV", style = Tokens.Type.headline, color = Tokens.Color.text)
                    pairedTv?.let { Text(pairedTvDetail(it), style = Tokens.Type.caption, color = Tokens.Color.tertiary) }
                    val version = pairedTv?.version?.takeIf { it.isNotEmpty() }
                    Text(when {
                        !hasTv -> stringResource(R.string.set_not_set_up)
                        live.connectedTvs > 0 && version != null -> stringResource(R.string.set_tv_app_connected, version)
                        live.connectedTvs > 0 -> stringResource(R.string.set_connected)
                        else -> waitingText
                    }, style = Tokens.Type.caption, color = Tokens.Color.secondary)
                }
                if (hasTv) StatusLabel(stringResource(R.string.set_linked), ok = live.connectedTvs > 0)
            }
            var sent by remember { mutableStateOf(false) }
            var testNote by remember { mutableStateOf<String?>(null) }
            var pairingOpened by remember { mutableStateOf(false) }
            var openingApp by remember { mutableStateOf(false) }
            var openFailed by remember { mutableStateOf(false) }
            var justConnected by remember { mutableStateOf(false) }
            // "TV'yi Eşleştir" / "Deneme Altyazısı Gönder" eşli TV'ye ulaşamadı: kart açık hata gösterir.
            var unreachableHost by remember { mutableStateOf<String?>(null) }
            val cardScope = rememberCoroutineScope()
            // Eylemden önce eşli TV yoklanır; ulaşılamazsa hata gösterilir, eylem yapılmaz (TV yeni adreste bulunursa sürer).
            fun whenReachable(action: () -> Unit) {
                if (pairedTv == null) { action(); return }
                cardScope.launch {
                    unreachableHost = unreachablePairedTv(context)
                    tvRevision++
                    if (unreachableHost == null) action()
                }
            }
            LaunchedEffect(sent) { if (sent) { kotlinx.coroutines.delay(1500); sent = false } }
            Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                if (sent) Box(Modifier.weight(1f).heightIn(min = Tokens.Control.button), contentAlignment = Alignment.Center) {
                    StatusLabel(stringResource(R.string.set_sent))
                } else SecondaryButton(stringResource(R.string.set_send_test), Modifier.weight(1f)) { whenReachable {
                    // Çeviri sürmüyorsa bekleme sunucusu açılır, TV uygulaması bağlanınca altyazı gider (iPhone ile aynı).
                    val waiting = TranslationService.connectedTvs() == 0
                    testNote = if (!TranslationService.testSubtitle(context, context.getString(R.string.test_subtitle_text)))
                        context.getString(R.string.settings_test_needs_start)
                    // TV'deki 6 haneli kod bir yere yazılmaz; bu telefonda açılan "Bu TV eşleşsin mi?" penceresinde onaylanır.
                    else if (waiting) context.getString(R.string.settings_test_tv_not_connected)
                    else null
                    sent = testNote == null
                } }
                // TV yoksa "TV'yi Bağla", eşli ama TV uygulaması bağlı değilse "TV'de CouchSubs'ı Aç" (eşleşme onayı açılır,
                // bağlanana dek düğme yükleniyor), bağlıyken eşleştirme düğmesi yok (önceden eşli ve bağlı TV'de de "TV'yi
                // Eşleştir" duruyordu; Mac, Windows ve iPhone ile aynı).
                if (!hasTv) SecondaryButton(stringResource(R.string.set_pair_the_tv), Modifier.weight(1f), onClick = onTarget)
                else if (live.connectedTvs == 0) SecondaryButton(
                    stringResource(if (openingApp) R.string.set_opening_on_tv else R.string.set_open_on_tv), Modifier.weight(1f),
                    enabled = !openingApp, busy = openingApp,
                ) { whenReachable {
                    openFailed = false
                    pairingOpened = TranslationService.openPairing(context)
                    openingApp = pairingOpened
                    if (!pairingOpened) openFailed = true
                } }
            }
            // Açma beklenirken TV bağlanırsa "Bağlandı" kısa süre görünür; süre dolarsa açık hata.
            LaunchedEffect(openingApp, live.connectedTvs) {
                if (!openingApp) return@LaunchedEffect
                if (live.connectedTvs > 0) {
                    openingApp = false
                    justConnected = true
                    kotlinx.coroutines.delay(4000)
                    justConnected = false
                    return@LaunchedEffect
                }
                kotlinx.coroutines.delay(30_000)
                openingApp = false
                openFailed = true
            }
            if (openingApp) Text(stringResource(R.string.set_pairing_waiting), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            if (justConnected) StatusLabel(stringResource(R.string.set_connected))
            AnimatedNote(if (openFailed && live.connectedTvs == 0) stringResource(R.string.set_tv_open_failed) else null)
            PairedTvActions(pairedTv, connected = live.connectedTvs > 0, unreachableHost = unreachableHost,
                onChanged = { unreachableHost = null; tvRevision++ }, onChangeTv = onTarget)
            AnimatedNote(testNote, Tokens.Color.secondary)
            if (pairingOpened && live.connectedTvs == 0)
                Text(stringResource(R.string.settings_pair_tv_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            if (settings.tvPlacement == SubtitlePlacement.FIXED)
                Text(stringResource(R.string.settings_placement_fixed_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        if (target == SubtitleTarget.OBS) ObsAddress()
    }
    if (target.showsOnTv || target == SubtitleTarget.OBS) PlacementTile(target)
    if (target.showsOnPhone) {
        // Bu telefonda: ekran açık kalsın (telefon kilitlenince ne olduğu açıkça yazar).
        var screenOn by remember { mutableStateOf(settings.keepScreenOn) }
        Tile(Modifier.fillMaxWidth()) {
            SwitchRow(stringResource(R.string.settings_screen_on), stringResource(R.string.settings_screen_on_note), screenOn) {
                screenOn = it; settings.keepScreenOn = it
            }
        }
        BackgroundLimitNote()
    }
    // Altyazı hedefi (TV arama, eşleme, OBS; iPhone'daki Çıkış Ekranları › Altyazı hedefi satırı).
    RowList(listOf { RowItem(stringResource(R.string.settings_target), onClick = onTarget) })
    if (target.showsOnTv) Tile(Modifier.fillMaxWidth()) {
        TileLabel(stringResource(R.string.settings_tv_app))
        RowItem(stringResource(R.string.tvinstall_entry), tvAppSummary(), onClick = onTvInstall)
    }
    if (target != SubtitleTarget.OBS) Tile(Modifier.fillMaxWidth()) { ObsAddress() }
    SecondScreenTile()
}

/** OBS katmanı adresi (Mac ve Windows'taki gibi adres görünür ve kopyalanır; telefonda ayrıca paylaşılır) ve erişim anahtarı. */
@Composable
private fun ObsAddress() {
    val context = LocalContext.current
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
        Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
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
    }) { Text(stringResource(R.string.tv_key_renew)) }
    if (LiveState.status.collectAsState().value.legacyTv) Text(stringResource(R.string.tv_legacy_warning))
}

/** Yer ve biçim (Mac AppearanceCard): Yeri, sabit yükseklik, zemin alanı, kalın yazı, önceki satırlar, görüntü modu. */
@Composable
private fun PlacementTile(target: SubtitleTarget) {
    val context = LocalContext.current
    val settings = Services.settings
    var placement by remember { mutableStateOf(settings.tvPlacement) }
    var bottomPercent by remember { mutableStateOf(settings.tvBottomPercent.toFloat()) }
    var shape by remember { mutableStateOf(settings.tvBackgroundShape) }
    var bold by remember { mutableStateOf(settings.bold) }
    var stackPrevious by remember { mutableStateOf(settings.stackPrevious) }
    var displayMode by remember { mutableStateOf(settings.tvDisplayMode) }
    Tile(Modifier.fillMaxWidth()) {
        // TV'de çevirinin yeri: üstünde/altında seçilince oyundaki İngilizce altyazı da görünür; sabit yerde yükseklik
        // kaydırıcıyla ayarlanır, bırakınca TV'de örnek altyazı çıkar.
        val placements = listOf(SubtitlePlacement.COVER, SubtitlePlacement.ABOVE, SubtitlePlacement.BELOW, SubtitlePlacement.FIXED)
        TileLabel(stringResource(R.string.settings_placement))
        Segmented(listOf(stringResource(R.string.settings_placement_cover), stringResource(R.string.settings_placement_above),
            stringResource(R.string.settings_placement_below), stringResource(R.string.settings_placement_fixed)),
            placements.indexOf(placement).coerceAtLeast(0)) {
            placement = placements[it]
            settings.tvPlacement = placement
        }
        if (placement == SubtitlePlacement.FIXED) {
            SliderRow(stringResource(R.string.settings_position_height), "%${bottomPercent.toInt()}", bottomPercent,
                { bottomPercent = it; settings.tvBottomPercent = it.toInt() }, valueRange = 0f..85f,
                note = stringResource(R.string.settings_placement_fixed_note),
                onValueChangeFinished = { TranslationService.testSubtitle(context, context.getString(R.string.test_subtitle_text)) })
        } else {
            Text(stringResource(R.string.settings_placement_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        TileLabel(stringResource(R.string.settings_background_area))
        Segmented(listOf(stringResource(R.string.settings_background_fit), stringResource(R.string.settings_background_band)),
            if (shape == SubtitleBackgroundShape.BAND) 1 else 0) {
            shape = if (it == 1) SubtitleBackgroundShape.BAND else SubtitleBackgroundShape.FIT
            settings.tvBackgroundShape = shape
        }
        Text(stringResource(R.string.settings_background_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        SwitchRow(stringResource(R.string.set_bold), checked = bold) { bold = it; settings.bold = it }
        SwitchRow(stringResource(R.string.settings_stack_previous), stringResource(R.string.settings_stack_previous_note), stackPrevious) {
            stackPrevious = it; settings.stackPrevious = it
        }
        // Yalnız Android TV uygulaması kullanır: bazı TV'lerde (ör. TCL) uygulama içindeki PS5 görüntüsü siyah kalıyor.
        if (target.showsOnTv) {
            TileLabel(stringResource(R.string.settings_display_mode))
            Segmented(listOf(stringResource(R.string.settings_display_mode_auto), stringResource(R.string.settings_display_mode_in_app),
                stringResource(R.string.settings_display_mode_overlay)), displayMode.ordinal) {
                displayMode = TvDisplayMode.entries[it]
                settings.tvDisplayMode = displayMode
            }
            Text(stringResource(R.string.settings_display_mode_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
    }
}

// MARK: Konsol ve Kaynak

@Composable
private fun ConsolePage(onPairing: () -> Unit, onPlatform: () -> Unit, onDemo: () -> Unit) {
    val context = LocalContext.current
    val settings = Services.settings
    var xboxAudio by remember { mutableStateOf(settings.xboxAudioOnDevice) }
    RowList(listOfNotNull<@Composable () -> Unit>(
        { RowItem(stringResource(R.string.platform_setting), stringResource(if (settings.xbox) R.string.platform_xbox else R.string.platform_ps), onClick = onPlatform) {
            if (settings.xbox) Pill(stringResource(R.string.beta)) } },
        if (settings.xbox) ({ RowItem("Xbox", settings.xboxConsole?.name ?: stringResource(R.string.profile_not_paired), onClick = onPairing) })
        else ({ RowItem(stringResource(R.string.settings_ps5), settings.console?.name ?: stringResource(R.string.profile_not_paired), onClick = onPairing) }),
        // Yalnız Xbox: uzaktan oynatmada Xbox sesi istemciye verip TV'yi susturabilir (PS5'te ses TV'de kalır).
        if (settings.xbox) ({ Box(Modifier.padding(vertical = Tokens.Space.gap)) {
            SwitchRow(stringResource(R.string.settings_xbox_audio), stringResource(R.string.settings_xbox_audio_short), xboxAudio) {
                xboxAudio = it; settings.xboxAudioOnDevice = it
            }
        } }) else null,
    ))
    XboxSignOutRow()
    PsnSignOutRow()
    // "IP Adresi Gir": PS5'in ağdaki adresi değişince (modem yeni adres verdi) kayıtlı PS5 yazılan adrese taşınır; çeviri
    // sürüyorsa yeni adresle yeniden bağlanılır. Eskiden elle adres yalnız ilk kurulumda giriliyordu (Mac, iPhone, Windows ile aynı).
    val savedConsole = settings.console
    if (!settings.xbox && savedConsole != null) {
        var host by remember { mutableStateOf(savedConsole.host) }
        var entering by remember { mutableStateOf(false) }
        var typed by remember { mutableStateOf("") }
        var invalid by remember { mutableStateOf(false) }
        Tile(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TileLabel(stringResource(R.string.settings_ps5))
                Spacer(Modifier.weight(1f))
                Text(host, style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
            SecondaryButton(stringResource(R.string.tv_enter_ip)) { entering = !entering; invalid = false }
            if (entering) {
                Field(typed, { typed = it; invalid = false }, stringResource(R.string.tv_enter_ip),
                    keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri), placeholder = stringResource(R.string.target_ip_hint))
                if (invalid) Text(stringResource(R.string.address_invalid), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                PrimaryButton(stringResource(R.string.save), enabled = typed.isNotBlank()) {
                    val current = settings.console
                    val moved = current?.let { ConsoleIpEntry.apply(it, typed) }
                    if (moved == null) { invalid = true; return@PrimaryButton }
                    settings.console = moved
                    host = moved.host
                    typed = ""
                    entering = false
                    TranslationService.reconnect()
                }
            }
        }
    }
    // İkinci hesabın PS5 giriş şifresi: yalnız 4 hane gizli depoya (Keystore) yazılır; silinince kaldırılır.
    if (!settings.xbox) {
        var passcode by remember { mutableStateOf(settings.loginPasscode ?: "") }
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
    }
    // Kurulumda seçilen TV girişi; değişince TV uygulaması o girişi açar (style.hdmiInput; Mac ile aynı koşul).
    if (settings.asksTvInput) Tile(Modifier.fillMaxWidth()) {
        SectionTitle(stringResource(R.string.set_hdmi))
        var hdmi by remember { mutableStateOf(settings.hdmiInput) }
        Segmented((1..4).map { stringResource(R.string.set_hdmi_n, it) }, (hdmi ?: 0) - 1) { index ->
            hdmi = index + 1
            settings.hdmiInput = hdmi
            TranslationService.testSubtitle(context, context.getString(R.string.test_subtitle_text))
        }
    }
    Tile(Modifier.fillMaxWidth()) {
        SectionTitle(stringResource(R.string.set_language))
        var language by remember { mutableStateOf(settings.sourceLanguage) }
        val languages = AppSettings.GAME_LANGUAGES
        SettingUnit(stringResource(R.string.set_game_language)) {
            Segmented(languages.map { code -> stringResource(when (code) {
                "ja" -> R.string.set_lang_ja
                "de" -> R.string.set_lang_de
                "fr" -> R.string.set_lang_fr
                "es" -> R.string.set_lang_es
                else -> R.string.set_lang_en
            }) }, languages.indexOf(language)) { index ->
                language = languages[index]; settings.sourceLanguage = language
            }
        }
        Text(stringResource(R.string.set_language_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
    }
    // Deneme modu: konsol olmadan örnek görüntülerle (iPhone ve Mac ile aynı; çeviri sürüyorsa önce durur).
    Tile(Modifier.fillMaxWidth()) {
        TileLabel(stringResource(R.string.demo_mode))
        Text(stringResource(R.string.demo_mode_body), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        val live by LiveState.status.collectAsState()
        if (live.running && live.demo) SecondaryButton(stringResource(R.string.demo_mode_exit)) { TranslationService.stop(context) }
        else SecondaryButton(stringResource(R.string.demo_mode_try), onClick = onDemo)
    }
}

// MARK: Kurulum › TV girişi (HDMI)

/**
 * Kurulumun TV girişi adımı (Mac HDMIStep, iPhone ile aynı): dört giriş; seçim TV uygulamasına gider (style.hdmiInput, TV
 * o girişi açar). "Bilmiyorum, Sırayla Dene" girişleri sırayla açar, görüntü görülünce onaylanır.
 */
@Composable
fun HdmiInputScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val settings = Services.settings
    var selected by remember { mutableStateOf(settings.hdmiInput) }
    var trying by remember { mutableStateOf(false) }
    var confirmed by remember { mutableStateOf(false) }
    fun choose(port: Int, auto: Boolean) {
        trying = auto
        confirmed = false
        selected = port
        settings.hdmiInput = port
        TranslationService.testSubtitle(context, context.getString(R.string.test_subtitle_text))
    }
    ScreenScaffold(top = { TopBar() }, bottom = {
        PrimaryButton(stringResource(R.string.next_continue), onClick = onDone)
    }) {
        Heading(stringResource(R.string.hdmi_title), stringResource(R.string.hdmi_body),
            stringResource(R.string.setup_step, 3) + " · " + stringResource(R.string.hdmi_step))
        Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
            (1..4).forEach { port ->
                Tile(Modifier.weight(1f), style = if (selected == port && !trying) TileStyle.ACTIVE else TileStyle.NORMAL,
                    onClick = { choose(port, auto = false) }) {
                    Text("HDMI", style = Tokens.Type.caption, color = Tokens.Color.secondary, modifier = Modifier.align(Alignment.CenterHorizontally))
                    Text("$port", style = Tokens.Type.title, color = Tokens.Color.text, modifier = Modifier.align(Alignment.CenterHorizontally))
                }
            }
        }
        Tile(Modifier.fillMaxWidth(), style = if (trying) TileStyle.ACTIVE else TileStyle.NORMAL,
            onClick = { choose(selected?.let { it % 4 + 1 } ?: 1, auto = true) }) {
            Text(stringResource(R.string.hdmi_auto), style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(R.string.hdmi_auto_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        Tile(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.hdmi_how), style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(R.string.hdmi_how_body), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        Tile(Modifier.fillMaxWidth()) {
            selected?.let { port ->
                Pill(if (trying) stringResource(R.string.hdmi_trying, port) else stringResource(R.string.set_hdmi_n, port))
            }
            Text(stringResource(R.string.hdmi_question), style = Tokens.Type.headline, color = Tokens.Color.text)
            if (confirmed) StatusLabel(stringResource(R.string.hdmi_confirmed))
            else {
                SecondaryButton(stringResource(R.string.hdmi_yes), enabled = selected != null) { confirmed = true; trying = false }
                SecondaryButton(stringResource(R.string.hdmi_next)) { choose((selected ?: 0) % 4 + 1, auto = trying) }
            }
            selected?.let { Text(stringResource(R.string.hdmi_saved, it), style = Tokens.Type.caption, color = Tokens.Color.secondary) }
            Text(stringResource(R.string.hdmi_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
    }
}
