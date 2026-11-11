// SPDX-License-Identifier: AGPL-3.0-only
// Profil, hesap bilgileri, abonelik ve ayarlar (tuval: Telefon-Profil, -Hesap, -Abonelik, -Ayarlar).
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.BuildConfig
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.account.Account
import com.couchsubs.mobile.account.AccountException
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.account.ConsentChoice
import com.couchsubs.mobile.account.Plan
import com.couchsubs.mobile.account.PlanKind
import com.couchsubs.mobile.account.Subscriptions
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.settings.EngineChoice
import com.couchsubs.mobile.settings.SubtitleTarget
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

private fun formatDate(millis: Long): String = DateFormat.getDateInstance(DateFormat.LONG).format(Date(millis))

@Composable
fun ProfileScreen(
    onBack: () -> Unit, onSettings: () -> Unit, onAccount: () -> Unit, onSubscription: () -> Unit, onDevices: () -> Unit,
    onPsn: () -> Unit, onPrivacy: () -> Unit, onSignIn: () -> Unit, onSignedOut: () -> Unit,
) {
    val context = LocalContext.current
    val settings = Services.settings
    val user by Account.user.collectAsState()
    val access by Subscriptions.access.collectAsState()
    ScreenScaffold(top = { TopBar(stringResource(R.string.profile), onBack = onBack) { SettingsAction(onSettings) } }, bottom = {
        if (user != null) DestructiveButton(stringResource(R.string.profile_sign_out)) {
            Account.signOut()
            onSignedOut()
        } else if (Backend.available) PrimaryButton(stringResource(R.string.auth_sign_in), onClick = onSignIn)
    }) {
        Tile(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                Box(Modifier.size(56.dp).background(Tokens.Color.surface2, CircleShape).border(1.dp, Tokens.Color.accent.copy(alpha = 0.45f), CircleShape),
                    contentAlignment = Alignment.Center) { Text(initials(user?.name, user?.email), style = Tokens.Type.title, color = Tokens.Color.accent) }
                Column(Modifier.weight(1f)) {
                    Text(user?.name?.takeIf { it.isNotBlank() } ?: stringResource(R.string.profile_no_name), style = Tokens.Type.title, color = Tokens.Color.text)
                    Text(user?.email ?: stringResource(if (Backend.available) R.string.profile_signed_out else R.string.auth_unavailable_short),
                        style = Tokens.Type.caption, color = Tokens.Color.secondary)
                }
                if (access.active) Pill(stringResource(if (access.plan == PlanKind.MONTHLY) R.string.profile_pro_monthly else R.string.profile_pro_annual), Tokens.Color.pro)
            }
        }
        TwoColumns(
            { SquareTile(Icons.Filled.Home, stringResource(R.string.profile_devices),
                stringResource(R.string.profile_devices_value, if (settings.console != null) 1 else 0, if (settings.target == SubtitleTarget.TV && settings.tvName != null) 1 else 0),
                it, onClick = onDevices) },
            { SquareTile(Icons.Filled.Person, stringResource(R.string.profile_psn),
                stringResource(if (settings.accountId != null) R.string.profile_psn_linked_short else R.string.profile_psn_missing), it,
                tint = Tokens.Color.success, onClick = onPsn) },
        )
        RowList(listOf(
            { RowItem(stringResource(R.string.profile_account_info), onClick = onAccount) },
            { RowItem(stringResource(R.string.profile_subscription), access.expiresAtMillis?.let { formatDate(it) }
                ?: stringResource(if (access.active) R.string.profile_pro_active else R.string.profile_free), onClick = onSubscription) },
            { RowItem(stringResource(R.string.profile_notifications), onClick = onAccount) },
            { RowItem(stringResource(R.string.profile_privacy), onClick = onPrivacy) },
            { RowItem(stringResource(R.string.profile_help), onClick = { open(context, context.getString(R.string.url_help)) }) },
        ))
    }
}

private enum class Edit { EMAIL, PASSWORD, DELETE }

/** Hesap bilgileri (tuval Telefon-Hesap): ad, e-posta, şifre; bildirim ve veri tercihleri; hesabı sil. */
@Composable
fun AccountScreen(onBack: () -> Unit, onDeleted: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings = Services.settings
    val user by Account.user.collectAsState()
    var name by remember(user?.name) { mutableStateOf(user?.name ?: "") }
    var edit by remember { mutableStateOf<Edit?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var notify by remember { mutableStateOf(settings.notifyNewPacks) }
    var pool by remember { mutableStateOf(settings.sharePool) }
    var usage by remember { mutableStateOf(settings.consent.analytics) }
    val errors = accountErrors()
    ScreenScaffold(top = { TopBar(stringResource(R.string.profile_account_info), onBack = onBack) }, bottom = {
        PrimaryButton(stringResource(R.string.save), enabled = user != null && name.isNotBlank() && name != user?.name) {
            scope.launch { message = runAccount(errors, context.getString(R.string.profile_saved)) { Account.updateName(name) } }
        }
    }) {
        if (user != null) Tile(Modifier.fillMaxWidth()) {
            Field(name, { name = it }, stringResource(R.string.profile_name))
            RowItem(stringResource(R.string.auth_email), user?.email ?: "—", onClick = { edit = Edit.EMAIL }) {
                if (user?.emailVerified == true) StatusPill(stringResource(R.string.profile_verified), ok = true)
            }
            if (user?.hasPassword == true) RowItem(stringResource(R.string.profile_password), onClick = { edit = Edit.PASSWORD }) {
                Text(stringResource(R.string.profile_change), style = Tokens.Type.headline, color = Tokens.Color.accent)
            }
        }
        RowList(listOf(
            { RowItem(stringResource(R.string.profile_notifications), stringResource(R.string.notify_packs)) {
                Switch(notify, { notify = it; settings.notifyNewPacks = it; settings.notifyDisconnect = it })
            } },
            { RowItem(stringResource(R.string.settings_pool), stringResource(R.string.settings_pool_short)) {
                Switch(pool, { pool = it; settings.sharePool = it })
            } },
            { RowItem(stringResource(R.string.profile_usage), stringResource(R.string.profile_usage_note)) {
                Switch(usage, { usage = it; Services.setConsent(ConsentChoice(true, it, settings.consent.ads)) })
            } },
        ))
        if (user != null) Tile(Modifier.fillMaxWidth(), onClick = { edit = Edit.DELETE }) {
            Text(stringResource(R.string.profile_delete), style = Tokens.Type.headline, color = Tokens.Color.danger)
            Text(stringResource(R.string.profile_delete_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        message?.let { NoteTile(it, Tokens.Color.secondary) }
    }

    when (edit) {
        Edit.EMAIL -> TextDialog(stringResource(R.string.profile_new_email), "", needsPassword = user?.hasPassword == true,
            keyboard = KeyboardType.Email, onDismiss = { edit = null }) { value, password ->
            scope.launch { message = runAccount(errors, context.getString(R.string.profile_email_sent)) { Account.changeEmail(value, password) } }
        }
        Edit.PASSWORD -> TextDialog(stringResource(R.string.profile_new_password), "", needsPassword = true, secret = true,
            onDismiss = { edit = null }) { value, password ->
            scope.launch { message = runAccount(errors, context.getString(R.string.profile_password_changed)) { Account.changePassword(password ?: "", value) } }
        }
        Edit.DELETE -> DeleteDialog(needsPassword = user?.hasPassword == true, onDismiss = { edit = null }) { password ->
            scope.launch {
                try {
                    Services.deleteAccount(password)
                    onDeleted()
                } catch (error: AccountException) {
                    message = errors(error.reason)
                }
            }
        }
        null -> {}
    }
}

/** Abonelik (tuval Telefon-Abonelik): durum, plan, yenileme; plan değiştirme ve iptal Google Play'den. */
@Composable
fun SubscriptionScreen(onBack: () -> Unit, onPaywall: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val access by Subscriptions.access.collectAsState()
    var plans by remember { mutableStateOf<List<Plan>>(emptyList()) }
    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { plans = runCatching { Subscriptions.plans().map { it.first } }.getOrDefault(emptyList()) }
    val current = plans.firstOrNull { it.kind == (access.plan ?: PlanKind.ANNUAL) }
    val other = plans.firstOrNull { it.kind != (access.plan ?: PlanKind.ANNUAL) }
    ScreenScaffold(top = { TopBar(stringResource(R.string.profile_subscription), onBack = onBack) }, bottom = {
        GhostButton(stringResource(R.string.paywall_restore)) {
            scope.launch {
                message = try {
                    if (Subscriptions.restore().active) context.getString(R.string.paywall_restored) else context.getString(R.string.paywall_nothing)
                } catch (error: Exception) {
                    error.message
                }
            }
        }
        if (access.active) {
            SecondaryButton(stringResource(R.string.subscription_manage)) { open(context, Subscriptions.manageUrl(context, access.plan)) }
            Text(stringResource(R.string.subscription_cancel_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        } else ProButton(stringResource(R.string.paywall_cta), onClick = onPaywall)
    }) {
        Tile(Modifier.fillMaxWidth(), style = if (access.active) TileStyle.PRO else TileStyle.NORMAL) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                Pill(stringResource(if (access.active) R.string.profile_pro_active else R.string.profile_free), Tokens.Color.pro)
                if (access.active) Text("Google Play", style = Tokens.Type.caption, color = Tokens.Color.secondary)
            }
            if (access.active) {
                Text(stringResource(if (access.plan == PlanKind.MONTHLY) R.string.subscription_monthly else R.string.subscription_annual),
                    style = Tokens.Type.title, color = Tokens.Color.text)
                current?.let {
                    Text(if (it.kind == PlanKind.ANNUAL) stringResource(R.string.plan_annual_note, it.price, it.perMonth ?: "") else it.price + stringResource(R.string.per_month),
                        style = Tokens.Type.caption, color = Tokens.Color.secondary)
                }
                access.expiresAtMillis?.let {
                    RowItem(stringResource(if (access.willRenew) R.string.subscription_renewal else R.string.subscription_ends), formatDate(it))
                }
            } else Text(stringResource(R.string.subscription_free_body), style = Tokens.Type.body, color = Tokens.Color.secondary)
        }
        RowList(listOf(R.string.subscription_benefit1, R.string.subscription_benefit2, R.string.subscription_benefit3).map { id ->
            { RowItem("✓  " + stringResource(id)) }
        })
        if (access.active && other != null) Tile(Modifier.fillMaxWidth(), onClick = { open(context, Subscriptions.manageUrl(context, access.plan)) }) {
            Text(stringResource(if (other.kind == PlanKind.MONTHLY) R.string.subscription_to_monthly else R.string.subscription_to_annual),
                style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(R.string.subscription_switch_note, other.price + stringResource(if (other.kind == PlanKind.MONTHLY) R.string.per_month else R.string.per_year)),
                style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        message?.let { NoteTile(it, Tokens.Color.secondary) }
    }
}

private suspend fun runAccount(errors: (AccountException.Reason) -> String, success: String? = null, block: suspend () -> Unit): String? = try {
    block()
    success
} catch (error: AccountException) {
    errors(error.reason)
}

@Composable
private fun TextDialog(
    title: String, initial: String, needsPassword: Boolean = false, secret: Boolean = false,
    keyboard: KeyboardType = KeyboardType.Text, onDismiss: () -> Unit, onSave: (String, String?) -> Unit,
) {
    var value by remember { mutableStateOf(initial) }
    var password by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = Tokens.Color.surface2,
        title = { Text(title, style = Tokens.Type.headline, color = Tokens.Color.text) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                Field(value, { value = it }, title, secret = secret, keyboard = KeyboardOptions(keyboardType = keyboard))
                if (needsPassword) Field(password, { password = it }, stringResource(R.string.profile_current_password), secret = true)
            }
        },
        confirmButton = {
            TextButton({ onSave(value, if (needsPassword) password else null); onDismiss() }, enabled = value.isNotBlank()) {
                Text(stringResource(R.string.save), color = Tokens.Color.accent)
            }
        },
        dismissButton = { TextButton(onDismiss) { Text(stringResource(R.string.cancel), color = Tokens.Color.secondary) } },
    )
}

@Composable
private fun DeleteDialog(needsPassword: Boolean, onDismiss: () -> Unit, onDelete: (String?) -> Unit) {
    var password by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = Tokens.Color.surface2,
        title = { Text(stringResource(R.string.profile_delete), style = Tokens.Type.headline, color = Tokens.Color.danger) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                Text(stringResource(R.string.profile_delete_body), style = Tokens.Type.body, color = Tokens.Color.secondary)
                if (needsPassword) Field(password, { password = it }, stringResource(R.string.profile_current_password), secret = true)
            }
        },
        confirmButton = {
            TextButton({ onDelete(if (needsPassword) password else null); onDismiss() }, enabled = !needsPassword || password.isNotEmpty()) {
                Text(stringResource(R.string.profile_delete_confirm), color = Tokens.Color.danger)
            }
        },
        dismissButton = { TextButton(onDismiss) { Text(stringResource(R.string.cancel), color = Tokens.Color.secondary) } },
    )
}

/** Ayarlar (tuval Telefon-Ayarlar): motor ve anahtar, altyazı görünümü, paketler, hedef, PS5, hakkında. */
@Composable
fun SettingsScreen(onBack: () -> Unit, onPacks: () -> Unit, onTarget: () -> Unit, onPairing: () -> Unit) {
    val context = LocalContext.current
    val settings = Services.settings
    val access by Subscriptions.access.collectAsState()
    var engine by remember { mutableStateOf(settings.engine) }
    var key by remember(engine) { mutableStateOf(settings.apiKey(engine) ?: "") }
    var scale by remember { mutableStateOf(settings.subtitleScale.toFloat()) }
    var color by remember { mutableStateOf(settings.textColor) }
    var screenOn by remember { mutableStateOf(settings.keepScreenOn) }
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
                    if (key.isNotBlank()) StatusPill(stringResource(R.string.settings_key_saved), ok = true)
                }
                Field(key, { key = it; settings.setApiKey(engine, it) }, stringResource(R.string.settings_key), secret = true)
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
                colors = SliderDefaults.colors(thumbColor = Tokens.Color.accent, activeTrackColor = Tokens.Color.accent))
            Text(stringResource(R.string.settings_preview), style = Tokens.Type.subtitleCurrent.copy(fontSize = Tokens.Type.subtitleCurrent.fontSize * (scale / 100f)),
                color = if (color == SubtitleTextColor.YELLOW) Tokens.Color.accent else Tokens.Color.text)
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
            RowItem(stringResource(R.string.settings_screen_on)) { Switch(screenOn, { screenOn = it; settings.keepScreenOn = it }) }
        }
        RowList(listOf(
            { RowItem(stringResource(R.string.settings_packs), onClick = onPacks) { Pill(if (access.active) stringResource(R.string.main_packs_on) else "Pro", Tokens.Color.pro) } },
            { RowItem(stringResource(R.string.settings_target), if (settings.target == SubtitleTarget.TV) settings.tvName ?: stringResource(R.string.main_target_tv)
                else stringResource(R.string.main_target_phone), onClick = onTarget) },
            { RowItem(stringResource(R.string.settings_ps5), settings.console?.name ?: stringResource(R.string.profile_not_paired), onClick = onPairing) },
            { RowItem(stringResource(R.string.settings_about), BuildConfig.VERSION_NAME, onClick = { open(context, context.getString(R.string.url_source)) }) },
        ))
        Text(stringResource(R.string.settings_copyright), style = Tokens.Type.caption, color = Tokens.Color.secondary,
            modifier = Modifier.padding(top = Tokens.Space.inline))
    }
}

