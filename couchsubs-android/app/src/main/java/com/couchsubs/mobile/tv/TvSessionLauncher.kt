// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.core.SubtitleAccess
import okhttp3.*
import org.json.JSONObject
import org.json.JSONArray
import java.net.InetAddress
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/** iPhone/Windows ile aynı oturum teslimi. Android TV yalnız kullanıcı onaylı /pair yolunu kullanır. */
object TvSessionLauncher {
    const val SAMSUNG_APP_ID = "CouchSubsT.CouchSubs"

    /**
     * Samsung'da `actionType` TV'nin uygulama listesinde bildirdiği türe göre seçilir ([samsungActionType]); bilinmiyorsa
     * DEEP_LINK.
     */
    fun launchMessage(brand: TvBrand, server: String, key: String, actionType: String = "DEEP_LINK"): String {
        val params = JSONObject().put("server", server).put("key", key)
        return if (brand == TvBrand.LG) JSONObject().put("type", "request").put("id", "launch_1")
            .put("uri", "ssap://system.launcher/launch").put("payload", JSONObject().put("id", "com.couchsubs.tv").put("params", params)).toString()
        else JSONObject().put("method", "ms.channel.emit").put("params", JSONObject().put("event", "ed.apps.launch").put("to", "host")
            .put("data", JSONObject().put("appId", SAMSUNG_APP_ID).put("action_type", actionType).put("metaTag", params.toString()))).toString()
    }

    /**
     * Samsung TV'de kurulu uygulamaların listesini ister; listede geliştirici modunda kurulan (mağazada olmayan)
     * uygulamalar da bulunur.
     */
    const val SAMSUNG_INSTALLED_APPS_REQUEST = """{"method":"ms.channel.emit","params":{"event":"ed.installedApp.get","to":"host"}}"""

    /** TV'nin kurulu uygulama listesine göre CouchSubs: yoksa [installed] false; varsa TV'nin bildirdiği `app_type`. */
    data class SamsungAppPresence(val installed: Boolean, val appType: Int?)

    /** Kurulu uygulama listesi yanıtında [appId] var mı; yanıt bu değilse null. */
    fun samsungInstalledApp(text: String, appId: String = SAMSUNG_APP_ID): SamsungAppPresence? = try {
        val message = JSONObject(text)
        val apps = message.optJSONObject("data")?.optJSONArray("data")
        if (message.optString("event") != "ed.installedApp.get" || apps == null) null
        else (0 until apps.length()).mapNotNull { apps.optJSONObject(it) }.firstOrNull { it.optString("appId") == appId }
            ?.let { SamsungAppPresence(true, if (it.has("app_type")) it.optInt("app_type") else null) }
            ?: SamsungAppPresence(false, null)
    } catch (_: Exception) { null }

    /**
     * `ed.apps.launch` açılış türü: `app_type` 4 (yerel Tizen uygulaması) NATIVE_LAUNCH, 2 (web uygulaması; CouchSubs .wgt)
     * ve bilinmeyen DEEP_LINK.
     */
    fun samsungActionType(appType: Int?): String = if (appType == 4) "NATIVE_LAUNCH" else "DEEP_LINK"

    /**
     * TV uygulamasının bu Samsung TV'de kurulu olduğu biliniyor mu: bu telefon kurdu ya da sürümünü TV'den okudu
     * ([InstalledTv.version]), ya da uygulama bu TV'den daha önce bağlandı ([seenHost]). Bilinen TV'de açma komutundan
     * önce TV'nin kurulu uygulama listesine bakılmaz: listenin geliştirici moduyla kurulan uygulamayı içerdiği gerçek
     * TV'de doğrulanmadı; içermiyorsa telefon uygulamayı hiç açmıyordu (beta.63).
     */
    fun samsungKnownInstalled(tv: InstalledTv, seenHost: String?): Boolean =
        tv.brand == TvBrand.SAMSUNG && (!tv.version.isNullOrEmpty() || (!seenHost.isNullOrEmpty() && seenHost == tv.host))

    /**
     * Açma kararı (Windows ve Mac/iPhone'daki SamsungAppKnowledge ile aynı). Kurulu olduğu bilinen TV'de liste ne derse
     * desin eski yol (DEEP_LINK); bilinmeyen TV'de listede yoksa (#637) ya da liste 3 saniyede gelmezse gönderilmez: kurulu
     * olmayan uygulamaya giden DEEP_LINK Smart Hub'ı mağaza aramasına yolluyor, Samsung'a ulaşamayan TV'de "Samsung
     * sunucusuna bağlanılamıyor (AS400)" çıkıyordu (Samsung 7 Series 2018, 21 Kas). Dönen değer gönderilecek tür,
     * gönderilmeyecekse null.
     */
    fun samsungAction(knownInstalled: Boolean, presence: SamsungAppPresence?): String? = when {
        knownInstalled -> "DEEP_LINK"
        presence?.installed != true -> null
        else -> samsungActionType(presence?.appType)
    }

    /** Açma isteği gönderilmediğinde tvinstall.log satırı (Windows ve Mac/iPhone ile aynı metin). */
    fun samsungNotSentLine(host: String, presence: SamsungAppPresence?): String =
        if (presence == null) "Samsung $host: uygulama listesi 3 sn'de gelmedi; açma isteği gönderilmedi (kurulu olmayan uygulamaya DEEP_LINK Smart Hub'ı mağazaya yollar)."
        else "Samsung $host: kurulu uygulama listesinde CouchSubs yok; açma isteği gönderilmedi."

    /** Listesiz DEEP_LINK gönderilen ama TV uygulaması o günden beri bağlanmayan TV'ler (yalnız bellekte). */
    private val samsungUnconfirmed = java.util.Collections.synchronizedSet(HashSet<String>())
    /** Bayat bilgi günlüğe yazıldı (bekçi her 30 sn'de denediği için bir kez). */
    private val samsungStaleReported = java.util.Collections.synchronizedSet(HashSet<String>())

    /**
     * Kurulu olduğu bilinen TV'de listeye bakmadan DEEP_LINK gönderilebilir mi. Hak, TV uygulaması her bağlandığında
     * ([samsungAppConnected]) bir kez verilir: bir önceki listesiz DEEP_LINK'ten sonra uygulama bağlanmadıysa bilgi bayat
     * sayılır ve TV'nin kurulu uygulama listesine bakılır. Uygulama TV'den silinince (Smart Hub sıfırlaması, kaldırılıp
     * yeniden kurulamayan güncelleme, TV yazılım güncellemesi) "kurulu" bilgisi kalıyordu; bekçi her 30 sn'de DEEP_LINK
     * gönderiyor, Smart Hub uygulamayı mağazada arıyor, TV her seferinde "Sunucu bakım altında (1544007)" diyordu (22 Kas).
     * Windows ve Mac/iPhone ile aynı. Yalnız bilinen TV için çağrılır.
     */
    fun samsungAllowsDirect(host: String, installLog: (String) -> Unit = {}): Boolean {
        val key = host.trim().lowercase()
        if (samsungUnconfirmed.add(key)) return true
        if (samsungStaleReported.add(key)) {
            val line = samsungUnconfirmedLine(host)
            android.util.Log.i("CouchSubsTvLaunch", line)
            installLog(line)
        }
        return false
    }

    /** TV uygulaması bu Samsung TV'den bağlandı: listesiz açma hakkı yenilenir. */
    fun samsungAppConnected(host: String) {
        val key = host.trim().lowercase()
        samsungUnconfirmed.remove(key)
        samsungStaleReported.remove(key)
    }

    /** Listesiz açma bilgisi silinir (uygulama TV'den silindi); yeniden kurulup bağlanınca hak yine verilir. */
    fun samsungForget(host: String) {
        val key = host.trim().lowercase()
        samsungUnconfirmed.remove(key)
        samsungStaleReported.remove(key)
    }

    /** İki adres aynı TV mi (boşluk ve büyük/küçük harf gözetmeden). */
    fun samsungSameHost(a: String?, b: String?): Boolean =
        !a.isNullOrBlank() && !b.isNullOrBlank() && a.trim().equals(b.trim(), ignoreCase = true)

    /**
     * Listedeki "CouchSubs yok" kurulu bilgisini siler mi: yalnız kurulu bilinen TV'de bayat bilgi yüzünden listeye
     * bakıldıysa ve liste kesin "yok" dediyse (yanıtsız liste silmez). Mac/iPhone ve Windows'taki forgetsOnList ile aynı.
     */
    fun samsungForgetsOnList(knownStale: Boolean, presence: SamsungAppPresence?): Boolean = knownStale && presence?.installed == false

    /**
     * Uygulama TV'den silinince (#1158) kayıtların yeni hâli: eşli TV korunur, yalnız sürümü (bilinen kurulumun işareti)
     * silinir; "uygulama bağlandı" adresi bu TV'nin ise o da silinir. Başka TV'nin kaydına dokunulmaz.
     */
    fun samsungForgetMissing(tv: InstalledTv?, seenHost: String?, host: String): Pair<InstalledTv?, String?> {
        val kept = if (tv != null && tv.brand == TvBrand.SAMSUNG && samsungSameHost(tv.host, host) && tv.version != null) tv.copy(version = null) else tv
        return kept to seenHost?.takeUnless { samsungSameHost(it, host) }
    }

    fun samsungMissingLine(host: String): String =
        "Samsung $host: TV'nin kurulu uygulama listesinde CouchSubs yok; TV uygulaması silinmiş, \"kurulu\" bilgisi silindi (kurulum adımı önerilecek)."

    fun samsungUnconfirmedLine(host: String): String =
        "Samsung $host: son doğrudan açma komutundan sonra TV uygulaması bağlanmadı; kurulu uygulama listesine bakılıyor (kurulu olmayan uygulamaya DEEP_LINK \"Sunucu bakım altında\" uyarısı çıkarır)."

    /** Bekçi her 30 sn'de denediği için aynı satır tvinstall.log'da yinelenmez. */
    private val lastNotSent = java.util.concurrent.atomic.AtomicReference<String?>(null)

    /** Sahadan öğrenmek için yapılan liste sorgusu çalışma boyunca bir kez yapılır. */
    private val samsungProbed = java.util.concurrent.atomic.AtomicBoolean(false)
    fun registerMessage(key: String?): String {
        val payload = JSONObject().put("forcePairing", false).put("pairingType", "PROMPT")
            .put("manifest", JSONObject().put("manifestVersion", 1).put("appVersion", "1.0")
                .put("permissions", JSONArray(listOf("LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "READ_RUNNING_APPS", "READ_INSTALLED_APPS"))))
        if (!key.isNullOrEmpty()) payload.put("client-key", key)
        return JSONObject().put("type", "register").put("id", "register_0").put("payload", payload).toString()
    }
    /** Android TV uygulaması bağlı değilken en çok bu aralıkla yeniden açılır. */
    const val ANDROID_RELAUNCH_MS = 30_000L

    /** Android TV bekçisi bağlantıya bu aralıkla bakar (açmanın kendisi [AndroidTvOpenRule]'un aralığına uyar). */
    const val ANDROID_CHECK_MS = 5_000L

    /**
     * Android TV: ADB açıksa (uygulama bu telefondan kurulduysa) CouchSubs TV telefonun adresiyle açılır. Ne zaman açılacağı
     * [AndroidTvOpenRule]'dadır: bu çeviride bağlanmış uygulama bir daha açılmaz, hiç bağlanmadıysa en çok üç kez, 30 sn
     * arayla; TV'de zaten çalışıyorsa `am start` gönderilmez (Windows, Mac ve iPhone'la aynı). Yalnız adres gider; TV yine
     * ekrandaki kodun onayıyla (/pair) eşleşir. Eskiden telefon Android TV'ye hiç dokunmuyor, TV uygulaması telefonu ağ
     * taramasıyla bulamazsa "Ağda CouchSubs aranıyor…"da kalıyordu. ADB kapalıysa sessizce vazgeçilir; tarama yolu sürer.
     *
     * @param open (adres, ADB portu, başlatma parametreleri, kapatıp aç) → `am start` çıktısı ya da
     *   AndroidTvInstaller.ALREADY_RUNNING; testlerde sahtesi verilir. Uygulama çalışıyor ama [resumeWaitMs] içinde
     *   bağlanmazsa bir kez kapatılıp (`am force-stop`) temiz açılır ([openAndroidTv]; Samsung'daki #1248 ile aynı).
     * @param sleep en çok verilen süre bekler; "Otomatik açmayı dene" istendiyse true döner (sayaç sıfırlanır).
     * @param current kayıtlı TV (her turda okunur): Android TV DHCP'den yeni adres alıp kurulum onu yeni adreste bulunca
     *   bekçi yeni adrese geçer. Eskiden çeviri boyunca eski adreste açmaya çalışıyordu (#985; Mac, Windows, iPhone ile aynı).
     */
    internal fun keepAndroidTvOpen(
        tv: InstalledTv, server: String, active: () -> Boolean, connected: () -> Boolean,
        open: (String, Int, String?, Boolean) -> String, log: (String) -> Unit = {},
        sleep: (Long) -> Boolean = { TvOpenRetry.waitOrRetry(it) },
        onOpenResult: (TvOpenProblem?) -> Unit = {}, now: () -> Long = { android.os.SystemClock.elapsedRealtime() },
        rule: AndroidTvOpenRule = AndroidTvOpenRule(), current: () -> InstalledTv? = { tv },
        resumeWaitMs: Long = SAMSUNG_RESUME_WAIT_MS,
    ) {
        var target = tv
        var adbPort = adbPortOf(target)
        val params = com.couchsubs.mobile.tv.android.AndroidTvInstaller.launchParams(server)
        var last: String? = null
        while (active()) {
            val saved = current()
            if (saved != null && saved.brand == TvBrand.ANDROID_TV && (saved.host != target.host || adbPortOf(saved) != adbPort)) {
                log("Android TV yeni adreste: ${target.host}:$adbPort → ${saved.host}:${adbPortOf(saved)}")
                target = saved
                adbPort = adbPortOf(saved)
                last = null
                rule.reset()
            }
            if (rule.shouldTry(connected(), now())) {
                val result = try {
                    val host = target.host
                    val port = adbPort
                    val output = openAndroidTv({ restart -> open(host, port, params, restart) }, connected, waitMs = resumeWaitMs, log = log)
                    // Uygulama TV'de çalışırken bulunduysa `am start` gönderilmedi: açılış sayılmaz.
                    if (output != com.couchsubs.mobile.tv.android.AndroidTvInstaller.ALREADY_RUNNING) rule.opened()
                    onOpenResult(null)
                    "açıldı: $output"
                } catch (error: Exception) {
                    onOpenResult(TvOpenProblem.ofAndroidTv(error))
                    "açılamadı: ${error.message ?: error.javaClass.simpleName}"
                }
                // Aynı sonuç her denemede yeniden yazılmaz.
                if (result != last) log("Android TV (${target.host}:$adbPort) telefonun adresiyle $result")
                last = result
            }
            if (sleep(ANDROID_CHECK_MS)) rule.reset()
        }
    }

    /**
     * Açma sonucu uygulamanın zaten çalıştığını söylüyor mu: açıcı `am start` göndermedi ("zaten açık") ya da `am start`
     * "Activity not started" dedi (ekran yalnız öne geldi). Samsung'daki "resumed"ın karşılığı; Windows ve Mac/iPhone'daki
     * AndroidTvLauncher.IsResumed ile aynı.
     */
    fun androidTvResumed(output: String): Boolean = output.trim().let {
        it == com.couchsubs.mobile.tv.android.AndroidTvInstaller.ALREADY_RUNNING || it.contains("Activity not started")
    }

    /**
     * Android TV'yi açar; Samsung'daki [openSamsungWithSdb] ile aynı kural (#1248). Uygulama TV'de çalışırken bulunursa ya da
     * `am start` "zaten çalışıyor" derse, uygulamaya kendisi bağlanması için [waitMs] (10 sn) tanınır; bağlanmazsa bir kez
     * kapatılıp (`am force-stop`) temiz açılır. Bağlanırsa dokunulmaz. Eskiden Android TV'de bu yol yoktu: akışı kopan ama
     * çalışmayı sürdüren TV uygulaması "zaten açık" sayılıyor, çeviri boyunca bağlanmıyordu. Windows, Mac ve iPhone'daki
     * AndroidTvLauncher ile aynı. Son açma çıktısı döner; açılamazsa hata.
     */
    internal fun openAndroidTv(open: (Boolean) -> String, connected: () -> Boolean, waitMs: Long = SAMSUNG_RESUME_WAIT_MS,
                               pollMs: Long = 500, now: () -> Long = { System.nanoTime() / 1_000_000 },
                               sleep: (Long) -> Unit = { Thread.sleep(it) }, log: (String) -> Unit = {}): String {
        val output = open(false).trim()
        if (!androidTvResumed(output)) return output
        val deadline = now() + waitMs
        while (now() < deadline) {
            if (connected()) return output
            sleep(pollMs)
        }
        if (connected()) return output
        log("Android TV: TV uygulaması çalışıyordu ($output) ama ${waitMs / 1000} sn'de bağlanmadı; kapatılıp (kapanma isteği, gerekirse am force-stop) yeniden açılıyor")
        return open(true).trim()
    }

    private fun adbPortOf(tv: InstalledTv) = tv.port.takeIf { it > 0 } ?: com.couchsubs.mobile.tv.android.AdbConnection.DEFAULT_PORT

    /** Telefonun TV'ye bakan adresiyle altyazı sunucusu ("http://192.168.1.20:8787"); bilinemezse null. */
    private fun serverAddress(remote: InetAddress, port: Int): String? {
        val own = DatagramSocket().use { it.connect(InetSocketAddress(remote, 9)); it.localAddress.hostAddress } ?: return null
        return "http://${if (own.contains(':')) "[$own]" else own}:$port"
    }

    /**
     * LG: [launch]'tan sonra çeviri sürdükçe CouchSubs TV'yi önde tutar ([LgKeeper]; Windows/Mac/iPhone'daki bekçiyle aynı
     * kural). Eskiden Android telefon uygulamayı bir kez açıp bırakıyordu; PS tuşu TV'yi PS5'in girişine geçirince çeviri
     * bir daha TV'ye gelmiyordu. TV'nin izin sorusu [launch]'ta yanıtlanmış olmalı (saklı anahtar yoksa bağlanılmaz). Bloklar.
     */
    fun keepLgOpen(settings: AppSettings, port: Int, key: String, consolePort: () -> Int?, log: (String) -> Unit = {},
                   onOpenResult: (TvOpenProblem?) -> Unit = {}, connected: (() -> Boolean)? = null,
                   relocate: () -> Boolean = { false }, active: () -> Boolean) {
        val tv = settings.installedTv ?: return
        if (tv.brand != TvBrand.LG || !active()) return
        if (!SubtitleAccess.isLocalPeer(InetAddress.getByName(tv.host))) return
        LgKeeper.keep(open = { openLg({ settings.installedTv }, relocate) { ssapToLg(settings, it, port, key) } },
            active = active, consolePort = consolePort, log = log, onOpenResult = onOpenResult, retry = TvOpenRetry::take,
            connected = connected)
    }

    /**
     * Kayıtlı LG'ye (her denemede kayıttan okunur) bağlanır; bağlanamazsa [relocate] TV'yi ağda arar, yeni adreste
     * bulunursa (kayıt güncellendi) yeni adresle hemen bir kez daha denenir. Eskiden arka plandaki bekçi kayıtlı adresi
     * aynen kullanıyor, TV yeni adres alınca çeviri bitene kadar bağlanamıyordu.
     */
    internal fun openLg(current: () -> InstalledTv?, relocate: () -> Boolean, connect: (InstalledTv) -> LgControl?): LgControl? {
        val tv = current()?.takeIf { it.brand == TvBrand.LG } ?: return null
        connect(tv)?.let { return it }
        if (!relocate()) return null
        val moved = current()?.takeIf { it.brand == TvBrand.LG && it.host != tv.host } ?: return null
        return connect(moved)
    }

    private fun ssapToLg(settings: AppSettings, tv: InstalledTv, port: Int, key: String): LgControl? {
        val remote = runCatching { InetAddress.getByName(tv.host) }.getOrNull() ?: return null
        if (!SubtitleAccess.isLocalPeer(remote)) return null
        return serverAddress(remote, port)?.let { LgKeeper.ssapControl(settings, tv, remote, it, key) }
    }

    /**
     * Samsung'da açma komutu gittikten sonra TV uygulamasının bağlanması için beklenen süre; bağlanmazsa ana ekranda "TV
     * açmadı" yazar ([TvOpenProblem.NOT_OPENED]). Samsung `ed.apps.launch`'ın açılışı söyleyen bir yanıtını vermez: bazı
     * TV'ler komutu alıp uygulamayı açmıyor, neden satırı boş kalıyordu (iPhone, TestFlight build 27; Windows/Mac/iPhone ile aynı).
     */
    const val SAMSUNG_OPEN_CHECK_MS = 15_000L

    /**
     * Samsung: [launch]'tan sonra TV uygulaması bağlı değilken yeniden açar; ne zaman açılacağı [SamsungOpenRule]'dadır
     * (seyrelen aralık ve üst sınır; Windows, Mac ve iPhone'daki bekçiyle aynı; Samsung önplandaki uygulamayı söylemez,
     * yalnız açılır). "Otomatik açmayı dene" sayacı sıfırlar ve beklemeyi keser. Eskiden Android telefon Samsung'da uygulamayı
     * yalnız bir kez açmayı deniyordu. Bloklar. [openWithSdb]: önce geliştirici bağlantısıyla (sdb `was_execute`) açmayı
     * dener (bkz. [launch]). [lastResult]: ana ekranda şu an gösterilen neden. Her denemenin sonucu [log]'a yazılır.
     */
    fun keepSamsungOpen(settings: AppSettings, port: Int, key: String, connected: () -> Boolean, log: (String) -> Unit = {},
                        onOpenResult: (TvOpenProblem?) -> Unit = {}, openWithSdb: ((Boolean) -> com.couchsubs.mobile.tv.samsung.SdbOpen)? = null,
                        lastResult: () -> TvOpenProblem? = { null }, installLog: (String) -> Unit = {},
                        relocate: () -> Boolean = { false }, active: () -> Boolean) =
        keepSamsungOpen(settings.installedTv, connected, active, log = log,
            notOpened = { if (lastResult() == null) onOpenResult(TvOpenProblem.NOT_OPENED) }, relocate = relocate) { attempt ->
            // TV bir önceki komutta da açmadıysa neden satırı yeniden gönderilen komutla silinmez (her 30 sn'de yanıp sönmesin).
            val keep = lastResult() == TvOpenProblem.NOT_OPENED
            launch(settings, port, key, connected = connected, log = log, openWithSdb = openWithSdb,
                onOpenResult = {
                    log("TV uygulamasını açma denemesi $attempt (Samsung): ${it?.let { problem -> "olmadı, $problem" } ?: "açma komutu gitti"}")
                    if (!(keep && it == null)) onOpenResult(it)
                }, installLog = installLog, active = active)
        }

    /**
     * Her [SAMSUNG_OPEN_CHECK_MS]'de bir bakar: son açma komutundan bu kadar sonra uygulama hâlâ bağlı değilse [notOpened];
     * [SamsungOpenRule] izin verirse yeniden [open] (deneme etiketiyle, "3/6"). İlk açma [launch]'ta olduğu için ilk deneme
     * sayılır. "Otomatik açmayı dene" ([sleep] true dönerse) sayacı sıfırlar, beklemeden açar.
     */
    internal fun keepSamsungOpen(tv: InstalledTv?, connected: () -> Boolean, active: () -> Boolean,
                                 sleep: (Long) -> Boolean = { TvOpenRetry.waitOrRetry(it) }, notOpened: () -> Unit = {},
                                 relocate: () -> Boolean = { false },
                                 now: () -> Long = { android.os.SystemClock.elapsedRealtime() }, log: (String) -> Unit = {},
                                 rule: SamsungOpenRule = SamsungOpenRule(), open: (String) -> Unit) {
        if (tv?.brand != TvBrand.SAMSUNG) return
        rule.shouldTry(connected = false, now = now())
        var sentAt: Long? = now()
        var exhaustedLogged = false
        while (active()) {
            if (sleep(SAMSUNG_OPEN_CHECK_MS)) {
                // "Otomatik açmayı dene": "açmadı" denetimi atlanır, sayaç sıfırlanır, hemen açılır.
                rule.reset()
                exhaustedLogged = false
                sentAt = null
            }
            if (!active()) return
            val isConnected = connected()
            val time = now()
            if (isConnected) sentAt = null
            sentAt?.let {
                if (time - it >= SAMSUNG_OPEN_CHECK_MS) {
                    sentAt = null
                    notOpened()
                }
            }
            if (rule.shouldTry(isConnected, time)) {
                // TV uygulaması bağlanmadı: kayıtlı adres sessizse TV ağda aranır, yeni adreste bulunursa kayıt güncellenir ve
                // açma komutu yeni adrese gider (open kayıttan okur). Eskiden kayıtlı eski adres aynen kullanılıyordu. Arama da
                // açma denemesiyle aynı seyrelen aralığa ve sınıra uyar.
                relocate()
                sentAt = time
                open("${rule.attempts}/${rule.maxAttempts}")
            } else if (!isConnected && rule.exhausted && !exhaustedLogged) {
                exhaustedLogged = true
                log("TV uygulamasını açma (Samsung): ${rule.maxAttempts} denemede bağlanmadı, otomatik açma durdu (\"TV'de aç\" ya da çeviriyi yeniden başlatmak yeniden dener)")
            }
        }
    }

    /** "resumed"dan sonra TV uygulamasının kendiliğinden bağlanması için beklenen süre (Windows/Mac/iPhone ResumeWait). */
    const val SAMSUNG_RESUME_WAIT_MS = 10_000L

    /**
     * Samsung'u geliştirici bağlantısıyla (sdb) açar; true ise uzaktan kumanda (8002) yoluna geçilmez.
     *
     * #1248 (beta.95, Samsung 2020): bilgisayar altyazı akışını "alındı gelmedi" diye kapattıktan sonra TV uygulaması hâlâ
     * çalışıyordu; `was_execute` her seferinde "resumed" diyordu (uygulama yalnız öne geliyor, sayfa yeniden yüklenmiyor ve
     * akışa bağlanmıyordu). "resumed" başarısız sayıldığı için 8002 yoluna düşülüyor, TV "Samsung sunucusuna
     * bağlanılamıyor (AS400)" diyordu. Artık "resumed" uygulamanın çalıştığı sayılır: sayfaya kendisi yeniden bağlanması
     * için [waitMs] tanınır (TV uygulaması 0.9.104'ten beri öne gelince akışı yeniden kurar), bağlanmazsa uygulama sdb ile
     * kapatılıp yeniden açılır (sayfa temiz yüklenir). Kapatıp açma da tutmazsa yine 8002'ye geçilmez; bekçi yeniden dener.
     * Windows, Mac ve iPhone'daki SamsungLauncher ile aynı.
     */
    internal fun openSamsungWithSdb(openWithSdb: (Boolean) -> com.couchsubs.mobile.tv.samsung.SdbOpen, connected: () -> Boolean,
                                    waitMs: Long = SAMSUNG_RESUME_WAIT_MS, pollMs: Long = 500,
                                    now: () -> Long = { System.nanoTime() / 1_000_000 },
                                    sleep: (Long) -> Unit = { Thread.sleep(it) }, log: (String) -> Unit = {}): Boolean {
        when (openWithSdb(false)) {
            com.couchsubs.mobile.tv.samsung.SdbOpen.LAUNCHED -> return true
            com.couchsubs.mobile.tv.samsung.SdbOpen.FAILED -> return false
            com.couchsubs.mobile.tv.samsung.SdbOpen.RESUMED -> {
                val deadline = now() + waitMs
                while (now() < deadline) {
                    if (connected()) return true
                    sleep(pollMs)
                }
                if (connected()) return true
                log("Samsung: TV uygulaması çalışıyordu (resumed) ama ${waitMs / 1000} sn'de bağlanmadı; kapatılıp yeniden açılıyor")
                val restarted = openWithSdb(true)
                if (restarted != com.couchsubs.mobile.tv.samsung.SdbOpen.LAUNCHED) {
                    log("Samsung: TV uygulaması kapatılıp açılamadı (${restarted.name.lowercase()}); uzaktan kumanda yolu denenmiyor, bekçi yeniden dener")
                }
                return true
            }
        }
    }

    /** [onOpenResult]: açma denemesinin sonucu (ana ekrandaki satır); TV izni alındıysa ya da açıldıysa null. */
    fun launch(settings: AppSettings, port: Int, key: String, adbKeyFile: java.io.File? = null, connected: () -> Boolean = { false },
               log: (String) -> Unit = {}, onOpenResult: (TvOpenProblem?) -> Unit = {}, openWithSdb: ((Boolean) -> com.couchsubs.mobile.tv.samsung.SdbOpen)? = null,
               installLog: (String) -> Unit = {}, active: () -> Boolean) {
        val tv = settings.installedTv ?: return
        if (!active()) return
        val remote = InetAddress.getByName(tv.host)
        if (!SubtitleAccess.isLocalPeer(remote)) return
        val server = serverAddress(remote, port) ?: return
        if (tv.brand == TvBrand.ANDROID_TV) {
            if (adbKeyFile == null) return
            keepAndroidTvOpen(tv, server, active, connected, open = { host, adbPort, params, restart ->
                if (!com.couchsubs.mobile.tv.android.AndroidTvInstaller.isReachable(host, adbPort)) throw java.io.IOException("ADB kapalı")
                com.couchsubs.mobile.tv.android.AndroidTvInstaller(host, adbPort,
                    adbKey = { com.couchsubs.mobile.tv.samsung.AdbKey.loadOrCreate(adbKeyFile) })
                    .open(params, restart)
            }, log = log, onOpenResult = onOpenResult, current = { settings.installedTv })
            return
        }
        // Samsung: önce geliştirici bağlantısı (sdb `was_execute`; Windows, Mac ve iPhone ile aynı). Uzaktan kumanda
        // bağlantısıyla açmayı bazı TV'ler sessizce yok sayıyor (Tizen 9.0, #412; iPhone build 27). sdb yalnız geliştirici modu
        // açık ve Host PC IP bu telefonsa çalışır (telefondan kurulduysa öyledir); değilse uzaktan kumandaya geçilir.
        // LG: uygulama zaten açık ve bağlıysa açma komutu gitmez; webOS önde çalışan uygulamayı yeniden başlatıp HDMI
        // görüntüsünü yeniden kuruyor, ekran kararıyordu (#1055; Mac, iPhone ve Windows ile aynı).
        if (tv.brand == TvBrand.LG && connected()) {
            onOpenResult(null)
            return
        }
        if (tv.brand == TvBrand.SAMSUNG && openWithSdb != null && openSamsungWithSdb(openWithSdb, connected, log = { line ->
                log(line)
                installLog(line)
            })) {
            log("Samsung (${tv.host}) TV uygulaması geliştirici bağlantısıyla açıldı")
            onOpenResult(null)
            return
        }
        val tokenKey = "tv.control.${tv.brand}.${tv.host}"
        val pinKey = "$tokenKey.certificate"
        val storedPin = settings.secrets.get(pinKey)
        var certificatePin: String? = null
        // TV sertifikaları kendinden imzalıdır. İlk TV izninden sonra sertifika parmak izi sabitlenir.
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw java.security.cert.CertificateException()
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty()) throw java.security.cert.CertificateException()
                val pin = MessageDigest.getInstance("SHA-256").digest(chain[0].publicKey.encoded).joinToString("") { "%02x".format(it.toInt() and 255) }
                if (storedPin != null && storedPin != pin) throw java.security.cert.CertificateException("TV certificate changed")
                certificatePin = pin
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
        val client = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS)
            .dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> =
                    if (hostname == tv.host) listOf(remote) else throw java.net.UnknownHostException(hostname)
            })
            .sslSocketFactory(tls.socketFactory, trust).hostnameVerifier { host, _ -> host == tv.host }.build()
        val token = settings.secrets.get(tokenKey)
        val host = if (tv.host.contains(':')) "[${tv.host}]" else tv.host
        val urls = if (tv.brand == TvBrand.LG) listOf("wss://$host:3001", "ws://$host:3000") else listOf(
            "wss://$host:8002/api/v2/channels/samsung.remote.control?name=Q291Y2hTdWJz" + (token?.let { "&token=" + java.net.URLEncoder.encode(it, "UTF-8") } ?: ""))
        try {
            for (url in urls) {
                if (!active()) return
                val done = CountDownLatch(1)
                var registered = false
                var sent = false
                // Samsung: TV kurulu olduğunu doğrulamadı, açma komutu gönderilmedi (ana ekran kurulumu önerir).
                var notInstalled = false
                // Samsung: kurulu uygulama listesinin yanıtı bekleniyor mu. Yanıt 3 saniyede gelmezse eski yol (DEEP_LINK).
                val awaitingList = java.util.concurrent.atomic.AtomicBoolean(false)
                // Uygulamanın bu TV'de kurulu olduğu biliniyorsa listeye bakılmaz, eskisi gibi doğrudan açılır.
                // Listesiz açma, uygulama her bağlandığında bir kez: bayat bilgi "Sunucu bakım altında" çıkarmasın.
                val knownInstalled = samsungKnownInstalled(tv, settings.samsungAppSeenHost)
                val known = knownInstalled && samsungAllowsDirect(tv.host, installLog)
                // Kurulu bilinen TV'de son listesiz açmadan sonra uygulama bağlanmadı: listeye bakılıyor (bilgi bayat).
                val knownStale = knownInstalled && !known
                // Bilinen TV'de açma komutundan sonra, yalnız günlük için listeye bir kez bakılıyor mu.
                val probing = java.util.concurrent.atomic.AtomicBoolean(false)
                fun samsungLaunch(webSocket: WebSocket, presence: SamsungAppPresence?) {
                    if (!awaitingList.getAndSet(false)) return
                    // Bayat bilgide liste "yok" diyor: uygulama TV'den silinmiş (#1158); "kurulu" kaydı silinir.
                    if (tv.brand == TvBrand.SAMSUNG && samsungForgetsOnList(knownStale, presence)) {
                        val line = samsungMissingLine(tv.host)
                        log(line)
                        installLog(line)
                        TvAppUpdate.samsungAppMissing(tv.host, settings = settings)
                    }
                    // Kurulu değilken DEEP_LINK gönderilirse Smart Hub uygulamayı mağazada arıyor ve TV'de "Sunucu bakım
                    // altında (1544007)" ya da "Samsung sunucusuna bağlanılamıyor (AS400)" çıkıyordu (#402, #511, #637);
                    // listede yoksa ya da liste 3 sn'de gelmezse hiçbir şey gönderilmez.
                    val action = samsungAction(false, presence)
                    if (action != null) sent = webSocket.send(launchMessage(tv.brand, server, key, action))
                    else {
                        notInstalled = true
                        val line = samsungNotSentLine(tv.host, presence)
                        log(line)
                        if (lastNotSent.getAndSet(line) != line) installLog(line)
                    }
                    webSocket.close(1000, null)
                }
                fun samsungProbeDone(webSocket: WebSocket, presence: SamsungAppPresence?) {
                    if (!probing.getAndSet(false)) return
                    android.util.Log.i("CouchSubsTvLaunch", when {
                        presence == null -> "Samsung ${tv.host}: kurulu uygulama listesi yanıtsız; uygulama daha önce bağlandığı için doğrudan açıldı."
                        !presence.installed -> "Samsung ${tv.host}: kurulu uygulama listesinde CouchSubs YOK ama uygulama daha önce bağlandı/kuruldu; doğrudan açıldı."
                        else -> "Samsung ${tv.host}: kurulu uygulama listesinde CouchSubs var (app_type ${presence.appType ?: "?"})."
                    })
                    webSocket.close(1000, null)
                }
                val socket = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        if (!active()) { done.countDown(); return }
                        if (tv.brand == TvBrand.LG) webSocket.send(registerMessage(token))
                    }
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        try {
                            if (awaitingList.get()) {
                                samsungInstalledApp(text)?.let { samsungLaunch(webSocket, it) }
                                return
                            }
                            if (probing.get()) {
                                samsungInstalledApp(text)?.let { samsungProbeDone(webSocket, it) }
                                return
                            }
                            val message = JSONObject(text)
                            val approved = if (tv.brand == TvBrand.LG) message.optString("type") == "registered" else message.optString("event") == "ms.channel.connect"
                            if (approved && !registered && active()) {
                                registered = true
                                val received = if (tv.brand == TvBrand.LG) message.optJSONObject("payload")?.optString("client-key") else message.optJSONObject("data")?.optString("token")
                                if (!received.isNullOrEmpty()) settings.secrets.put(tokenKey, received)
                                certificatePin?.let { settings.secrets.put(pinKey, it) }
                                if (tv.brand == TvBrand.SAMSUNG && known) {
                                    sent = webSocket.send(launchMessage(tv.brand, server, key, samsungAction(true, null)!!))
                                    if (samsungProbed.compareAndSet(false, true) && webSocket.send(SAMSUNG_INSTALLED_APPS_REQUEST)) {
                                        probing.set(true)
                                        Thread { Thread.sleep(3000); samsungProbeDone(webSocket, null) }.apply { isDaemon = true }.start()
                                    } else webSocket.close(1000, null)
                                } else if (tv.brand == TvBrand.SAMSUNG) {
                                    awaitingList.set(true)
                                    if (!webSocket.send(SAMSUNG_INSTALLED_APPS_REQUEST)) samsungLaunch(webSocket, null)
                                    else Thread { Thread.sleep(3000); samsungLaunch(webSocket, null) }.apply { isDaemon = true }.start()
                                } else sent = webSocket.send(launchMessage(tv.brand, server, key))
                            } else if (message.optString("id") == "launch_1" || message.optString("type") == "error" || message.optString("event") in listOf("ms.channel.unauthorized", "ms.channel.timeOut")) done.countDown()
                        } catch (_: Exception) { done.countDown() }
                    }
                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { done.countDown() }
                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { done.countDown() }
                })
                try { done.await(60, TimeUnit.SECONDS) } finally { socket.close(1000, null); socket.cancel() }
                // Açılış başarısız olsa bile TV /pair ile onay isteyebilir; sürekli yeniden başlatma yok.
                if (registered || sent || storedPin != null) {
                    onOpenResult(if (notInstalled && !sent) TvOpenProblem.NOT_INSTALLED else if (registered || sent) null else TvOpenProblem.UNREACHABLE)
                    return
                }
            }
            if (active()) onOpenResult(TvOpenProblem.UNREACHABLE)
        } finally { client.dispatcher.executorService.shutdown(); client.connectionPool.evictAll() }
    }
}
