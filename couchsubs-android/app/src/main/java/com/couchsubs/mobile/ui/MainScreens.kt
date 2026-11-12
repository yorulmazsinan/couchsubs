// SPDX-License-Identifier: AGPL-3.0-only
// Ana ekran (tuval: Telefon-Ana, -Calisiyor, -Tur) ve oyun paketleri (-Paketler). Uygulama ve paketler ücretsiz.
package com.couchsubs.mobile.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.AdBanner
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.settings.SubtitleTarget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** Turda vurgulanan öğeler (TASARIM-MOBIL.md §10, tuval Telefon-Tur). */
private enum class TourStep(val title: Int, val body: Int) {
    START(R.string.tour1_title, R.string.tour1_body),
    TARGET(R.string.tour2_title, R.string.tour2_body),
    PACKS(R.string.tour3_title, R.string.tour3_body),
    PROFILE(R.string.tour4_title, R.string.tour4_body),
}

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
    onPairing: () -> Unit,
    onPacks: () -> Unit,
    onProfile: () -> Unit,
    onSettings: () -> Unit,
) {
    val context = LocalContext.current
    val settings = Services.settings
    val bounds = remember { mutableStateMapOf<TourStep, Rect>() }
    var tour by remember { mutableStateOf(if (settings.tourShown) null else TourStep.START) }
    fun mark(step: TourStep) = Modifier.onGloballyPositioned { bounds[step] = it.boundsInRoot() }
    val topBar: @Composable () -> Unit = {
        TopBar {
            SettingsAction(onSettings)
            Box(mark(TourStep.PROFILE)) { ProfileAction(onProfile) }
        }
    }

    Box(Modifier.fillMaxSize()) {
        if (status.running) RunningScreen(status, topBar, onStop, onPhoneView)
        else ScreenScaffold(top = topBar, bottom = {
            AdBanner()
            PrimaryButton(stringResource(R.string.start), modifier = mark(TourStep.START), onClick = onStart)
        }) {
            Heading(stringResource(R.string.main_ready), stringResource(R.string.main_ready_body))
            status.error?.let { NoteTile(it) }
            TwoColumns(
                { StatusTile(Icons.Filled.PlayArrow, "PS5", settings.console?.name ?: stringResource(R.string.profile_not_paired), it,
                    corner = { if (settings.console != null) StatusLabel(stringResource(R.string.main_paired)) }, onClick = onPairing) },
                { StatusTile(if (settings.target == SubtitleTarget.TV) Icons.Filled.Home else Icons.Filled.Phone, stringResource(R.string.main_target),
                    if (settings.target == SubtitleTarget.TV) settings.tvName ?: stringResource(R.string.main_target_tv) else stringResource(R.string.main_target_phone),
                    it.then(mark(TourStep.TARGET)), onClick = onTarget) },
            )
            Box(mark(TourStep.PACKS)) {
                Tile(Modifier.fillMaxWidth(), onClick = onPacks) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        TileIcon(Icons.AutoMirrored.Filled.List, Tokens.Color.pro)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                            Text(stringResource(R.string.main_packs_title), style = Tokens.Type.headline, color = Tokens.Color.text)
                            Text(stringResource(R.string.main_packs_games), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                        Pill(stringResource(if (settings.packsEnabled) R.string.packs_free else R.string.main_packs_off))
                        TileIcon(Icons.AutoMirrored.Filled.KeyboardArrowRight)
                    }
                }
            }
            TwoColumns(
                { StatusTile(Icons.Filled.Create, stringResource(R.string.main_engine), status.engineLabel.ifEmpty { engineName(context) }, it, onClick = onSettings) },
                { StatusTile(Icons.Filled.DateRange, stringResource(R.string.main_last_session),
                    if (settings.lastSessionMs > 0) durationText(context, settings.lastSessionMs) else "—", it) },
            )
        }
        tour?.let { step ->
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
}

fun engineName(context: Context): String = when (Services.settings.engine) {
    com.couchsubs.mobile.settings.EngineChoice.FREE -> context.getString(R.string.engine_free_short)
    com.couchsubs.mobile.settings.EngineChoice.DEEPL -> "DeepL"
    com.couchsubs.mobile.settings.EngineChoice.GEMINI -> "Gemini"
    com.couchsubs.mobile.settings.EngineChoice.OPENAI -> "OpenAI"
    com.couchsubs.mobile.settings.EngineChoice.CLAUDE -> "Claude"
}

/** Çeviri sürerken (tuval Telefon-Calisiyor): süre, paket, canlı satır ve önceki satırlar, sayılar. */
@Composable
private fun RunningScreen(status: LiveStatus, topBar: @Composable () -> Unit, onStop: () -> Unit, onPhoneView: () -> Unit) {
    val context = LocalContext.current
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }
    ScreenScaffold(top = topBar, bottom = {
        SecondaryButton(stringResource(R.string.main_phone_view), onClick = onPhoneView)
        DestructiveButton(stringResource(R.string.stop), onClick = onStop)
    }) {
        Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap), verticalAlignment = Alignment.CenterVertically) {
            val elapsed = ((now - status.startedAt).coerceAtLeast(0) / 1000)
            StatusLabel(stringResource(R.string.running_pill, "%d:%02d".format(elapsed / 60, elapsed % 60)), live = true)
            Spacer(Modifier.weight(1f))
            status.packInUse?.let { Pill(stringResource(R.string.running_pack, it), pro = true) }
        }
        Text(status.phase, style = Tokens.Type.caption, color = Tokens.Color.secondary)
        status.error?.let { NoteTile(it) }
        val current = status.recent.firstOrNull()
        Tile(Modifier.fillMaxWidth()) {
            TileLabel(stringResource(R.string.running_now))
            // Son çeviri altyazı sarısında (içerik), altında özgün metin.
            Text(current?.translation ?: stringResource(R.string.running_waiting), style = Tokens.Type.subtitleCurrent,
                color = if (current != null) Tokens.Color.accentText else Tokens.Color.secondary)
            current?.let {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                    Text(it.source, style = Tokens.Type.caption, color = Tokens.Color.secondary, modifier = Modifier.weight(1f))
                    if (it.origin == "paket") Text(stringResource(R.string.running_ready_translation), style = Tokens.Type.caption, color = Tokens.Color.pro)
                }
            }
        }
        val previous = status.recent.drop(1).take(4)
        if (previous.isNotEmpty()) RowList(previous.map { pair ->
            {
                Row(Modifier.padding(vertical = Tokens.Space.inline), verticalAlignment = Alignment.CenterVertically,
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
                Text("${status.packLines} / ${status.shownLines}", style = Tokens.Type.title, color = Tokens.Color.text)
            } },
            { Tile(it) {
                TileLabel(stringResource(R.string.main_tvs_label))
                Text(if (Services.settings.target == SubtitleTarget.TV) status.connectedTvs.toString() else stringResource(R.string.main_target_phone),
                    style = Tokens.Type.title, color = Tokens.Color.text)
            } },
        )
    }
}

/** Karartma %70, vurgulanan öğe çevresinde amber çerçeveli 16 yarıçaplı delik; kart surface2. */
@Composable
private fun TourOverlay(step: TourStep, target: Rect?, onSkip: () -> Unit, onNext: () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
            drawRect(Color.Black.copy(alpha = 0.7f))
            target?.let { rect ->
                val pad = 6.dp.toPx()
                val topLeft = Offset(rect.left - pad, rect.top - pad)
                val size = Size(rect.width + 2 * pad, rect.height + 2 * pad)
                val corner = CornerRadius(16.dp.toPx())
                drawRoundRect(Color.Transparent, topLeft, size, corner, blendMode = BlendMode.Clear)
                drawRoundRect(Tokens.Color.accent, topLeft, size, corner, style = Stroke(2.dp.toPx()))
            }
        }
        val above = (target?.top ?: 0f) > 900f
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
    var catalog by remember { mutableStateOf<List<Services.CatalogEntry>?>(null) }
    var disabled by remember { mutableStateOf(settings.disabledPacks) }
    var packsOn by remember { mutableStateOf(settings.packsEnabled) }
    LaunchedEffect(version) { catalog = withContext(Dispatchers.IO) { Services.catalog(context) } }
    val unlocked = packsOn
    val list = catalog.orEmpty()
    ScreenScaffold(top = {
        TopBar(stringResource(R.string.packs_title), onBack = onBack) {
            Pill(if (list.isEmpty()) stringResource(R.string.packs_free) else stringResource(R.string.packs_free_count, list.size))
        }
    }, bottom = {
        SecondaryButton(stringResource(R.string.packs_refresh)) { Services.refreshPacks(force = true) }
    }) {
        Text(stringResource(R.string.packs_auto), style = Tokens.Type.body, color = Tokens.Color.secondary)
        RowList(listOf({
            RowItem(stringResource(R.string.settings_packs), stringResource(R.string.packs_switch_note)) {
                androidx.compose.material3.Switch(packsOn, { packsOn = it; settings.packsEnabled = it })
            }
        }))
        if (catalog == null) Text(stringResource(R.string.packs_loading), style = Tokens.Type.body, color = Tokens.Color.secondary)
        else if (list.isEmpty()) NoteTile(stringResource(R.string.packs_none_yet), Tokens.Color.secondary)
        list.chunked(2).forEach { row ->
            Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                row.forEach { entry ->
                    val (code, short) = packShort(entry.id, entry.title)
                    val on = entry.id !in disabled
                    val playing = packInUse != null && packInUse == entry.title
                    PackTile(code, short, linesText(context, entry.entries), Modifier.weight(1f).fillMaxHeight(),
                        style = if (playing) TileStyle.ACTIVE else TileStyle.NORMAL, dim = !unlocked || !on,
                        corner = { if (playing) StatusLabel(stringResource(R.string.packs_now)) else if (unlocked && !on) Pill(stringResource(R.string.packs_off)) },
                        onClick = {
                            disabled = if (on) disabled + entry.id else disabled - entry.id
                            settings.disabledPacks = disabled
                        })
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
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

fun open(context: Context, url: String) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (error: Exception) {
    }
}
