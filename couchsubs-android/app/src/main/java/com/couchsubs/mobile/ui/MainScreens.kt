// SPDX-License-Identifier: AGPL-3.0-only
// Ana ekran (tuval: Telefon-Ana, -Calisiyor, -Tur) ve oyun paketleri (-Paketler). Uygulama ve paketler ücretsiz.
package com.couchsubs.mobile.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalView
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.core.GameCatalog
import com.couchsubs.mobile.packs.PackUpdateOutcome
import com.couchsubs.mobile.packs.PackUpdateSummary
import com.couchsubs.mobile.service.FramePreview
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.settings.SubtitleTarget
import com.couchsubs.mobile.tv.InstalledTv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Turda vurgulanan öğeler (TASARIM-MOBIL.md §10, tuval Telefon-Tur); [radius] öğenin köşesi (delik ona göre çizilir). */
private enum class TourStep(val title: Int, val body: Int, val radius: Dp) {
    START(R.string.tour1_title, R.string.tour1_body, Tokens.Radius.control),
    TARGET(R.string.tour2_title, R.string.tour2_body, Tokens.Radius.tile),
    PACKS(R.string.tour3_title, R.string.tour3_body, Tokens.Radius.tile),
    PROFILE(R.string.tour4_title, R.string.tour4_body, Tokens.Radius.control),
}

/** Tanıtım popup'ı açıkken ana ekranın bulanıklığı. */
private val PROMO_BLUR = 16.dp

/** Boşta ↔ çeviri ekranı geçişinin süresi (ms). */
private const val MOTION_MS = 250

/** Paket kimliğinden kısa ad ve kod (tuvaldeki karolar). */
fun packShort(id: String, title: String): Pair<String, String> = when (id) {
    "gta-v" -> "GTA" to "GTA V"
    "red-dead-redemption-2" -> "RDR" to "Red Dead 2"
    "mafia-the-old-country" -> "MAF" to "Mafia: TOC"
    "assassins-creed-shadows" -> "ACS" to "AC Shadows"
    "death-stranding-2" -> "DS2" to "Death Str. 2"
    "call-of-duty-modern-warfare-2019" -> "MW" to "CoD MW 2019"
    else -> title.filter { it.isLetterOrDigit() }.take(3).uppercase() to title
}

/** "190 bin satır" */
fun linesText(context: Context, entries: Int): String =
    if (entries >= 1000) context.getString(R.string.lines_thousands, (entries + 500) / 1000) else context.getString(R.string.lines_count, entries)

fun durationText(context: Context, millis: Long): String {
    val minutes = millis / 60_000
    return if (minutes >= 60) context.getString(R.string.duration_hours, minutes / 60, minutes % 60) else context.getString(R.string.duration_minutes, minutes)
}

@Composable
fun MainScreen(
    status: LiveStatus,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onPhoneView: () -> Unit,
    onTarget: () -> Unit,
    onDemo: () -> Unit = {},
    onExitDemo: () -> Unit = {},
    onPairing: () -> Unit,
    onPacks: () -> Unit,
    onProfile: () -> Unit,
    onSettings: () -> Unit,
    onHistory: () -> Unit = {},
    onTvUpdate: (InstalledTv) -> Unit = {},
    /** Ana ekran en üstte (geçişte ya da üstünde başka ekran varken false): tanıtım popup'ı yalnız o zaman açılır. */
    onHome: Boolean = true,
) {
    val context = LocalContext.current
    val settings = Services.settings
    val bounds = remember { mutableStateMapOf<TourStep, Rect>() }
    var tour by remember { mutableStateOf(if (settings.tourShown) null else TourStep.START) }
    val xbox = settings.xbox
    val paired = if (xbox) settings.xboxConsole != null && Services.xboxAuth.signedIn else settings.console != null
    fun mark(step: TourStep) = Modifier.onGloballyPositioned { bounds[step] = it.boundsInRoot() }
    // Perde (iPhone ile aynı): üstte logo; çeviri sürerken sağda canlı süre hapı. Boşta durum tek yerde, büyük başlıkta
    // ("Hazır"). Geçmiş ve Ayarlar alttaki cam sekme çubuğunda; turun "Profil ve ayarlar" adımı Ayarlar sekmesini gösterir.
    val topBar: @Composable () -> Unit = {
        TopBar {
            if (status.running) {
                val elapsed = rememberElapsed(status.startedAt)
                StatusChip(stringResource(R.string.running_pill, DateUtils.formatElapsedTime(elapsed)),
                    if (status.streaming) ChipTone.LIVE else ChipTone.AMBER)
            }
        }
    }
    val tabMarker: (PhoneTab) -> Modifier = { tab -> if (tab == PhoneTab.SETTINGS) mark(TourStep.PROFILE) else Modifier }

    // Kendi ürünlerimizin tanıtımı (promo.json): yalnız boştaki ana ekranda, girişten 10 sn sonra; oturum, deneme,
    // kurulum ve tur sırasında asla. Açıkken ana ekran bulanıklaşır (Android 12+; altında yalnız karartma).
    val promo by com.couchsubs.mobile.promo.PromoController.ready.collectAsState()
    val promoShown = promo?.let { ready ->
        val moment = com.couchsubs.mobile.promo.PromoMoment(onHome = onHome, sessionActive = status.running, demo = status.demo,
            onboarding = Routes.next() != Routes.MAIN, tour = tour != null && !status.demo,
            inAppMs = System.currentTimeMillis() - com.couchsubs.mobile.promo.PromoController.foregroundAtMs)
        val record = com.couchsubs.mobile.promo.PromoController.record(context)
        ready.takeIf { com.couchsubs.mobile.promo.PromoPolicy.shouldShow(it.popup, record, System.currentTimeMillis(), moment) }
    }
    // Paket karosundaki kapak yığını: kurulu paketlerin ilk üçü, yoksa uygulamayla gelen ilk üç oyun (iPhone ile aynı).
    var coverTitles by remember { mutableStateOf(listOf("Grand Theft Auto V", "Red Dead Redemption 2", "Mafia")) }
    LaunchedEffect(Unit) {
        val shelf = withContext(Dispatchers.IO) {
            runCatching { GameCatalog.packShelf(Services.catalog(context).filter { it.installed }, { it.id }, { it.title }, { it.entries }) }
                .getOrDefault(emptyList())
        }
        if (shelf.isNotEmpty()) coverTitles = shelf.map { it.title }
    }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().then(if (promoShown != null) Modifier.blur(PROMO_BLUR) else Modifier)) {
            // Başlatınca ve durdurunca boşta ve çeviri ekranları solarak yer değiştirir.
            CompositionLocalProvider(LocalTabMarker provides tabMarker) {
            AnimatedContent(status.running, transitionSpec = { fadeIn(tween(MOTION_MS)) togetherWith fadeOut(tween(MOTION_MS)) },
                label = "running") { running ->
                if (running) CompositionLocalProvider(LocalAdBand provides false) {
                    RunningScreen(status, topBar, if (status.demo) onExitDemo else onStop, onPhoneView, onTvUpdate)
                }
                else ScreenScaffold(top = topBar, ambient = true, bottom = {
                    // PS5 eşlenmemişse (kurulum atlandı) başlatmak yerine eşleme açılır.
                    if (paired) PerdeButton(stringResource(R.string.start), ButtonKind.PRIMARY, modifier = mark(TourStep.START),
                        leading = { Icon(Icons.Filled.PlayArrow, null, tint = Tokens.Color.onAccent, modifier = Modifier.size(20.dp)) },
                        onClick = onStart)
                    else {
                        PrimaryButton(stringResource(R.string.main_pair_button), modifier = mark(TourStep.START), onClick = onPairing)
                        // Kurulum bitmeden de uygulama örnek görüntülerle denenebilir.
                        GhostButton(stringResource(R.string.demo_mode_try), Modifier.fillMaxWidth(), onClick = onDemo)
                    }
                }) {
                    if (paired) Heading(stringResource(R.string.main_ready), stringResource(R.string.main_ready_body))
                    else {
                        Heading(stringResource(R.string.main_unpaired), stringResource(R.string.main_unpaired_body))
                        NoteTile(stringResource(R.string.main_unpaired_note), Tokens.Color.secondary)
                    }
                    AnimatedNote(status.error)
                    TvAppUpdateCard(onTvUpdate)
                    // Perde: TV önizlemesi kahraman alan; altyazının nerede görüneceğini gösterir, dokununca hedef seçilir.
                    val targetLabel = targetName(settings)
                    val subtitlesLabel = stringResource(R.string.main_target)
                    Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(Tokens.Radius.preview))
                        .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onTarget)
                        .semantics(mergeDescendants = true) { contentDescription = "$subtitlesLabel: $targetLabel" }) {
                        PerdePreview(line = stringResource(R.string.perde_preview_line)) {
                            StatusChip(targetLabel, ChipTone.GLASS, dot = false,
                                icon = if (settings.target.showsOnTv) CouchIcons.Tv else CouchIcons.Smartphone)
                        }
                    }
                    // Telefon ana ekranı: PS5 ve Altyazı durum karoları ilgili ayarı açar; altlarında durum hapı.
                    val tv = settings.installedTv
                    val targetReady = settings.target == SubtitleTarget.PHONE || settings.target == SubtitleTarget.OBS || tv != null || settings.tvName != null
                    // Altyazı karosunun rozeti "Hazır" değil, anlamlı kısa bilgi: TV'nin markası ya da yeri; TV yoksa "Kurulmadı".
                    val targetStatus = when {
                        settings.target == SubtitleTarget.PHONE -> stringResource(R.string.perde_on_this_screen)
                        settings.target == SubtitleTarget.OBS -> "OBS"
                        tv != null -> brandName(tv.brand)
                        targetReady -> stringResource(R.string.main_ready)
                        else -> stringResource(R.string.perde_not_set_up)
                    }
                    TwoColumns(
                        { if (xbox) StatusTile(CouchIcons.Gamepad, "Xbox · Beta", settings.xboxConsole?.name ?: stringResource(R.string.perde_choose_xbox), it,
                            status = stringResource(if (paired) R.string.main_ready else R.string.perde_not_set_up), statusOk = paired,
                            iconTone = if (paired) IconTone.TEAL else IconTone.GRAY, onClick = onPairing)
                          else StatusTile(CouchIcons.Gamepad, "PS5", settings.console?.name ?: stringResource(R.string.perde_pair_ps5), it,
                            status = stringResource(if (settings.console != null) R.string.perde_paired else R.string.perde_not_set_up),
                            statusOk = settings.console != null, iconTone = if (settings.console != null) IconTone.TEAL else IconTone.GRAY,
                            onClick = onPairing) },
                        { StatusTile(if (settings.target.showsOnTv) CouchIcons.Tv else CouchIcons.Smartphone, subtitlesLabel, targetLabel,
                            it.then(mark(TourStep.TARGET)), status = targetStatus,
                            statusOk = targetReady, iconTone = IconTone.AMBER, onClick = onTarget) },
                    )
                    // Paket karosu: kapak yığını, başlık ve not tek satır, sağda `›`; paketler kapalıysa nötr "Kapalı" etiketi.
                    Box(mark(TourStep.PACKS)) {
                        Tile(Modifier.fillMaxWidth(), onClick = onPacks) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                                CoverStack(coverTitles)
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                                    Text(stringResource(R.string.main_packs_title), style = Tokens.Type.headline, color = Tokens.Color.text,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(stringResource(R.string.main_packs_games), style = Tokens.Type.caption, color = Tokens.Color.secondary,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                if (!settings.packsEnabled) Pill(stringResource(R.string.main_packs_off))
                                Chevron()
                            }
                        }
                    }
                    // Çeviri motoru ve son oturum durum değil ayar bilgisidir: tek bilgi karosunda iki satır.
                    InfoCard(listOf(
                        { InfoRow(stringResource(R.string.main_engine), status.engineLabel.ifEmpty { engineName(context) }, onClick = onSettings) },
                        { InfoRow(stringResource(R.string.main_last_session),
                            if (settings.lastSessionMs > 0) durationText(context, settings.lastSessionMs) else "—", onClick = onHistory) },
                    ))
                    DeveloperSignature()
                }
            }
            }
            if (!status.demo) tour?.let { step ->
                TourOverlay(step, bounds[step], onSkip = {
                    settings.tourShown = true
                    tour = null
                }, onNext = {
                    val next = TourStep.entries.getOrNull(step.ordinal + 1)
                    if (next == null) settings.tourShown = true
                    tour = next
                })
            }
        }
        promoShown?.let { ready -> PromoOverlay(ready) { com.couchsubs.mobile.promo.PromoController.dismissed(context, ready.popup) } }
    }
}

/** Başlangıçtan bu yana geçen saniye; saniyede bir güncellenir (canlı hap). */
@Composable
internal fun rememberElapsed(startedAt: Long): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(startedAt) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }
    return ((now - startedAt).coerceAtLeast(0) / 1000)
}

/** Son satırın ölçümleri tek satırda; bilinmeyen değer yazılmaz, hiç ölçüm yoksa null. */
fun metricsText(context: Context, pair: com.couchsubs.mobile.core.ShownPair): String? {
    val total = pair.totalMs ?: return null
    val parts = mutableListOf<String>()
    pair.ocrMs?.let { parts.add(context.getString(R.string.metrics_ocr, it)) }
    if (pair.origin == "paket") parts.add(context.getString(R.string.metrics_pack))
    else pair.translationMs?.let { parts.add(context.getString(R.string.metrics_translation, it)) }
    parts.add(context.getString(R.string.metrics_delay, total))
    return parts.joinToString(" · ")
}

fun engineName(context: Context): String = when (Services.settings.engine) {
    com.couchsubs.mobile.settings.EngineChoice.FREE -> context.getString(R.string.engine_free_short)
    com.couchsubs.mobile.settings.EngineChoice.DEEPL -> "DeepL"
    com.couchsubs.mobile.settings.EngineChoice.GEMINI -> "Gemini"
    com.couchsubs.mobile.settings.EngineChoice.OPENAI -> "OpenAI"
    com.couchsubs.mobile.settings.EngineChoice.CLAUDE -> "Claude"
    com.couchsubs.mobile.settings.EngineChoice.LOCAL -> context.getString(R.string.engine_local)
}

/** Deneme modunda çeviri ekranının üstü: "Deneme modu" rozeti, "Çık" ve hattın okuduğu örnek kare (iPhone ile aynı). */
@Composable
private fun DemoHeader(onExit: () -> Unit) {
    DisposableEffect(Unit) {
        FramePreview.watch(true)
        onDispose { FramePreview.watch(false) }
    }
    val frame by FramePreview.frame.collectAsState()
    Row(verticalAlignment = Alignment.CenterVertically) {
        Pill(stringResource(R.string.demo_mode), pro = true)
        Spacer(Modifier.weight(1f))
        GhostButton(stringResource(R.string.demo_mode_exit_short), onClick = onExit)
    }
    Tile(Modifier.fillMaxWidth()) {
        frame?.let {
            Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.FillWidth,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(Tokens.Radius.inner)))
        }
        Text(stringResource(R.string.demo_mode_frame_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
    }
}

/** Çeviri sürerken (tuval Telefon-Calisiyor): süre, paket, canlı satır ve önceki satırlar, sayılar. */
@Composable
private fun RunningScreen(status: LiveStatus, topBar: @Composable () -> Unit, onStop: () -> Unit, onPhoneView: () -> Unit,
                          onTvInstall: (InstalledTv) -> Unit = {}) {
    val context = LocalContext.current
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }
    ScreenScaffold(top = topBar, bottom = {
        // İkincil düğmeler yan yana (iPhone ile aynı): altyazı ekranı telefonda gösterirken ya da deneme modunda, "TV'de
        // dene" TV'ye çevirirken, "Ekranı çevir" yalnız görüntü gelirken.
        val target = Services.settings.target
        if (target.showsOnPhone || status.demo || target.showsOnTv || status.streaming)
            Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                if (target.showsOnPhone || status.demo)
                    SecondaryButton(stringResource(R.string.main_phone_view), Modifier.weight(1f), onClick = onPhoneView)
                if (target.showsOnTv) SecondaryButton(stringResource(R.string.settings_test_subtitle), Modifier.weight(1f)) {
                    com.couchsubs.mobile.service.TranslationService.sendTestSubtitle(context.getString(R.string.test_subtitle_text))
                }
                if (status.streaming) ScreenTranslateButton(status, Modifier.weight(1f))
            }
        // Perde: kırmızı yumuşak hap + nabız noktası; deneme modundan çıkış kare simgeli.
        if (status.demo) StopButton(stringResource(R.string.demo_mode_exit), onClick = onStop)
        else LiveButton(stringResource(R.string.stop), onClick = onStop)
    }) {
        if (status.demo) DemoHeader(onStop)
        // Süre üst satırdaki canlı hapta (Perde); burada yalnız hazır çeviri etiketi.
        status.packInUse?.let { Pill(stringResource(R.string.running_pack, it), pro = true) }
        // Görüntü gelirken durum metni ("Altyazılar okunuyor") üstteki "Çeviri sürüyor" satırını tekrarlar; yalnız
        // bağlanırken ve bağlantı sorunlarında gösterilir.
        if (!status.streaming && status.phase.isNotEmpty()) Text(status.phase, style = Tokens.Type.caption, color = Tokens.Color.secondary)
        // Oturum yeniden denemeyi bıraktıysa hemen, süren denemelerde 45 sn sonra: uygulamayı kapatıp açmadan bağlantı
        // baştan kurulur (ReconnectOffer; Mac/iPhone ile aynı).
        if (status.running && !status.demo && !status.streaming &&
            com.couchsubs.mobile.remoteplay.ReconnectOffer.shows(status.notLiveSince, status.gaveUp, now))
            SecondaryButton(stringResource(R.string.reconnect)) { com.couchsubs.mobile.service.TranslationService.reconnect() }
        AnimatedNote(status.error)
        // TV'ye çevirirken telefon kilitlenebilir: pil kısıtlaması açıksa çeviri ekran kapanınca durabilir.
        if (!status.demo && Services.settings.target.showsOnTv) BackgroundLimitNote()
        // TV uygulaması sürümünü çeviri başında, altyazı akışına bağlanınca bildirir: eskiyse güncelleme önerisi çeviri
        // ekranında da görünür. Önceden yalnız ana ekrandaydı, çeviri sürerken hiç görülmüyordu; TV'de 0.9.71 kalmıştı
        // (GitHub #1199). Windows, Mac ve iPhone ile aynı.
        if (!status.demo && Services.settings.target.showsOnTv) TvAppUpdateCard(onTvInstall)
        // TV uygulaması bağlı değil: CouchSubs TV'de nerede bulunur (markaya göre), otomatik açma neden olmadı ve
        // "Otomatik açmayı dene" (Windows, Mac ve iPhone ile aynı).
        if (!status.demo && Services.settings.target.showsOnTv && status.connectedTvs == 0)
            Services.settings.installedTv?.let { tv -> TvOpenCard(tv.brand, status.tvOpenProblem, status.tvReconnecting) { onTvInstall(tv) } }
        val current = status.recent.firstOrNull()
        // İlk altyazı gelene kadar ve bağlantı koptuğunda: kolu açınca PS5'te ana hesap seçilmeli (GitHub #231, MainAccountTip).
        if (com.couchsubs.mobile.remoteplay.MainAccountTip.visible(ps5 = !Services.settings.xbox, demo = status.demo,
                hasSubtitle = current != null, streaming = status.streaming))
            NoteTile(stringResource(R.string.psn_main_account_steps), Tokens.Color.secondary)
        // Otomatik ekran yazısı beta.63'te açık geliyordu; bir kez kapatıldı, kullanıcıya söylenir.
        if (com.couchsubs.mobile.settings.AppSettings.autoScreenTextNotice)
            NoteTile(stringResource(R.string.auto_screen_text_notice), Tokens.Color.secondary)
        // Çevrimiçi motor çeviremiyor: gerçek nedeni (anahtar, kota, ağ) söylenir (GitHub #1322; Mac, iPhone, Windows ile aynı).
        if (status.running) status.onlineIssue?.let { issue ->
            NoteTile(onlineIssueText(issue, status.engineLabel))
        }
        // Görüntü bir dakikadır geliyor ama hiç altyazı satırı okunmadı (GitHub #503, #566, #572; SubtitleOffTip).
        if (status.subtitleOffTip) {
            NoteTile(stringResource(R.string.subtitle_off_tip), Tokens.Color.secondary)
        }
        // Telefon çevirisi kapalıyken GTA 6 telefonunun listesi altyazı sayılmadı (#1202): oturumda bir kez sorulur.
        if (status.gamePhoneHint && !status.demo) {
            Tile(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.game_phone_hint), style = Tokens.Type.body, color = Tokens.Color.text)
                Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                    SecondaryButton(stringResource(R.string.game_phone_hint_turn_on)) {
                        Services.settings.setGamePhone(true)
                        com.couchsubs.mobile.service.LiveState.update { it.copy(gamePhoneHint = false) }
                    }
                    GhostButton(stringResource(R.string.area_profile_no), color = Tokens.Color.secondary) {
                        com.couchsubs.mobile.service.LiveState.update { it.copy(gamePhoneHint = false) }
                    }
                }
            }
        }
        if (!status.demo) GameSection(status)
        // Yeni satır gelince kartın amber halkası kısa sürede söner (hareket azaltılmışken yok).
        val flash = remember { Animatable(0f) }
        val gate = motionGate()
        LaunchedEffect(current?.translation) {
            if (current != null && !gate.reduced) {
                flash.snapTo(0.9f)
                flash.animateTo(0f, tween(900))
            }
        }
        Box(Modifier.fillMaxWidth()) {
            Tile(Modifier.fillMaxWidth()) {
                TileLabel(stringResource(R.string.running_now))
                // Son çeviri (canlı satır 28), altında özgün metin.
                Text(current?.translation ?: stringResource(R.string.running_waiting), style = Tokens.Type.subtitleCurrent,
                    color = if (current != null) Tokens.Color.text else Tokens.Color.secondary)
                current?.let {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        Text(it.source, style = Tokens.Type.caption, color = Tokens.Color.secondary, modifier = Modifier.weight(1f))
                        if (it.origin == "paket") Text(stringResource(R.string.running_ready_translation), style = Tokens.Type.caption, color = Tokens.Color.pro)
                    }
                    // Ölçüm satırı (iPhone ile aynı): "OCR 42 ms · Çeviri 310 ms · Gecikme 520 ms".
                    metricsText(context, it)?.let { line -> Text(line, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
                }
            }
            if (flash.value > 0f) Box(Modifier.matchParentSize().border(1.5.dp, Tokens.Color.accent.copy(alpha = flash.value),
                RoundedCornerShape(Tokens.Radius.tile)))
        }
        // Önceki 8 satır (iPhone ile aynı).
        val previous = status.recent.drop(1).take(8)
        if (previous.isNotEmpty()) RowList(previous.map { pair ->
            {
                // Satır iki ya da daha çok satıra uzayınca kaynak etiketi ilk satırın hizasında kalır.
                Row(Modifier.padding(vertical = Tokens.Space.inline), verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                        Text(pair.translation, style = Tokens.Type.line, color = Tokens.Color.secondary)
                        Text(pair.source, style = Tokens.Type.caption, color = Tokens.Color.secondary)
                    }
                    if (pair.origin == "paket") Text(stringResource(R.string.running_ready), style = Tokens.Type.caption, color = Tokens.Color.pro)
                    else Text(status.engineLabel, style = Tokens.Type.caption, color = Tokens.Color.secondary)
                }
            }
        })
        TwoColumns(
            { Tile(it) {
                TileLabel(stringResource(R.string.running_from_pack))
                Text("${status.packLines} / ${status.shownLines}", style = Tokens.Type.monoValue, color = Tokens.Color.text)
            } },
            { Tile(it) {
                TileLabel(stringResource(R.string.main_tvs_label))
                Text(if (Services.settings.target.showsOnTv) status.connectedTvs.toString()
                    else stringResource(if (Services.settings.target == SubtitleTarget.OBS) R.string.target_obs else R.string.main_target_phone),
                    style = Tokens.Type.titleNumeric, color = Tokens.Color.text)
            } },
        )
    }
}

/**
 * Çeviri sürüyor ama TV uygulaması bağlı değil: kullanıcı CouchSubs'ı TV'de kendisinin açması gerektiğini bilmiyordu
 * ("ilk başta olmadı, TV'den de uygulamayı açmak lazımmış", 21 Kas). Düğme açma döngüsünü beklemeden yeniden denetir.
 */
@Composable
private fun TvOpenCard(brand: com.couchsubs.mobile.tv.TvBrand, problem: com.couchsubs.mobile.tv.TvOpenProblem?, reconnecting: Boolean,
                       onInstall: () -> Unit) {
    Tile(Modifier.fillMaxWidth()) {
        // TV bağlantısı koptu ya da TV alındı göndermeyi bıraktı: "Bağlı" yerine "yeniden bağlanılıyor"; bekçi uygulamayı
        // kendisi yeniden açar, 60 sn içinde bağlanmazsa yalnız "TV'de açın" kalır (Mac/iPhone/Windows ile aynı).
        if (reconnecting) Text(stringResource(R.string.tv_reconnecting), style = Tokens.Type.body, color = Tokens.Color.warning)
        Text(stringResource(com.couchsubs.mobile.tv.TvOpenProblem.openOnTv(brand)), style = Tokens.Type.body, color = Tokens.Color.text)
        com.couchsubs.mobile.tv.TvOpenProblem.reason(problem)?.let {
            Text(stringResource(it), style = Tokens.Type.caption, color = Tokens.Color.warning)
        }
        SecondaryButton(stringResource(R.string.tv_open_try)) {
            com.couchsubs.mobile.tv.TvOpenRetry.request()
            com.couchsubs.mobile.service.LiveState.update { it.copy(tvOpenProblem = null) }
        }
        // TV uygulaması kurulu değilse ya da açılmıyorsa bu telefondan kurulur (iPhone'daki "TV uygulamasını bu telefondan kur").
        GhostButton(stringResource(R.string.tvinstall_entry), onClick = onInstall)
    }
}

/**
 * Karartma %70, vurgulanan öğe çevresinde amber çerçeveli delik (köşesi öğenin köşesi + 6 boşluk, iç içe köşeler
 * paralel kalsın); kart surface2. Karartma alttaki ekrana dokunuş geçirmez; Geri tuşu turu "Geç" gibi kapatır.
 */
@Composable
private fun TourOverlay(step: TourStep, target: Rect?, onSkip: () -> Unit, onNext: () -> Unit) {
    BackHandler(onBack = onSkip)
    BoxWithConstraints(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { } }) {
        Canvas(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
            drawRect(Color.Black.copy(alpha = 0.7f))
            target?.let { rect ->
                val pad = TOUR_PAD.toPx()
                val topLeft = Offset(rect.left - pad, rect.top - pad)
                val size = Size(rect.width + 2 * pad, rect.height + 2 * pad)
                val corner = CornerRadius((step.radius + TOUR_PAD).toPx())
                drawRoundRect(Color.Transparent, topLeft, size, corner, blendMode = BlendMode.Clear)
                drawRoundRect(Tokens.Color.accent, topLeft, size, corner, style = Stroke(2.dp.toPx()))
            }
        }
        // Öğe ekranın alt yarısındaysa kart üstte durur (piksel eşiği değil, ekran yüksekliğine göre).
        val above = target != null && target.center.y > constraints.maxHeight / 2f
        Column(Modifier.align(if (above) Alignment.TopCenter else Alignment.BottomCenter).safeDrawingPadding().padding(Tokens.Space.screen)
            .background(Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.tile)).padding(Tokens.Space.tile),
            verticalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${step.ordinal + 1} / ${TourStep.entries.size}", style = Tokens.Type.caption, color = Tokens.Color.secondary)
                Spacer(Modifier.weight(1f))
                GhostButton(stringResource(R.string.skip), onClick = onSkip)
            }
            Text(stringResource(step.title), style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(step.body), style = Tokens.Type.body, color = Tokens.Color.secondary)
            PrimaryButton(stringResource(if (step == TourStep.PROFILE) R.string.tour_done else R.string.next), onClick = onNext)
        }
    }
}

/** Oyun paketleri (ücretsiz): anahtarla toptan, karoya dokunarak paket başına açılıp kapatılır. */
@Composable
fun PacksScreen(onBack: () -> Unit, packInUse: String?) {
    val context = LocalContext.current
    val settings = Services.settings
    val version by Services.packsVersion.collectAsState()
    val status by Services.packStatus.collectAsState()
    var catalog by remember { mutableStateOf<List<Services.CatalogEntry>?>(null) }
    var disabled by remember { mutableStateOf(settings.disabledPacks) }
    var packsOn by remember { mutableStateOf(settings.packsEnabled) }
    LaunchedEffect(version) { catalog = withContext(Dispatchers.IO) { Services.catalog(context) } }
    val unlocked = packsOn
    // Oyunun "(ek satırlar)" paketi asıl paketin karosunda; ikisi birlikte açılıp kapanır (#353).
    val list = GameCatalog.packShelf(catalog.orEmpty(), { it.id }, { it.title }, { it.entries })
    // "Paketleri güncelle"ye basıldı, sonuç bekleniyor: sayfa bulanıklaşır (Android 12+; öncesinde koyu perde), ortada
    // gösterge döner; bitince ne geldiği uyarıda yazar (iPhone ile aynı).
    var updating by remember { mutableStateOf(false) }
    var outcome by remember { mutableStateOf<PackUpdateOutcome?>(null) }
    val scope = rememberCoroutineScope()
    val busy = updating || status == Services.PackStatus.DOWNLOADING
    fun updateNow() {
        if (updating) return
        updating = true
        outcome = null
        scope.launch {
            val before = withContext(Dispatchers.IO) {
                catalog?.filter { it.installed }?.map { it.id to it.entries }
                    ?: Services.packLibrary(context).infos.map { it.id to it.entries }
            }
            val result = try {
                Services.updatePacksNow(before)
            } finally {
                updating = false
            }
            outcome = result
        }
    }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().then(if (updating) Modifier.blur(12.dp) else Modifier)) {
            ScreenScaffold(top = {
                TopBar(stringResource(R.string.packs_title), onBack = onBack) {
                    Pill(if (list.isEmpty()) stringResource(R.string.packs_free) else stringResource(R.string.packs_free_count, list.size))
                }
            }, bottom = {
                SecondaryButton(stringResource(if (busy) R.string.packs_updating_short else R.string.packs_refresh),
                    enabled = !busy) { updateNow() }
            }) {
                Text(stringResource(R.string.packs_auto), style = Tokens.Type.body, color = Tokens.Color.secondary)
                Tile(Modifier.fillMaxWidth()) {
                    SwitchRow(stringResource(R.string.settings_packs), stringResource(R.string.packs_switch_note), packsOn) {
                        packsOn = it; settings.packsEnabled = it
                    }
                }
                // Güncelleme hatası sessizce yutulmaz (iPhone'daki gibi): ulaşılamazsa telefondaki paketlerin kullanıldığı yazar.
                when (status) {
                    Services.PackStatus.DOWNLOADING -> Text(stringResource(R.string.packs_updating), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                    Services.PackStatus.OFFLINE -> NoteTile(stringResource(R.string.packs_offline))
                    Services.PackStatus.FAILED -> NoteTile(stringResource(R.string.packs_failed))
                    else -> {}
                }
                if (catalog == null) Text(stringResource(R.string.packs_loading), style = Tokens.Type.body, color = Tokens.Color.secondary)
                else if (list.isEmpty()) NoteTile(stringResource(R.string.packs_none_yet), Tokens.Color.secondary)
                // Perde kapak rafı: yatay kayan 3:4 tipografik kapaklar; oynanan paketin kapağı amber halka ve kendi renginden
                // ışıma. Kapağa dokunmak paketi açar ya da kapatır (anahtar; seçim titreşimi).
                if (list.isNotEmpty()) CoverShelf(stringResource(R.string.perde_installed_packs)) {
                    list.forEach { entry ->
                        val on = entry.packIds.none { it in disabled }
                        val playing = packInUse != null && packInUse in entry.titles
                        val view = LocalView.current
                        Column(
                            Modifier.width(DesignTokens.Size.coverWidthRail.dp).alpha(if (unlocked && on) 1f else 0.5f)
                                .toggleable(on, role = androidx.compose.ui.semantics.Role.Switch) {
                                    Haptics.selection(view)
                                    disabled = if (on) disabled + entry.packIds else disabled - entry.packIds.toSet()
                                    settings.disabledPacks = disabled
                                },
                            verticalArrangement = Arrangement.spacedBy(Tokens.Space.titleToBody),
                        ) {
                            GameCover(entry.title, stringResource(when {
                                playing -> R.string.perde_now_playing
                                on -> R.string.perde_installed
                                else -> R.string.perde_off
                            }), selected = playing)
                            Text(linesText(context, entry.entries), style = Tokens.Type.captionNumeric, color = Tokens.Color.secondary, maxLines = 1)
                        }
                    }
                }
                ImportedPacksSection()
                Tile(Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        TileIcon(Icons.Filled.Refresh)
                        Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                            Text(stringResource(R.string.packs_next), style = Tokens.Type.headline, color = Tokens.Color.text)
                            Text(stringResource(R.string.packs_next_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                    }
                }
            }
        }
        if (updating) PacksUpdatingOverlay()
    }
    outcome?.let { shown ->
        val failed = shown is PackUpdateOutcome.Failed
        AlertDialog(
            onDismissRequest = { outcome = null },
            title = { Text(stringResource(when (shown) {
                PackUpdateOutcome.UpToDate -> R.string.packs_result_current_title
                is PackUpdateOutcome.Updated -> R.string.packs_result_updated_title
                is PackUpdateOutcome.Failed -> R.string.packs_result_failed_title
            })) },
            text = { Text(packUpdateMessage(context, shown)) },
            confirmButton = {
                TextButton({
                    outcome = null
                    if (failed) updateNow()
                }) { Text(stringResource(if (failed) R.string.packs_retry else R.string.ok)) }
            },
            dismissButton = if (failed) ({ TextButton({ outcome = null }) { Text(stringResource(R.string.close)) } }) else null,
            containerColor = Tokens.Color.surface2,
        )
    }
}

/** Güncelleme sürerken sayfanın üstündeki perde: dokunuş ve Geri tuşu geçmez, ortada gösterge ve "Paketler güncelleniyor…". */
@Composable
private fun PacksUpdatingOverlay() {
    BackHandler { }
    // Bulanıklık Android 12'den önce çalışmaz; orada perde daha koyu.
    val scrim = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) 0.45f else 0.7f
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = scrim)).pointerInput(Unit) { detectTapGestures { } },
        contentAlignment = Alignment.Center) {
        Column(Modifier.glass(RoundedCornerShape(Tokens.Radius.tile)).padding(Tokens.Space.tile * 1.5f),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
            BarsLoader(2f)
            Text(stringResource(R.string.packs_updating), style = Tokens.Type.headline, color = Tokens.Color.text)
        }
    }
}

/** "2 paket güncellendi: Grand Theft Auto VI (+12.300 satır), Red Dead Redemption 2 (+800 satır)." */
fun packUpdateMessage(context: Context, outcome: PackUpdateOutcome): String = when (outcome) {
    PackUpdateOutcome.UpToDate -> context.getString(R.string.packs_result_current)
    is PackUpdateOutcome.Updated -> packSummaryText(context, outcome.summary)
    is PackUpdateOutcome.Failed -> {
        val reason = when (outcome.reason) {
            PackUpdateOutcome.Reason.OFFLINE -> context.getString(R.string.packs_error_offline)
            PackUpdateOutcome.Reason.RATE_LIMITED -> context.getString(R.string.packs_error_rate)
            PackUpdateOutcome.Reason.SERVER -> context.getString(R.string.packs_error_server, outcome.status ?: 0)
            PackUpdateOutcome.Reason.PARTIAL -> context.getString(R.string.packs_error_partial)
            PackUpdateOutcome.Reason.UNKNOWN -> context.getString(R.string.packs_error_unknown)
        }
        (listOf(reason, context.getString(R.string.packs_result_still_used)) +
            listOfNotNull(packSummaryText(context, outcome.summary).takeIf { it.isNotEmpty() })).joinToString("\n\n")
    }
}

private fun packSummaryText(context: Context, summary: PackUpdateSummary): String {
    val locale = context.resources.configuration.locales[0]
    val number = { value: Int -> java.text.NumberFormat.getIntegerInstance(locale).format(value) }
    val parts = mutableListOf<String>()
    val updated = summary.updated
    if (updated.isNotEmpty()) {
        val items = updated.joinToString(", ") { change ->
            when {
                change.lineDelta > 0 -> context.getString(R.string.packs_result_item_more, change.title, number(change.lineDelta))
                change.lineDelta < 0 -> context.getString(R.string.packs_result_item_fewer, change.title, number(-change.lineDelta))
                else -> context.getString(R.string.packs_result_item_revised, change.title)
            }
        }
        parts += if (updated.size == 1) context.getString(R.string.packs_result_updated_one, items)
        else context.getString(R.string.packs_result_updated_many, updated.size, items)
    }
    val added = summary.added
    if (added.isNotEmpty()) {
        val items = added.joinToString(", ") { context.getString(R.string.packs_result_item_lines, it.title, number(it.lines)) }
        parts += if (added.size == 1) context.getString(R.string.packs_result_added_one, items)
        else context.getString(R.string.packs_result_added_many, added.size, items)
    }
    if (summary.newLines > 0) parts += context.getString(R.string.packs_result_total, number(summary.newLines))
    return parts.joinToString("\n")
}

/** Tur deliğinin öğeden taşma payı. */
private val TOUR_PAD = 6.dp

fun open(context: Context, url: String) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (error: Exception) {
    }
}

/** "Ekranı çevir": oyun ekranının tamamını çevirir; çeviri sürerken ya da sonuçlar ekrandayken dokununca kaldırır (iPhone ile aynı). */
@Composable
fun ScreenTranslateButton(status: LiveStatus, modifier: Modifier = Modifier) {
    val label = when (status.screenState) {
        LiveStatus.ScreenState.IDLE -> R.string.screen_translate
        LiveStatus.ScreenState.WORKING -> R.string.screen_working
        LiveStatus.ScreenState.SHOWN -> R.string.screen_remove
    }
    SecondaryButton(stringResource(label), modifier) { com.couchsubs.mobile.service.TranslationService.translateScreen() }
}

/** Çevrimiçi motor hatasının ana ekran metni: "DeepL şu an çevirmiyor. <neden> Bu arada ücretsiz çeviri kullanılıyor." */
@Composable
internal fun onlineIssueText(issue: com.couchsubs.mobile.translation.OnlineKeyState, engine: String): String =
    stringResource(R.string.online_issue_title, engine) + ". " +
        (onlineIssueReason(issue)?.let { stringResource(it, engine) + " " } ?: "") + stringResource(R.string.online_issue_meanwhile)

/** Hatanın nedeni (Mac/iPhone OnlineIssueText.describe, Windows Contracts.Describe ile aynı metinler); yoksa null. */
internal fun onlineIssueReason(issue: com.couchsubs.mobile.translation.OnlineKeyState): Int? = when (issue) {
    com.couchsubs.mobile.translation.OnlineKeyState.INVALID -> R.string.online_issue_invalid
    com.couchsubs.mobile.translation.OnlineKeyState.QUOTA_EXCEEDED -> R.string.online_issue_quota
    com.couchsubs.mobile.translation.OnlineKeyState.MODEL_REJECTED -> R.string.online_issue_model
    com.couchsubs.mobile.translation.OnlineKeyState.UNREACHABLE -> R.string.online_issue_unreachable
    com.couchsubs.mobile.translation.OnlineKeyState.BUSY -> R.string.online_issue_busy
    else -> null
}
