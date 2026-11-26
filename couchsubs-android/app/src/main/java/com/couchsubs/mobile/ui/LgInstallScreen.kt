// SPDX-License-Identifier: AGPL-3.0-only
// CouchSubs'ın LG webOS uygulamasını bu telefondan geliştirici modu (SSH) ile kurmak ve güncellemek (TvInstallScreen'de marka seçimi).
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
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.tv.InstalledTv
import com.couchsubs.mobile.tv.TvAddress
import com.couchsubs.mobile.tv.TvAppUpdate
import com.couchsubs.mobile.tv.TvBrand
import com.couchsubs.mobile.tv.TvDiscovery
import com.couchsubs.mobile.tv.TvPackages
import com.couchsubs.mobile.tv.TvReach
import com.couchsubs.mobile.tv.TvRelocation
import com.couchsubs.mobile.tv.lg.JschShell
import com.couchsubs.mobile.tv.lg.LgInstallError
import com.couchsubs.mobile.tv.lg.LgInstallException
import com.couchsubs.mobile.tv.lg.LgInstaller
import com.couchsubs.mobile.tv.lg.LgKeys
import com.couchsubs.mobile.tv.lg.LgUnreachableReason
import com.couchsubs.mobile.tv.samsung.InstallLog
import com.couchsubs.mobile.tv.samsung.InstallStep
import com.couchsubs.mobile.core.ManualAddress
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
    data class Failed(val error: LgInstallError?, val detail: String?, val reason: LgUnreachableReason? = null) : LgState
}

@Composable
internal fun LgInstallScreen(onBack: () -> Unit, onDone: () -> Unit, brandPicker: @Composable () -> Unit, preset: InstalledTv? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val keys = remember { LgKeys(File(context.noBackupFilesDir, "lg")) }
    val phoneIp = remember { phoneAddress(context) }
    var candidates by remember { mutableStateOf<List<LgCandidate>?>(null) }
    var host by remember { mutableStateOf(preset?.host ?: Services.settings.installedTv?.takeIf { it.brand == TvBrand.LG }?.host ?: "") }
    var manual by remember { mutableStateOf(false) }
    var addressError by remember { mutableStateOf(false) }
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

    // TV'de bu kimlikle başka bir uygulama var: kaldırılıp kurulsun mu diye sorulur (onaysız kaldırılmaz).
    var foreignDialog by remember { mutableStateOf(false) }

    fun install(replaceForeign: Boolean = false) {
        // Elle yazılan adres temizlenir ("192.168.1.5:3000", "http://…", virgüllü yazım); adres değilse söylenir (#50).
        val target = ManualAddress.normalize(host) ?: run {
            addressError = true
            return
        }
        addressError = false
        val typed = passphrase.trim()
        state = LgState.Working(InstallStep.CONNECTING)
        val main = Handler(Looper.getMainLooper())
        scope.launch {
            state = try {
                val (installedAt, result) = withContext(Dispatchers.IO) {
                    val (ipk, name, version) = TvPackages.lg(context) ?: throw LgInstallException(LgInstallError.PACKAGE_MISSING)
                    val log = InstallLog(logFile)
                    fun runAt(at: String): LgInstaller.Result {
                        val progress: (InstallStep) -> Unit = { step -> main.post { if (state is LgState.Working) state = LgState.Working(step) } }
                        fun fresh(): ByteArray {
                            if (typed.isEmpty()) throw LgInstallException(LgInstallError.KEY_REFUSED, "parola yazılmadı")
                            progress(InstallStep.KEY)
                            val key = LgInstaller.decodeKey(LgInstaller.downloadKey(at), typed) { k, p -> JschShell.decryptOtherFormat(k, p) }
                            keys.save(at, key)
                            log.write("Key Server'dan anahtar alındı.")
                            return key
                        }
                        fun attempt(key: ByteArray): LgInstaller.Result {
                            val installer = LgInstaller(JschShell(at, key), progress, log)
                            // TV'de açık uygulamanın sürümü: paket güncel ama bu eskiyse uygulama kapatılıp açılır (beta.89).
                            val result = installer.ensureInstalled(ipk, name, version, replaceForeign, TvAppUpdate.runningVersion)
                            // Masaüstündeki gibi: geliştirici modunun süresi günde bir uzatılır, kullanıcı TV'den uzatmaz.
                            TvAppUpdate.renewLgSessionIfDue(at, installer)
                            return result
                        }
                        val saved = keys.load(at)
                        return if (saved == null) attempt(fresh())
                        else try {
                            attempt(saved)
                        } catch (error: LgInstallException) {
                            // Geliştirici modu yeniden açılınca TV yeni anahtar üretir; eskisi bırakılır, parola yazıldıysa yenisi alınır.
                            if (error.error != LgInstallError.KEY_REFUSED) throw error
                            keys.remove(at)
                            log.write("Kayıtlı anahtar reddedildi; bırakıldı.")
                            attempt(fresh())
                        }
                    }
                    try {
                        target to runAt(target)
                    } catch (error: LgInstallException) {
                        // TV'nin adresi değişmiş olabilir (beta.89: kayıtlı adres sessiz, TV yeni adreste): adres hiç yanıt
                        // vermiyorsa TV ağda yeniden aranır, aynı TV bulunursa kurulum yeni adresle bir kez daha denenir.
                        // "Key Server kapalı" yalnız TV yanıt verip 9991 reddediyorsa gösterilir.
                        if (error.error != LgInstallError.UNREACHABLE && error.error != LgInstallError.KEY_SERVER_OFF) throw error
                        val moved = relocateLg(target, log, keys) ?: throw error
                        main.post { host = moved }
                        moved to runAt(moved)
                    }
                }
                TvAppUpdate.installed(InstalledTv(TvBrand.LG, installedAt, version = result.version))
                LgState.Done(result.version, result.installed)
            } catch (error: LgInstallException) {
                // 9922 yanıt vermediyse neden: TV bu adreste mi, geliştirici modu mu kapalı (diğer portlara bakılır).
                val reason = if (error.error == LgInstallError.UNREACHABLE && error.detail == TvReach.NOT_RESPONDING_LINE) LgUnreachableReason.TV_NOT_FOUND
                else if (error.error != LgInstallError.UNREACHABLE) null else withContext(Dispatchers.IO) {
                    runCatching { LgUnreachableReason.probe(target) }.getOrNull()
                        ?.also { InstallLog(logFile).write("9922 yanıt vermedi; TV'nin durumu: $it") }
                }
                LgState.Failed(error.error, error.detail, reason)
            } catch (error: Exception) {
                Log.w(TAG, "LG kurulumu başarısız", error)
                LgState.Failed(null, error.message ?: error.javaClass.simpleName)
            }
            foreignDialog = (state as? LgState.Failed)?.error == LgInstallError.FOREIGN_APP
        }
    }

    if (foreignDialog) ForeignTvAppDialog(onReplace = {
        foreignDialog = false
        install(replaceForeign = true)
    }, onDismiss = { foreignDialog = false })

    // "TV uygulamasını güncelle"den gelindiyse ve anahtar kayıtlıysa kurulum hemen başlar; değilse parola beklenir.
    LaunchedEffect(preset) { if (preset != null && state is LgState.Idle && hasKey) install() }

    ScreenScaffold(top = { TopBar(onBack = onBack) }, ambient = true, bottom = {
        // Kurulum bitince ana düğme ana ekrana götürür; kurulumda geri düğmesi 3. adıma dönüyor, kullanıcı orada kalıyordu (#113).
        if (state is LgState.Done) PrimaryButton(stringResource(R.string.tvinstall_go_home), onClick = onDone)
        else PrimaryButton(stringResource(if (state is LgState.Failed) R.string.tvinstall_retry else R.string.tvinstall_button),
            enabled = !working && host.isNotBlank() && !TvAddress.isPhoneAddress(host, phoneIp) && (passphrase.isNotBlank() || hasKey),
            busy = working) { install() }
    }) {
        Heading(stringResource(R.string.tvinstall_title), stringResource(R.string.tvinstall_lg_body))
        if (!working) brandPicker()
        NoteTile(stringResource(R.string.tvinstall_lg_supported), Tokens.Color.secondary)

        InstallListTitle(stringResource(R.string.tvinstall_lg_tvs), searching = candidates == null)
        when (val list = candidates) {
            null -> InstallSearching()
            else -> {
                if (list.isEmpty()) InstallEmpty(stringResource(R.string.tvinstall_lg_none))
                list.forEach { tv ->
                    TvCard(tv.name, "LG · ${tv.host}", host == tv.host, status = {
                        StatusChip(stringResource(if (tv.devMode) R.string.tvinstall_dev_on else R.string.tvinstall_dev_off),
                            if (tv.devMode) ChipTone.OK else ChipTone.AMBER)
                    }, onClick = { if (!working) host = tv.host })
                }
            }
        }
        // iPhone ile aynı yer: "TV Listede Yok mu?" listenin hemen altında, alt çubukta yalnız ana düğme.
        if (!manual && !working) GhostButton(stringResource(R.string.tvinstall_not_found)) { manual = true }
        if (addressError) NoteTile(stringResource(R.string.address_invalid))
        if (manual) TvAddressField(host, { host = it.trim(); addressError = false }, phoneIp)
        Field(passphrase, { passphrase = it.trim().uppercase() },
            stringResource(if (hasKey) R.string.tvinstall_lg_passphrase_saved else R.string.tvinstall_lg_passphrase),
            keyboard = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, keyboardType = KeyboardType.Ascii))

        InstallSteps(stringResource(R.string.tvinstall_lg_steps_title), listOf(stringResource(R.string.tvinstall_lg_step1),
            stringResource(R.string.tvinstall_lg_step2), stringResource(R.string.tvinstall_lg_step3), stringResource(R.string.tvinstall_lg_step4)))
        NoticeBox(stringResource(R.string.tvinstall_lg_session_note), NoticeTone.INFO)

        when (val current = state) {
            LgState.Idle -> Unit
            is LgState.Working -> InstallWorking(current.step)
            is LgState.Done -> InstallDone(stringResource(if (current.installed) R.string.tvinstall_done else R.string.tvinstall_up_to_date, current.version))
            is LgState.Failed -> InstallErrorBox(lgFailureText(current), onShareLog = { shareLog(context, logFile) })
        }
    }
}

/**
 * LG kurulumunda adres yanıt vermedi (9922 ya da Key Server): adres hiç yanıt vermiyorsa (bağlantı zaman aşımı, adreste
 * cihaz yok; "reddedildi" yanıttır) TV ağda yeniden aranır. Aynı TV bulunursa kayıtlı TV, LG anahtarı ve günlük yeni
 * adrese geçer, yeni adres döner. TV yanıt veriyorsa null (asıl hata gösterilir); sessiz ve bulunamadıysa
 * "TV bu adreste yanıt vermiyor" hatası fırlatılır. Bloklar.
 */
internal fun relocateLg(target: String, log: InstallLog, keys: LgKeys): String? =
    when (val result = TvRelocation.retarget(target, TvBrand.LG, log, keys)) {
        TvRelocation.Retarget.Responds -> null
        is TvRelocation.Retarget.Moved -> result.host
        TvRelocation.Retarget.Silent -> throw LgInstallException(LgInstallError.UNREACHABLE, TvReach.NOT_RESPONDING_LINE)
    }

/** Ne yapılacağı (masaüstündeki TvAppMessages ile aynı anlam) ve TV'nin verdiği ayrıntı. */
@Composable
private fun lgFailureText(failure: LgState.Failed): String {
    val context = LocalContext.current
    val advice = when (failure.error) {
        LgInstallError.UNREACHABLE -> context.getString(when (failure.reason) {
            LgUnreachableReason.RESTART_NEEDED -> R.string.tvinstall_lg_err_restart_needed
            LgUnreachableReason.DEV_MODE_OFF -> R.string.tvinstall_lg_err_dev_mode_off
            LgUnreachableReason.TV_NOT_FOUND -> R.string.tvinstall_lg_err_tv_not_found
            null -> R.string.tvinstall_lg_err_unreachable
        })
        LgInstallError.KEY_SERVER_OFF -> context.getString(R.string.tvinstall_lg_err_key_server)
        LgInstallError.WRONG_PASSPHRASE -> context.getString(R.string.tvinstall_lg_err_passphrase)
        LgInstallError.KEY_REFUSED -> context.getString(R.string.tvinstall_lg_err_key_refused)
        LgInstallError.NOT_ENOUGH_SPACE -> context.getString(R.string.tvinstall_err_space)
        LgInstallError.CONNECTION_LOST -> context.getString(R.string.tvinstall_err_connection)
        LgInstallError.PACKAGE_MISSING -> context.getString(R.string.tvinstall_err_package_missing)
        LgInstallError.FOREIGN_APP -> return context.getString(R.string.tvinstall_foreign_body)
        LgInstallError.TV_CLOCK_WRONG -> context.getString(R.string.tvinstall_lg_err_clock)
        // "ipk verified failed" (-5): saat yerindeyse de ne yapılacağı söylenir (Mac, iPhone, Windows aynı).
        LgInstallError.INSTALL_FAILED, null -> context.getString(
            if (failure.detail?.let { LgInstaller.isPackageVerifyFailure(it) } == true) R.string.tvinstall_lg_err_verify else R.string.tvinstall_err_failed)
    }
    val detail = failure.detail?.takeIf { it.isNotBlank() && failure.error != LgInstallError.WRONG_PASSPHRASE && it != TvReach.NOT_RESPONDING_LINE } ?: return advice
    return advice + "\n\n" + context.getString(R.string.tvinstall_lg_tv_says, detail)
}
