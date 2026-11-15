// SPDX-License-Identifier: AGPL-3.0-only
// Deneysel: CouchSubs'ın LG webOS uygulamasını bu telefondan geliştirici modu (SSH) ile kurmak (TvInstallScreen'de marka seçimi).
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
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import com.couchsubs.mobile.R
import com.couchsubs.mobile.tv.TvBrand
import com.couchsubs.mobile.tv.TvDiscovery
import com.couchsubs.mobile.tv.TvPackages
import com.couchsubs.mobile.tv.lg.JschShell
import com.couchsubs.mobile.tv.lg.LgInstallError
import com.couchsubs.mobile.tv.lg.LgInstallException
import com.couchsubs.mobile.tv.lg.LgInstaller
import com.couchsubs.mobile.tv.lg.LgKeys
import com.couchsubs.mobile.tv.samsung.InstallLog
import com.couchsubs.mobile.tv.samsung.InstallStep
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private const val TAG = "CouchSubsTvInstall"

/** Ağda görülen LG TV ve geliştirici modunun (9922) açık olup olmadığı. */
private data class LgCandidate(val host: String, val name: String, val devMode: Boolean)

private sealed interface LgState {
    data object Idle : LgState
    data class Working(val step: InstallStep) : LgState
    data class Done(val version: String, val installed: Boolean) : LgState
    data class Failed(val error: LgInstallError?, val detail: String?) : LgState
}

@Composable
internal fun LgInstallScreen(onBack: () -> Unit, brandPicker: @Composable () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val keys = remember { LgKeys(File(context.noBackupFilesDir, "lg")) }
    var candidates by remember { mutableStateOf<List<LgCandidate>?>(null) }
    var host by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf(false) }
    var passphrase by remember { mutableStateOf("") }
    var state by remember { mutableStateOf<LgState>(LgState.Idle) }
    val working = state is LgState.Working
    val logFile = remember { File(context.filesDir, "tvinstall.log") }
    val hasKey = host.isNotBlank() && keys.load(host.trim()) != null

    LaunchedEffect(Unit) {
        val found = withContext(Dispatchers.IO) {
            val lg = runCatching { TvDiscovery.search() }.getOrDefault(emptyList()).filter { it.brand == TvBrand.LG }
            lg.map { async { LgCandidate(it.host, it.name, LgInstaller.isDevModeOn(it.host)) } }.awaitAll()
        }
        candidates = found
        if (host.isEmpty()) (found.firstOrNull { it.devMode } ?: found.firstOrNull())?.let { host = it.host }
        if (found.isEmpty()) manual = true
    }

    fun install() {
        val target = host.trim()
        val typed = passphrase.trim()
        state = LgState.Working(InstallStep.CONNECTING)
        val main = Handler(Looper.getMainLooper())
        scope.launch {
            state = try {
                val result = withContext(Dispatchers.IO) {
                    val (ipk, name, version) = TvPackages.lg(context) ?: throw LgInstallException(LgInstallError.PACKAGE_MISSING)
                    val log = InstallLog(logFile)
                    val progress: (InstallStep) -> Unit = { step -> main.post { if (state is LgState.Working) state = LgState.Working(step) } }
                    fun fresh(): ByteArray {
                        if (typed.isEmpty()) throw LgInstallException(LgInstallError.KEY_REFUSED, "parola yazılmadı")
                        progress(InstallStep.KEY)
                        val key = LgInstaller.decodeKey(LgInstaller.downloadKey(target), typed) { k, p -> JschShell.decryptOtherFormat(k, p) }
                        keys.save(target, key)
                        log.write("Key Server'dan anahtar alındı.")
                        return key
                    }
                    fun attempt(key: ByteArray) = LgInstaller(JschShell(target, key), progress, log).ensureInstalled(ipk, name, version)
                    val saved = keys.load(target)
                    if (saved == null) attempt(fresh())
                    else try {
                        attempt(saved)
                    } catch (error: LgInstallException) {
                        // Geliştirici modu yeniden açılınca TV yeni anahtar üretir; eskisi bırakılır, parola yazıldıysa yenisi alınır.
                        if (error.error != LgInstallError.KEY_REFUSED) throw error
                        keys.remove(target)
                        log.write("Kayıtlı anahtar reddedildi; bırakıldı.")
                        attempt(fresh())
                    }
                }
                LgState.Done(result.version, result.installed)
            } catch (error: LgInstallException) {
                LgState.Failed(error.error, error.detail)
            } catch (error: Exception) {
                Log.w(TAG, "LG kurulumu başarısız", error)
                LgState.Failed(null, error.message ?: error.javaClass.simpleName)
            }
        }
    }

    ScreenScaffold(top = { TopBar(onBack = onBack) }, bottom = {
        if (!manual && !working) GhostButton(stringResource(R.string.tvinstall_not_found)) { manual = true }
        PrimaryButton(stringResource(if (state is LgState.Failed) R.string.tvinstall_retry else R.string.tvinstall_button),
            enabled = !working && host.isNotBlank() && (passphrase.isNotBlank() || hasKey)) { install() }
    }) {
        Heading(stringResource(R.string.tvinstall_title), stringResource(R.string.tvinstall_lg_body))
        if (!working) brandPicker()
        NoteTile(stringResource(R.string.tvinstall_lg_experimental), Tokens.Color.secondary)

        TileLabel(stringResource(R.string.tvinstall_lg_tvs))
        when (val list = candidates) {
            null -> Tile(Modifier.fillMaxWidth()) { Text(stringResource(R.string.tvinstall_searching), style = Tokens.Type.body, color = Tokens.Color.secondary) }
            else -> {
                if (list.isEmpty()) Tile(Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.tvinstall_lg_none), style = Tokens.Type.body, color = Tokens.Color.secondary)
                }
                list.forEach { tv ->
                    Tile(Modifier.fillMaxWidth(), style = if (host == tv.host) TileStyle.ACTIVE else TileStyle.NORMAL,
                        onClick = { if (!working) host = tv.host }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                            TileIcon(Icons.Filled.Home)
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
                                Text(tv.name, style = Tokens.Type.headline, color = Tokens.Color.text)
                                Text(tv.host, style = Tokens.Type.caption, color = Tokens.Color.secondary)
                                StatusLabel(stringResource(if (tv.devMode) R.string.tvinstall_dev_on else R.string.tvinstall_dev_off), ok = tv.devMode)
                            }
                            if (host == tv.host) SelectedCheck()
                        }
                    }
                }
            }
        }
        if (manual) Field(host, { host = it.trim() }, stringResource(R.string.tvinstall_address),
            keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
        Field(passphrase, { passphrase = it.trim().uppercase() },
            stringResource(if (hasKey) R.string.tvinstall_lg_passphrase_saved else R.string.tvinstall_lg_passphrase),
            keyboard = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, keyboardType = KeyboardType.Ascii))

        Tile(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.tvinstall_lg_steps_title), style = Tokens.Type.headline, color = Tokens.Color.text)
            Text(stringResource(R.string.tvinstall_lg_step1), style = Tokens.Type.body, color = Tokens.Color.secondary)
            Text(stringResource(R.string.tvinstall_lg_step2), style = Tokens.Type.body, color = Tokens.Color.secondary)
            Text(stringResource(R.string.tvinstall_lg_step3), style = Tokens.Type.body, color = Tokens.Color.secondary)
            Text(stringResource(R.string.tvinstall_lg_step4), style = Tokens.Type.body, color = Tokens.Color.secondary)
        }
        Text(stringResource(R.string.tvinstall_lg_session_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)

        when (val current = state) {
            LgState.Idle -> Unit
            is LgState.Working -> Tile(Modifier.fillMaxWidth()) { StatusLabel(stepText(current.step), live = true) }
            is LgState.Done -> Tile(Modifier.fillMaxWidth(), style = TileStyle.ACTIVE) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                    TileIcon(Icons.Filled.Check, Tokens.Color.success)
                    Text(stringResource(if (current.installed) R.string.tvinstall_done else R.string.tvinstall_up_to_date, current.version),
                        style = Tokens.Type.headline, color = Tokens.Color.text)
                }
            }
            is LgState.Failed -> {
                NoteTile(lgFailureText(current))
                GhostButton(stringResource(R.string.tvinstall_share_log)) { shareLog(context, logFile) }
            }
        }
    }
}

/** Ne yapılacağı (masaüstündeki TvAppMessages ile aynı anlam) ve TV'nin verdiği ayrıntı. */
@Composable
private fun lgFailureText(failure: LgState.Failed): String {
    val context = LocalContext.current
    val advice = when (failure.error) {
        LgInstallError.UNREACHABLE -> context.getString(R.string.tvinstall_lg_err_unreachable)
        LgInstallError.KEY_SERVER_OFF -> context.getString(R.string.tvinstall_lg_err_key_server)
        LgInstallError.WRONG_PASSPHRASE -> context.getString(R.string.tvinstall_lg_err_passphrase)
        LgInstallError.KEY_REFUSED -> context.getString(R.string.tvinstall_lg_err_key_refused)
        LgInstallError.NOT_ENOUGH_SPACE -> context.getString(R.string.tvinstall_err_space)
        LgInstallError.CONNECTION_LOST -> context.getString(R.string.tvinstall_err_connection)
        LgInstallError.PACKAGE_MISSING -> context.getString(R.string.tvinstall_err_package_missing)
        LgInstallError.INSTALL_FAILED, null -> context.getString(R.string.tvinstall_err_failed)
    }
    val detail = failure.detail?.takeIf { it.isNotBlank() && failure.error != LgInstallError.WRONG_PASSPHRASE } ?: return advice
    return advice + "\n\n" + context.getString(R.string.tvinstall_lg_tv_says, detail)
}
