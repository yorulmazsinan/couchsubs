// SPDX-License-Identifier: AGPL-3.0-only
// Deneysel: CouchSubs'ın Android TV uygulamasını bu telefondan ADB ile kurmak (TvInstallScreen'de marka seçimi).
package com.couchsubs.mobile.ui

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Home
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
import com.couchsubs.mobile.R
import com.couchsubs.mobile.tv.TvBrand
import com.couchsubs.mobile.tv.TvDiscovery
import com.couchsubs.mobile.tv.TvPackages
import com.couchsubs.mobile.tv.android.AdbConnection
import com.couchsubs.mobile.tv.android.AndroidInstallError
import com.couchsubs.mobile.tv.android.AndroidInstallException
import com.couchsubs.mobile.tv.android.AndroidTvInstaller
import com.couchsubs.mobile.tv.samsung.AdbKey
import com.couchsubs.mobile.tv.samsung.InstallLog
import com.couchsubs.mobile.tv.samsung.InstallStep
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File

private const val TAG = "CouchSubsTvInstall"

/** Ağda görülen Android TV: DIAL'la bulunan ya da 5555'i açık olan. */
private data class AndroidCandidate(val host: String, val name: String, val debugging: Boolean)

private sealed interface AndroidState {
    data object Idle : AndroidState
    data class Working(val step: InstallStep) : AndroidState
    data class Done(val version: String, val installed: Boolean) : AndroidState
    data class Failed(val error: AndroidInstallError?, val detail: String?, val fromPlay: Boolean = false) : AndroidState
}

@Composable
internal fun AndroidTvInstallScreen(onBack: () -> Unit, brandPicker: @Composable () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val phoneIp = remember { phoneAddress(context) }
    var candidates by remember { mutableStateOf<List<AndroidCandidate>?>(null) }
    var address by remember { mutableStateOf("") }
    var wireless by remember { mutableStateOf(false) }
    var pairAddress by remember { mutableStateOf("") }
    var pairCode by remember { mutableStateOf("") }
    var state by remember { mutableStateOf<AndroidState>(AndroidState.Idle) }
    val working = state is AndroidState.Working
    val logFile = remember { File(context.filesDir, "tvinstall.log") }

    LaunchedEffect(Unit) {
        val found = withContext(Dispatchers.IO) { findAndroidTvs(phoneIp) }
        candidates = found
        if (address.isEmpty()) found.firstOrNull { it.debugging }?.let { address = it.host }
    }

    fun install(allowReplace: Boolean = false) {
        val defaultPort = if (wireless) 0 else AdbConnection.DEFAULT_PORT
        val target = AndroidTvInstaller.parseAddress(address, defaultPort)?.takeIf { it.second > 0 }
        if (target == null) {
            state = AndroidState.Failed(AndroidInstallError.UNREACHABLE, context.getString(R.string.tvinstall_android_need_port))
            return
        }
        val code = pairCode.filter { it.isDigit() }
        val pairing = if (wireless && code.isNotEmpty()) {
            // Eşleme penceresindeki adres yazılmadıysa bağlantı adresiyle aynı TV varsayılır.
            val pair = AndroidTvInstaller.parseAddress(pairAddress, 0)?.takeIf { it.second > 0 }
            if (pair == null) {
                state = AndroidState.Failed(AndroidInstallError.PAIRING_FAILED, context.getString(R.string.tvinstall_android_need_pair_port))
                return
            }
            AndroidTvInstaller.Pairing(pair.second, code)
        } else null
        state = AndroidState.Working(if (pairing != null) InstallStep.PAIRING else InstallStep.CONNECTING)
        val main = Handler(Looper.getMainLooper())
        scope.launch {
            state = try {
                val result = withContext(Dispatchers.IO) {
                    val (apk, version) = TvPackages.androidTv(context)
                        ?: throw AndroidInstallException(AndroidInstallError.PACKAGE_MISSING)
                    AndroidTvInstaller(
                        host = target.first,
                        port = target.second,
                        adbKey = { AdbKey.loadOrCreate(File(context.noBackupFilesDir, "adb/adbkey")) },
                        pairing = pairing,
                        progress = { step -> main.post { if (state is AndroidState.Working) state = AndroidState.Working(step) } },
                        log = InstallLog(logFile),
                    ).ensureInstalled({ apk.readBytes() }, version, allowReplace)
                }
                AndroidState.Done(result.version, result.installed)
            } catch (error: AndroidInstallException) {
                AndroidState.Failed(error.error, error.detail, error.installedFromPlay)
            } catch (error: Exception) {
                Log.w(TAG, "Android TV kurulumu başarısız", error)
                AndroidState.Failed(null, error.message ?: error.javaClass.simpleName)
            }
        }
    }

    ScreenScaffold(top = { TopBar(onBack = onBack) }, bottom = {
        PrimaryButton(stringResource(if (state is AndroidState.Failed) R.string.tvinstall_retry else R.string.tvinstall_button),
            enabled = !working && address.isNotBlank()) { install() }
    }) {
        Heading(stringResource(R.string.tvinstall_title), stringResource(R.string.tvinstall_android_body))
        if (!working) brandPicker()
        NoteTile(stringResource(R.string.tvinstall_android_experimental), Tokens.Color.secondary)

        TileLabel(stringResource(R.string.tvinstall_android_tvs))
        when (val list = candidates) {
            null -> Tile(Modifier.fillMaxWidth()) { Text(stringResource(R.string.tvinstall_searching), style = Tokens.Type.body, color = Tokens.Color.secondary) }
            else -> {
                if (list.isEmpty()) Tile(Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.tvinstall_android_none), style = Tokens.Type.body, color = Tokens.Color.secondary)
                }
                list.forEach { tv ->
                    val selected = AndroidTvInstaller.parseAddress(address)?.first == tv.host
                    Tile(Modifier.fillMaxWidth(), style = if (selected) TileStyle.ACTIVE else TileStyle.NORMAL,
                        onClick = { if (!working) address = tv.host }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                            TileIcon(Icons.Filled.Home)
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                                Text(tv.name, style = Tokens.Type.headline, color = Tokens.Color.text)
                                Text(tv.host, style = Tokens.Type.caption, color = Tokens.Color.secondary)
                                StatusLabel(stringResource(if (tv.debugging) R.string.tvinstall_android_debug_on else R.string.tvinstall_android_debug_off),
                                    ok = tv.debugging)
                            }
                            if (selected) SelectedCheck()
                        }
                    }
                }
            }
        }

        TileLabel(stringResource(R.string.tvinstall_android_mode))
        Segmented(listOf(stringResource(R.string.tvinstall_android_mode_network), stringResource(R.string.tvinstall_android_mode_wireless)),
            if (wireless) 1 else 0) { if (!working) wireless = it == 1 }
        Field(address, { address = it.trim() },
            stringResource(if (wireless) R.string.tvinstall_android_address_wireless else R.string.tvinstall_android_address),
            keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
        if (wireless) {
            Field(pairAddress, { pairAddress = it.trim() }, stringResource(R.string.tvinstall_android_pair_address),
                keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
            Field(pairCode, { pairCode = it.filter { c -> c.isDigit() }.take(6) }, stringResource(R.string.tvinstall_android_pair_code),
                keyboard = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
        }

        Tile(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.tvinstall_android_steps_title), style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(R.string.tvinstall_android_step1), style = Tokens.Type.body, color = Tokens.Color.secondary)
            if (wireless) {
                Text(stringResource(R.string.tvinstall_android_wireless_step2), style = Tokens.Type.body, color = Tokens.Color.secondary)
                Text(stringResource(R.string.tvinstall_android_wireless_step3), style = Tokens.Type.body, color = Tokens.Color.secondary)
            } else {
                Text(stringResource(R.string.tvinstall_android_step2), style = Tokens.Type.body, color = Tokens.Color.secondary)
                Text(stringResource(R.string.tvinstall_android_step3), style = Tokens.Type.body, color = Tokens.Color.secondary)
            }
        }

        when (val current = state) {
            AndroidState.Idle -> Unit
            is AndroidState.Working -> Tile(Modifier.fillMaxWidth()) { StatusLabel(stepText(current.step), live = true) }
            is AndroidState.Done -> Tile(Modifier.fillMaxWidth(), style = TileStyle.ACTIVE) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                    TileIcon(Icons.Filled.Check, Tokens.Color.success)
                    Text(stringResource(if (current.installed) R.string.tvinstall_done else R.string.tvinstall_up_to_date, current.version),
                        style = Tokens.Type.headline, color = Tokens.Color.text)
                }
            }
            is AndroidState.Failed -> {
                NoteTile(androidFailureText(current))
                // TV'deki başka imzalı kopya yalnız kullanıcı isterse kaldırılır (TV uygulamasının ayarları da silinir).
                if (current.error == AndroidInstallError.REPLACE_NEEDED)
                    DestructiveButton(stringResource(R.string.tvinstall_android_replace), Modifier.fillMaxWidth()) { install(allowReplace = true) }
                GhostButton(stringResource(R.string.tvinstall_share_log)) { shareLog(context, logFile) }
            }
        }
    }
}

/** Ne yapılacağı (masaüstündeki TvAppMessages ile aynı anlam) ve TV'nin verdiği ayrıntı. */
@Composable
private fun androidFailureText(failure: AndroidState.Failed): String {
    val context = LocalContext.current
    val advice = when (failure.error) {
        AndroidInstallError.UNREACHABLE -> context.getString(R.string.tvinstall_android_err_unreachable)
        AndroidInstallError.NOT_APPROVED -> context.getString(R.string.tvinstall_android_err_not_approved)
        AndroidInstallError.NOT_PAIRED -> context.getString(R.string.tvinstall_android_err_not_paired)
        AndroidInstallError.PAIRING_FAILED -> context.getString(R.string.tvinstall_android_err_pairing)
        AndroidInstallError.REPLACE_NEEDED -> context.getString(
            if (failure.fromPlay) R.string.tvinstall_android_err_play_copy else R.string.tvinstall_android_err_other_copy)
        AndroidInstallError.NOT_ENOUGH_SPACE -> context.getString(R.string.tvinstall_err_space)
        AndroidInstallError.CONNECTION_LOST -> context.getString(R.string.tvinstall_err_connection)
        AndroidInstallError.PACKAGE_MISSING -> context.getString(R.string.tvinstall_err_package_missing)
        AndroidInstallError.INSTALL_FAILED, null -> context.getString(R.string.tvinstall_err_failed)
    }
    // Yeniden kurma önerisinde TV'nin uzun "Failure [...]" metni gösterilmez; günlükte durur.
    if (failure.error == AndroidInstallError.REPLACE_NEEDED) return advice
    val detail = failure.detail?.takeIf { it.isNotBlank() } ?: return advice
    return advice + "\n\n" + context.getString(R.string.tvinstall_details, detail)
}

/** Ağdaki Android TV'ler: SSDP'de DIAL ile görünenler ve ağın /24 bölümünde 5555 portu açık olanlar. */
private suspend fun findAndroidTvs(phoneIp: String?): List<AndroidCandidate> = withContext(Dispatchers.IO) {
    val dial = runCatching { TvDiscovery.search() }.getOrDefault(emptyList()).filter { it.brand == TvBrand.ANDROID_TV }
    val gate = Semaphore(32)
    val open = if (phoneIp == null) emptySet() else {
        val prefix = phoneIp.substringBeforeLast('.')
        (1..254).map { "$prefix.$it" }.filter { it != phoneIp }
            .map { address -> async { gate.withPermit { address.takeIf { AndroidTvInstaller.isReachable(it) } } } }
            .awaitAll().filterNotNull().toSet()
    }
    val named = dial.associate { it.host to it.name }
    (named.keys + open).distinct().map { AndroidCandidate(it, named[it] ?: "Android TV", it in open) }
        .sortedByDescending { it.debugging }
}
