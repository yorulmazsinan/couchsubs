// SPDX-License-Identifier: AGPL-3.0-only
// Ana ekran (tuval: Telefon-Ana, -Calisiyor, -Tur), oyun paketleri (-Paketler, -Paketler-Kilitli) ve satın alma
// ekranı (-Paywall).
package com.couchsubs.mobile.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.draw.alpha
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
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Account
import com.couchsubs.mobile.account.AdBanner
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.account.Plan
import com.couchsubs.mobile.account.PlanKind
import com.couchsubs.mobile.account.Pricing
import com.couchsubs.mobile.account.PurchaseException
import com.couchsubs.mobile.account.Subscriptions
import com.couchsubs.mobile.account.Telemetry
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.settings.SubtitleTarget
import com.revenuecat.purchases.Package
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
    onPaywall: () -> Unit,
    onProfile: () -> Unit,
    onSettings: () -> Unit,
) {
    val context = LocalContext.current
    val settings = Services.settings
    val access by Subscriptions.access.collectAsState()
    val user by Account.user.collectAsState()
    val bounds = remember { mutableStateMapOf<TourStep, Rect>() }
    var tour by remember { mutableStateOf(if (settings.tourShown) null else TourStep.START) }
    fun mark(step: TourStep) = Modifier.onGloballyPositioned { bounds[step] = it.boundsInRoot() }
    val avatar = initials(user?.name, user?.email)
    val topBar: @Composable () -> Unit = {
        TopBar {
            SettingsAction(onSettings)
            Box(mark(TourStep.PROFILE)) { AvatarAction(avatar, onProfile) }
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
                { SquareTile(Icons.Filled.PlayArrow, "PS5", settings.console?.name ?: stringResource(R.string.profile_not_paired), it,
                    tint = Tokens.Color.success, corner = { if (settings.console != null) LiveDot() }, onClick = onPairing) },
                { SquareTile(if (settings.target == SubtitleTarget.TV) Icons.Filled.Home else Icons.Filled.Phone, stringResource(R.string.main_target),
                    if (settings.target == SubtitleTarget.TV) settings.tvName ?: stringResource(R.string.main_target_tv) else stringResource(R.string.main_target_phone),
                    it.then(mark(TourStep.TARGET)), style = TileStyle.ACTIVE, onClick = onTarget) },
            )
            Box(mark(TourStep.PACKS)) {
                Tile(Modifier.fillMaxWidth(), style = TileStyle.PRO, onClick = if (access.active) onPacks else onPaywall) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        IconBadge(Icons.Filled.Star, Tokens.Color.pro)
                        Column(Modifier.weight(1f)) {
                            Text(stringResource(R.string.main_packs_title), style = Tokens.Type.headline, color = Tokens.Color.text)
                            Text(stringResource(R.string.main_packs_games), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                        Pill(stringResource(if (access.active) R.string.main_packs_on else R.string.main_packs_pro), Tokens.Color.pro)
                    }
                }
            }
            TwoColumns(
                { SquareTile(Icons.Filled.Create, stringResource(R.string.main_engine), status.engineLabel.ifEmpty { engineName(context) }, it, onClick = onSettings) },
                { SquareTile(Icons.Filled.DateRange, stringResource(R.string.main_last_session),
                    if (settings.lastSessionMs > 0) durationText(context, settings.lastSessionMs) else "—", it, tint = Tokens.Color.secondary) },
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
        Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline), verticalAlignment = Alignment.CenterVertically) {
            val elapsed = ((now - status.startedAt).coerceAtLeast(0) / 1000)
            Pill(stringResource(R.string.running_pill, "%d:%02d".format(elapsed / 60, elapsed % 60)), Tokens.Color.success)
            status.packInUse?.let { Pill(stringResource(R.string.running_pack, it), Tokens.Color.pro) }
        }
        Text(status.phase, style = Tokens.Type.caption, color = Tokens.Color.secondary)
        status.error?.let { NoteTile(it) }
        val current = status.recent.firstOrNull()
        Tile(Modifier.fillMaxWidth(), style = TileStyle.ACTIVE) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                LiveDot()
                TileLabel(stringResource(R.string.running_now))
                Spacer(Modifier.weight(1f))
                if (current?.origin == "paket") Pill(stringResource(R.string.running_ready_translation), Tokens.Color.pro)
            }
            Text(current?.translation ?: stringResource(R.string.running_waiting), style = Tokens.Type.subtitleCurrent, color = Tokens.Color.text)
            current?.let { Text(it.source, style = Tokens.Type.body, color = Tokens.Color.secondary) }
        }
        val previous = status.recent.drop(1).take(4)
        if (previous.isNotEmpty()) RowList(previous.mapIndexed { index, pair ->
            {
                Row(Modifier.alpha(if (index == 0) 1f else 0.6f).padding(vertical = Tokens.Space.inline), verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f)) {
                        Text(pair.translation, style = Tokens.Type.headline, color = Tokens.Color.text)
                        Text(pair.source, style = Tokens.Type.caption, color = Tokens.Color.secondary)
                    }
                    if (pair.origin == "paket") Pill(stringResource(R.string.running_ready), Tokens.Color.pro)
                    else Pill(status.engineLabel, Tokens.Color.secondary)
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
                    style = Tokens.Type.title, color = if (status.connectedTvs > 0) Tokens.Color.success else Tokens.Color.text)
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
                Pill("${step.ordinal + 1} / ${TourStep.entries.size}")
                Spacer(Modifier.weight(1f))
                GhostButton(stringResource(R.string.skip), onClick = onSkip)
            }
            Text(stringResource(step.title), style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(step.body), style = Tokens.Type.body, color = Tokens.Color.secondary)
            PrimaryButton(stringResource(if (step == TourStep.PROFILE) R.string.tour_done else R.string.next), onClick = onNext)
        }
    }
}

/** Oyun paketleri: Pro ise etkin (paket başına kapatılabilir), değilse kilitli tanıtım. */
@Composable
fun PacksScreen(onBack: () -> Unit, onPaywall: () -> Unit, packInUse: String?) {
    val context = LocalContext.current
    val settings = Services.settings
    val access by Subscriptions.access.collectAsState()
    val version by Services.packsVersion.collectAsState()
    var catalog by remember { mutableStateOf<List<Services.CatalogEntry>?>(null) }
    var disabled by remember { mutableStateOf(settings.disabledPacks) }
    var debugFree by remember { mutableStateOf(settings.debugFreePacks) }
    var prices by remember { mutableStateOf<List<Plan>>(emptyList()) }
    LaunchedEffect(version) { catalog = withContext(Dispatchers.IO) { Services.catalog(context) } }
    LaunchedEffect(Unit) { prices = runCatching { Subscriptions.plans().map { it.first } }.getOrDefault(emptyList()) }
    val unlocked = access.active || debugFree
    val list = catalog.orEmpty()
    ScreenScaffold(top = {
        TopBar(stringResource(R.string.packs_title), onBack = onBack) { if (unlocked) Pill("Pro", Tokens.Color.pro) }
    }, bottom = {
        if (!unlocked) {
            val monthly = prices.firstOrNull { it.kind == PlanKind.MONTHLY }
            val annual = prices.firstOrNull { it.kind == PlanKind.ANNUAL }
            if (monthly != null && annual?.perMonth != null) Text(stringResource(R.string.packs_price_line, monthly.price, annual.perMonth),
                style = Tokens.Type.caption, color = Tokens.Color.secondary, textAlign = TextAlign.Center)
            ProButton(stringResource(R.string.packs_see_pro), onClick = onPaywall)
        } else SecondaryButton(stringResource(R.string.packs_refresh)) { Services.refreshPacks(force = true) }
    }) {
        if (unlocked) Text(stringResource(R.string.packs_auto), style = Tokens.Type.body, color = Tokens.Color.secondary)
        else Tile(Modifier.fillMaxWidth(), style = TileStyle.PRO) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                IconBadge(Icons.Filled.Lock, Tokens.Color.pro)
                Column {
                    Text(stringResource(R.string.packs_locked_title), style = Tokens.Type.headline, color = Tokens.Color.text)
                    Text(stringResource(R.string.packs_locked_summary, list.size.coerceAtLeast(6), list.sumOf { it.entries }.let { if (it > 0) (it + 500) / 1000 else 517 }),
                        style = Tokens.Type.caption, color = Tokens.Color.secondary)
                }
            }
            Text(stringResource(R.string.packs_free_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        if (catalog == null) Text(stringResource(R.string.paywall_loading), style = Tokens.Type.body, color = Tokens.Color.secondary)
        else if (list.isEmpty()) NoteTile(stringResource(if (unlocked) R.string.packs_none_yet else R.string.packs_list_after), Tokens.Color.secondary)
        list.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                row.forEach { entry ->
                    val (code, short) = packShort(entry.id, entry.title)
                    val on = entry.id !in disabled
                    val playing = packInUse != null && packInUse == entry.title
                    SquareTile(null, "", short, Modifier.weight(1f), code = code, tint = Tokens.Color.pro,
                        style = if (playing) TileStyle.ACTIVE else TileStyle.NORMAL, dim = !unlocked || !on,
                        corner = { if (playing) StatusPill(stringResource(R.string.packs_now), ok = true) else if (unlocked && !on) Pill(stringResource(R.string.packs_off), Tokens.Color.secondary) },
                        note = linesText(context, entry.entries),
                        onClick = if (!unlocked) onPaywall else ({
                            disabled = if (on) disabled + entry.id else disabled - entry.id
                            settings.disabledPacks = disabled
                        }))
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        if (unlocked) Tile(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                IconBadge(Icons.Filled.Refresh, Tokens.Color.secondary)
                Column {
                    Text(stringResource(R.string.packs_next), style = Tokens.Type.headline, color = Tokens.Color.text)
                    Text(stringResource(R.string.packs_next_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                }
            }
        }
        if (BuildConfig.DEBUG) RowList(listOf({
            RowItem(stringResource(R.string.packs_debug_free), stringResource(R.string.packs_debug_free_body)) {
                androidx.compose.material3.Switch(debugFree, { debugFree = it; settings.debugFreePacks = it })
            }
        }))
    }
}

/** Kendi satın alma ekranımız (tuval Telefon-Paywall); ürün ve fiyatlar RevenueCat teklifinden (yerel fiyat Play'den). */
@Composable
fun PaywallScreen(source: String, onClose: () -> Unit, onSignIn: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val user by Account.user.collectAsState()
    val access by Subscriptions.access.collectAsState()
    var plans by remember { mutableStateOf<List<Pair<Plan, Package>>?>(null) }
    var selected by remember { mutableStateOf(PlanKind.ANNUAL) }
    var message by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        Telemetry.event(Telemetry.PAYWALL_VIEW, "source" to source)
        plans = try {
            Subscriptions.plans()
        } catch (error: PurchaseException) {
            message = error.message
            emptyList()
        }
    }
    val needsAccount = Backend.available && user == null
    val chosen = plans?.firstOrNull { it.first.kind == selected } ?: plans?.firstOrNull()
    ScreenScaffold(top = {
        TopBar(onClose = onClose) { Box(Modifier.weight(1f)) { Pill(stringResource(R.string.paywall_badge), Tokens.Color.pro) } }
    }, bottom = {
        when {
            access.active -> PrimaryButton(stringResource(R.string.paywall_active), onClick = onClose)
            !Subscriptions.available || plans?.isEmpty() == true -> ProButton(stringResource(R.string.paywall_soon), enabled = false) {}
            needsAccount -> ProButton(stringResource(R.string.paywall_sign_in), onClick = onSignIn)
            else -> ProButton(stringResource(R.string.paywall_cta), enabled = !busy && chosen != null) {
                val (plan, pkg) = chosen ?: return@ProButton
                busy = true
                scope.launch {
                    try {
                        Subscriptions.purchase(context as Activity, plan, pkg)
                        Services.refreshPacks(force = true)
                        onClose()
                    } catch (error: PurchaseException) {
                        if (!error.cancelled) message = error.message
                    } finally {
                        busy = false
                    }
                }
            }
        }
        Text(stringResource(R.string.paywall_cancel_anytime), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        Row(verticalAlignment = Alignment.CenterVertically) {
            GhostButton(stringResource(R.string.paywall_restore), color = Tokens.Color.secondary) {
                scope.launch {
                    message = try {
                        if (Subscriptions.restore().active) context.getString(R.string.paywall_restored) else context.getString(R.string.paywall_nothing)
                    } catch (error: PurchaseException) {
                        error.message
                    }
                }
            }
            Text("·", color = Tokens.Color.secondary)
            GhostButton(stringResource(R.string.terms_short), color = Tokens.Color.secondary) { open(context, context.getString(R.string.url_terms)) }
            Text("·", color = Tokens.Color.secondary)
            GhostButton(stringResource(R.string.privacy), color = Tokens.Color.secondary) { open(context, context.getString(R.string.url_privacy)) }
        }
    }) {
        Heading(stringResource(R.string.paywall_title), stringResource(R.string.paywall_body))
        TwoColumns(
            { FeatureTile(Icons.Filled.Star, stringResource(R.string.paywall_feature1), it) },
            { FeatureTile(Icons.Filled.PlayArrow, stringResource(R.string.paywall_feature2), it) },
        )
        TwoColumns(
            { FeatureTile(Icons.Filled.Check, stringResource(R.string.paywall_feature3), it) },
            { FeatureTile(Icons.Filled.List, stringResource(R.string.paywall_feature4), it) },
        )
        val list = plans
        when {
            list == null -> Text(stringResource(R.string.paywall_loading), style = Tokens.Type.body, color = Tokens.Color.secondary)
            list.isEmpty() -> NoteTile(stringResource(R.string.paywall_soon_body), Tokens.Color.secondary)
            else -> {
                val monthly = list.firstOrNull { it.first.kind == PlanKind.MONTHLY }?.first
                list.sortedByDescending { it.first.kind == PlanKind.ANNUAL }.forEach { (plan, _) ->
                    PlanTile(plan, plan.kind == selected, monthly) { selected = plan.kind }
                }
            }
        }
        message?.let { NoteTile(it) }
    }
}

@Composable
private fun FeatureTile(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, modifier: Modifier) {
    Tile(modifier) {
        IconBadge(icon, Tokens.Color.pro)
        Text(text, style = Tokens.Type.headline, color = Tokens.Color.text)
    }
}

@Composable
private fun PlanTile(plan: Plan, selected: Boolean, monthly: Plan?, onClick: () -> Unit) {
    Tile(Modifier.fillMaxWidth(), style = if (selected) TileStyle.ACTIVE else TileStyle.NORMAL, onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
            Box(Modifier.background(if (selected) Tokens.Color.accent else Tokens.Color.borderStrong, CircleShape).padding(6.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                    Text(stringResource(if (plan.kind == PlanKind.ANNUAL) R.string.plan_annual else R.string.plan_monthly),
                        style = Tokens.Type.headline, color = Tokens.Color.text)
                    if (plan.kind == PlanKind.ANNUAL && monthly != null)
                        Pill(stringResource(R.string.plan_saving, Pricing.savingPercent(monthly.priceMicros, plan.priceMicros)))
                }
                Text(if (plan.kind == PlanKind.ANNUAL) stringResource(R.string.plan_annual_note, plan.price, plan.perMonth ?: "")
                    else stringResource(R.string.plan_monthly_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
            Text(if (plan.kind == PlanKind.ANNUAL) plan.perMonth ?: plan.price else plan.price, style = Tokens.Type.title, color = Tokens.Color.text)
        }
    }
}

fun open(context: Context, url: String) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (error: Exception) {
    }
}
