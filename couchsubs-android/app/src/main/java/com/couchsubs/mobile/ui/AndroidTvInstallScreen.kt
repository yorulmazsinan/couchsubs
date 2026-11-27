// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs'ın Android TV uygulamasını bu telefondan ADB ile kurmak ve güncellemek (TvInstallScreen'de marka seçimi).
package com.couchsubs.mobile.ui

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
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
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.tv.InstalledTv
import com.couchsubs.mobile.tv.TvAddress
import com.couchsubs.mobile.tv.TvAppUpdate
import com.couchsubs.mobile.tv.TvBrand
import com.couchsubs.mobile.tv.TvDiscovery
import com.couchsubs.mobile.tv.TvPackages
import com.couchsubs.mobile.tv.TvRelocation
import com.couchsubs.mobile.tv.android.AdbConnection
import com.couchsubs.mobile.tv.android.AdbMode
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

/** Ağda görülen Android TV: DIAL'la bulunan ya da eski tip ADB portu 5555'i açık olan. */
private data class AndroidCandidate(val host: String, val name: String, val legacyAdbReachable: Boolean)

private sealed interface AndroidState {
    data object Idle : AndroidState
    data class Working(val step: InstallStep) : AndroidState
    data class Done(val version: String, val installed: Boolean) : AndroidState
    data class Failed(val error: AndroidInstallError?, val detail: String?, val fromPlay: Boolean = false, val notResponding: Boolean = false) : AndroidState
}

@Composable
internal fun AndroidTvInstallScreen(onBack: () -> Unit, onDone: () -> Unit, brandPicker: @Composable () -> Unit, preset: InstalledTv? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val phoneIp = remember { phoneAddress(context) }
    var candidates by remember { mutableStateOf<List<AndroidCandidate>?>(null) }
    val known = preset ?: Services.settings.installedTv?.takeIf { it.brand == TvBrand.ANDROID_TV }
    var address by remember {
        mutableStateOf(known?.let { if (it.port > 0 && it.port != AdbConnection.DEFAULT_PORT) "${it.host}:${it.port}" else it.host } ?: "")
    }
    var wireless by remember { mutableStateOf(false) }
    var pairAddress by remember { mutableStateOf("") }
    var pairCode by remember { mutableStateOf("") }
    var state by remember { mutableStateOf<AndroidState>(AndroidState.Idle) }
    val working = state is AndroidState.Working
    val logFile = remember { File(context.filesDir, "tvinstall.log") }

    // Tanı: "IP ve port kutusuna dokununca klavye açılmıyor" (X, 27 Kas; iPhone ile aynı satırlar). Klavyenin açılıp
    // kapandığı ve seçilen hata ayıklama türü tvinstall.log'a yazılır.
    @OptIn(ExperimentalLayoutApi::class)
    val imeVisible = WindowInsets.isImeVisible
    var imeLogged by remember { mutableStateOf(false) }
    LaunchedEffect(imeVisible) {
        if (imeVisible || imeLogged) withContext(Dispatchers.IO) { InstallLog(logFile).write("TV kurulumu: klavye ${if (imeVisible) "açıldı" else "kapandı"}") }
        if (imeVisible) imeLogged = true
    }
    LaunchedEffect(wireless) {
        withContext(Dispatchers.IO) {
            InstallLog(logFile).write("TV kurulumu (Android TV): ${if (wireless) "kablosuz hata ayıklama" else "ağ üzerinden hata ayıklama"} seçildi")
        }
    }

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { InstallLog(logFile).write("TV kurulumu (Android TV): ekran açıldı") }
        val found = withContext(Dispatchers.IO) { findAndroidTvs(phoneIp) }
        candidates = found
        if (address.isEmpty()) {
            // 5555'i açık TV yoksa ağda bulunan ilk TV seçilir ve kablosuz hata ayıklama sekmesi açılır (GitHub #478).
            (found.firstOrNull { it.legacyAdbReachable } ?: found.firstOrNull())?.let {
                address = it.host
                wireless = AdbMode.prefersWireless(it.legacyAdbReachable)
            }
        }
    }

    // 5555'e bağlanılamadı: kablosuz hata ayıklama sekmesine geçilir, TV'nin adresi kalır (port TV'den yazılır).
    fun switchToWireless() {
        wireless = true
        address = AdbMode.hostOnly(address)
        state = AndroidState.Idle
    }

    // TV'de bu kimlikle başka bir uygulama var: kaldırılıp kurulsun mu diye sorulur (onaysız kaldırılmaz).
    var foreignDialog by remember { mutableStateOf(false) }

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
                val (installedAt, result) = withContext(Dispatchers.IO) {
                    val (apk, version) = TvPackages.androidTv(context)
                        ?: throw AndroidInstallException(AndroidInstallError.PACKAGE_MISSING)
                    fun runAt(at: String) = AndroidTvInstaller(
                        host = at,
                        port = target.second,
                        adbKey = { AdbKey.loadOrCreate(File(context.noBackupFilesDir, "adb/adbkey")) },
                        pairing = pairing,
                        progress = { step -> main.post { if (state is AndroidState.Working) state = AndroidState.Working(step) } },
                        log = InstallLog(logFile),
                        // Play'de herkese açıksa ve TV'de Play Store varsa TV'de Play sayfası açılır.
                        playListed = { AndroidTvInstaller.isListedOnPlay() },
                    ).ensureInstalled({ apk.readBytes() }, version, allowReplace)
                    try {
                        target.first to runAt(target.first)
                    } catch (error: AndroidInstallException) {
                        // TV'nin adresi değişmiş olabilir: adres hiç yanıt vermiyorsa TV ağda yeniden aranır (LG, Samsung ile
                        // aynı). Kablosuz hata ayıklamada kapı her açılışta değiştiği için yeni adreste kapı TV'den yazılır.
                        if (error.error != AndroidInstallError.UNREACHABLE) throw error
                        when (val moved = TvRelocation.retarget(target.first, TvBrand.ANDROID_TV, InstallLog(logFile))) {
                            TvRelocation.Retarget.Responds -> throw error
                            TvRelocation.Retarget.Silent -> throw TvNotRespondingException()
                            is TvRelocation.Retarget.Moved -> {
                                main.post { address = moved.host }
                                if (wireless) throw error
                                moved.host to runAt(moved.host)
                            }
                        }
                    }
                }
                TvAppUpdate.installed(InstalledTv(TvBrand.ANDROID_TV, installedAt, target.second, result.version))
                AndroidState.Done(result.version, result.installed)
            } catch (error: TvNotRespondingException) {
                AndroidState.Failed(AndroidInstallError.UNREACHABLE, null, notResponding = true)
            } catch (error: AndroidInstallException) {
                AndroidState.Failed(error.error, error.detail, error.installedFromPlay)
            } catch (error: Exception) {
                Log.w(TAG, "Android TV kurulumu başarısız", error)
                AndroidState.Failed(null, error.message ?: error.javaClass.simpleName)
            }
            foreignDialog = (state as? AndroidState.Failed)?.error == AndroidInstallError.FOREIGN_APP
        }
    }

    if (foreignDialog) ForeignTvAppDialog(onReplace = {
        foreignDialog = false
        install(allowReplace = true)
    }, onDismiss = { foreignDialog = false })

    // "TV uygulamasını güncelle"den gelindiyse kurulum hemen başlar (kullanıcı ana ekranda onayladı).
    LaunchedEffect(preset) { if (preset != null && state is AndroidState.Idle && address.isNotBlank()) install() }

    ScreenScaffold(top = { TopBar(onBack = onBack) }, ambient = true, bottom = {
        if (state is AndroidState.Done) PrimaryButton(stringResource(R.string.tvinstall_go_home), onClick = onDone)
        else PrimaryButton(stringResource(if (state is AndroidState.Failed) R.string.tvinstall_retry else R.string.tvinstall_button),
            enabled = !working && address.isNotBlank() && !TvAddress.isPhoneAddress(address, phoneIp), busy = working) { install() }
    }) {
        Heading(stringResource(R.string.tvinstall_title), stringResource(R.string.tvinstall_android_body))
        if (!working) brandPicker()
        NoteTile(stringResource(R.string.tvinstall_android_supported), Tokens.Color.secondary)

        InstallListTitle(stringResource(R.string.tvinstall_android_tvs), searching = candidates == null)
        when (val list = candidates) {
            null -> InstallSearching()
            else -> {
                if (list.isEmpty()) InstallEmpty(stringResource(R.string.tvinstall_android_none))
                list.forEach { tv ->
                    val selected = AndroidTvInstaller.parseAddress(address)?.first == tv.host
                    TvCard(tv.name, "Android TV · ${tv.host}", selected, status = {
                        StatusChip(stringResource(if (tv.legacyAdbReachable) R.string.tvinstall_android_debug_on else R.string.tvinstall_android_debug_off),
                            if (tv.legacyAdbReachable) ChipTone.OK else ChipTone.AMBER)
                    }, onClick = {
                        if (!working) {
                            address = tv.host
                            wireless = AdbMode.prefersWireless(tv.legacyAdbReachable)
                        }
                    })
                }
            }
        }

        TileLabel(stringResource(R.string.tvinstall_android_mode))
        Segmented(listOf(stringResource(R.string.tvinstall_android_mode_network), stringResource(R.string.tvinstall_android_mode_wireless)),
            if (wireless) 1 else 0) { if (!working) wireless = it == 1 }
        TvAddressField(address, { address = it.trim() }, phoneIp,
            label = stringResource(if (wireless) R.string.tvinstall_android_address_wireless else R.string.tvinstall_android_address),
            placeholder = if (wireless) null else stringResource(R.string.tvinstall_address_example))
        if (wireless) {
            Field(pairAddress, { pairAddress = it.trim() }, stringResource(R.string.tvinstall_android_pair_address),
                keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
            Field(pairCode, { pairCode = it.filter { c -> c.isDigit() }.take(6) }, stringResource(R.string.tvinstall_android_pair_code),
                keyboard = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
        }

        InstallSteps(stringResource(R.string.tvinstall_android_steps_title), listOf(stringResource(R.string.tvinstall_android_step1)) +
            if (wireless) listOf(stringResource(R.string.tvinstall_android_wireless_step2), stringResource(R.string.tvinstall_android_wireless_step3))
            else listOf(stringResource(R.string.tvinstall_android_step2), stringResource(R.string.tvinstall_android_step3)))

        when (val current = state) {
            AndroidState.Idle -> Unit
            is AndroidState.Working -> InstallWorking(current.step)
            is AndroidState.Done -> InstallDone(stringResource(if (current.installed) R.string.tvinstall_done else R.string.tvinstall_up_to_date, current.version))
            is AndroidState.Failed -> {
                // Eskiden yalnız genel "TV yanıt vermedi" yazısı vardı; 5555 kapalı TV'de çözüm kablosuz hata ayıklamadır.
                val wirelessFix = !current.notResponding && AdbMode.offersWireless(wireless, current.error)
                InstallErrorBox(if (wirelessFix) stringResource(R.string.tvinstall_android_err_legacy_closed) else androidFailureText(current),
                    onShareLog = { shareLog(context, logFile) }) {
                    if (wirelessFix) SecondaryButton(stringResource(R.string.tvinstall_android_try_wireless), Modifier.fillMaxWidth()) { switchToWireless() }
                    // TV'deki başka imzalı kopya yalnız kullanıcı isterse kaldırılır (TV uygulamasının ayarları da silinir).
                    if (current.error == AndroidInstallError.REPLACE_NEEDED)
                        DestructiveButton(stringResource(R.string.tvinstall_android_replace), Modifier.fillMaxWidth()) { install(allowReplace = true) }
                }
            }
        }
    }
}

/** Ne yapılacağı (masaüstündeki TvAppMessages ile aynı anlam) ve TV'nin verdiği ayrıntı. */
@Composable
private fun androidFailureText(failure: AndroidState.Failed): String {
    val context = LocalContext.current
    if (failure.notResponding) return context.getString(R.string.tv_not_responding)
    val advice = when (failure.error) {
        AndroidInstallError.UNREACHABLE -> context.getString(R.string.tvinstall_android_err_unreachable)
        AndroidInstallError.NOT_APPROVED -> context.getString(R.string.tvinstall_android_err_not_approved)
        AndroidInstallError.NOT_PAIRED -> context.getString(R.string.tvinstall_android_err_not_paired)
        AndroidInstallError.PAIRING_FAILED -> context.getString(R.string.tvinstall_android_err_pairing)
        AndroidInstallError.REPLACE_NEEDED -> context.getString(
            if (failure.fromPlay) R.string.tvinstall_android_err_play_copy else R.string.tvinstall_android_err_other_copy)
        AndroidInstallError.FOREIGN_APP -> return context.getString(R.string.tvinstall_foreign_body)
        AndroidInstallError.NOT_ENOUGH_SPACE -> context.getString(R.string.tvinstall_err_space)
        AndroidInstallError.CONNECTION_LOST -> context.getString(R.string.tvinstall_err_connection)
        AndroidInstallError.PACKAGE_MISSING -> context.getString(R.string.tvinstall_err_package_missing)
        // Kaldırıp kurma denendi ama TV eski kopyayı kaldırmadı (imza yine tutmuyor): kullanıcı TV'de elle kaldırır.
        AndroidInstallError.INSTALL_FAILED -> context.getString(
            if (mustRemoveOnTv(failure)) R.string.tvinstall_android_err_remove_manually else R.string.tvinstall_err_failed)
        null -> context.getString(R.string.tvinstall_err_failed)
    }
    // Yeniden kurma önerisinde TV'nin uzun "Failure [...]" metni gösterilmez; günlükte durur.
    if (failure.error == AndroidInstallError.REPLACE_NEEDED || mustRemoveOnTv(failure)) return advice
    val detail = failure.detail?.takeIf { it.isNotBlank() } ?: return advice
    return advice + "\n\n" + context.getString(R.string.tvinstall_details, detail)
}

/**
 * Kaldırıp kurmadan sonra da TV "imza tutmuyor" dedi: `pm uninstall` TV'de işe yaramadı. 0.9.18 ve önceki TV paketleri
 * her derlemede değişen geliştirme anahtarıyla imzalıydı; bunlar yalnız kaldırılıp yeniden kurularak güncellenir.
 */
private fun mustRemoveOnTv(failure: AndroidState.Failed) =
    failure.error == AndroidInstallError.INSTALL_FAILED && AndroidTvInstaller.needsReplace(failure.detail.orEmpty())

/** Ağdaki Android TV'ler: SSDP'de DIAL ile görünenler ve ağın /24 bölümünde TCP 5555'i yanıtlayanlar. */
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
        .sortedByDescending { it.legacyAdbReachable }
}
