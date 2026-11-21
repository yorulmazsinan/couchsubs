// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import android.os.SystemClock
import android.util.Log
import com.couchsubs.mobile.account.Backend
import com.couchsubs.mobile.account.Telemetry
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Bağlantının neden koptuğu; kullanıcıya anlatılabilecek biçimde (Windows: DisconnectKind). */
enum class DisconnectKind {
    STOPPED, IN_USE,
    /**
     * PS5'in adresi oturum ya da ctrl bağlantısını (TCP 9295) reddetti: PS5 yeni uyanıyor ya da adres başka bir cihaza
     * geçmiş. Eşleme sorunu değildir; beklenip yeniden denenir ve PS5 ağda yeniden aranır.
     */
    REFUSED,
    NETWORK, NOT_FOUND, CONSOLE_ASLEEP,
    /** PS5 bu hesap için giriş şifresi istiyor, Ayarlar'da kayıtlı şifre yok. */
    LOGIN_PASSCODE,
    /** PS5 Ayarlar'daki giriş şifresini kabul etmedi; yeniden gönderilmez. */
    LOGIN_PASSCODE_INCORRECT,
    /**
     * PS5 oturum isteğinde kaydı kabul etmedi (0x80108b09 kayıt geçersiz, 0x80108b02 hesap tanınmıyor, 0x80108b26 PS5 bu
     * cihazın eşlemesini bulamadı). Yeniden denemek aynı yere çıkar; PS5 ikinci hesapla yeniden eşlenmelidir.
     */
    REGISTRATION_INVALID,
    /**
     * Bağlantı kuruluyor ama art arda [PictureWatchdog.MAX_NO_PICTURE_SESSIONS] oturumda PS5'ten hiç görüntü gelmedi
     * (iki çözücü türüyle de). Sonsuz "Bağlantı koptu, yeniden bağlanılıyor" döngüsü yerine durulur.
     */
    NO_PICTURE,
    /**
     * PS5 oturum isteğini kayıt dışı bir nedenle reddetti ya da yanıtı okunamadı; libchiaki bunu yalnız "Unknown Session
     * Request Error" diye verir (GitHub #33, #202). Ayrıntı: PS5'in "Reported Application Reason" kodu (ör. 0x80108bff;
     * günlükte kod yoksa null).
     */
    REJECTED,
    /**
     * PS5'teki Uzaktan Oynatma çöktü (libchiaki CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH, "Remote Play on Console has
     * crashed"). PS5 tamamen kapatılıp açılana kadar her oturum isteği aynı yanıtı alır; eskiden İngilizce metinle sonsuza
     * kadar "yeniden bağlanılıyor" deneniyordu (GitHub #519). [CrashRetryLimit.MAX_RETRIES] denemeden sonra durulur.
     */
    CONSOLE_RP_CRASHED,
    OTHER;

    companion object {
        /** Yerel köprünün CS_QUIT_* değeri (Mac/iPhone: DisconnectReason(quit:), Windows: DisconnectReasons.FromNative). */
        fun fromNative(reason: Int): DisconnectKind = when (reason) {
            NativeBridge.QUIT_STOPPED -> STOPPED
            NativeBridge.QUIT_IN_USE -> IN_USE
            NativeBridge.QUIT_REFUSED -> REFUSED
            NativeBridge.QUIT_NETWORK -> NETWORK
            NativeBridge.QUIT_RP_CRASHED -> CONSOLE_RP_CRASHED
            // PSN üzerinden eşleme reddedildi: yeniden eşleme gerekir (eskiden TCP reddiyle aynı REFUSED'du).
            NativeBridge.QUIT_PSN_REGIST_FAILED -> REGISTRATION_INVALID
            else -> OTHER
        }

        /**
         * CHIAKI_RP_APPLICATION_REASON_REGIST_FAILED, _INVALID_PSN_ID ve 0x80108b26. 0x80108b26'yı libchiaki tanımaz: PS5
         * gönderilen kayıt anahtarını (RP-Registkey) kendi eşli cihaz listesinde bulamadı (eşleme PS5'te silinmiş ya da PS5
         * sıfırlanmış). Yeniden denemek aynı yere çıkar; PS5 yeniden eşlenmelidir.
         */
        val REGISTRATION_REJECTED_CODES = setOf(0x80108b09L, 0x80108b02L, 0x80108b26L)

        /**
         * PS5'te Uzaktan Oynatma kapalı (Ayarlar › Sistem › Uzaktan Oynatma › Uzaktan Oynatmayı Etkinleştir); [REJECTED]
         * ayrıntısında bu yazımla gelir. libchiaki tanımaz; GitHub #9'da kullanıcı ayarı açınca düzeldi. Ayar açılınca
         * bağlanılsın diye yeniden denenir.
         */
        const val REMOTE_PLAY_DISABLED = "0x80108b12"
        private val unreachableLines = listOf(
            "Session request connect failed eventually",
            "Failed to send session request",
            "Failed to receive session request response",
        )

        /** libchiaki'nin CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN metni. */
        const val UNKNOWN_SESSION_REQUEST = "Unknown Session Request Error"

        /**
         * libchiaki oturum isteği (TCP 9295) düşünce yalnız "Unknown Session Request Error" der; asıl neden günlük
         * satırındadır. Satırdan anlaşılan neden; anlaşılmıyorsa null (Mac/iPhone: DisconnectReason.sessionRequestHint).
         * PS5 kayıt dışı bir kodla reddettiyse [REJECTED], ayrıntıda kod.
         */
        fun sessionRequestHint(line: String): SessionState.Disconnected? {
            val marker = "Reported Application Reason:"
            val at = line.indexOf(marker)
            if (at >= 0) {
                val token = line.substring(at + marker.length).trimStart(' ').takeWhile { !it.isWhitespace() }.lowercase()
                val code = token.removePrefix("0x").toLongOrNull(16) ?: return null
                return if (code in REGISTRATION_REJECTED_CODES) SessionState.Disconnected(REGISTRATION_INVALID)
                    else SessionState.Disconnected(REJECTED, "0x%08x".format(code))
            }
            // PS5'e bağlanılamadı ya da yanıt gelmedi: PS5 dinlenmeden yeni uyandıysa ilk denemelerde olağandır.
            return if (unreachableLines.any { line.contains(it) }) SessionState.Disconnected(NETWORK) else null
        }

        /** Günlük satırlarından anlaşılan son neden (sonraki satır öncekinden daha yenidir). */
        fun sessionRequestHint(lines: List<String>): SessionState.Disconnected? =
            lines.mapNotNull(::sessionRequestHint).lastOrNull()
    }
}

/** Art arda oturumlarda PS5'ten hiç görüntü gelmedi (Crashlytics'e günlüğüyle birlikte gider). */
class NoPictureException(message: String) : RuntimeException(message)

/** PS5 oturum giriş şifresi (4 hane). PS5 ikinci hesapta şifre isterse Ayarlar'da kayıtlı şifre gönderilir. */
object LoginPasscode {
    const val LENGTH = 4

    /** Boşlukları atar; tam 4 rakam değilse null. */
    fun normalized(value: String?): String? {
        val trimmed = value?.trim() ?: return null
        return trimmed.takeIf { it.length == LENGTH && it.all { c -> c in '0'..'9' } }
    }

    sealed class Reply {
        /** libchiaki rakamları ASCII bekler (chiaki-ng'deki gibi). */
        class Send(val pin: ByteArray) : Reply()
        data class Stop(val kind: DisconnectKind) : Reply()
    }

    /** Şifre yoksa ya da PS5 önceki şifreyi kabul etmediyse oturum kapanır; yanlış şifreyle döngüye girilmez. */
    fun reply(saved: String?, incorrect: Boolean): Reply {
        if (incorrect) return Reply.Stop(DisconnectKind.LOGIN_PASSCODE_INCORRECT)
        val pin = normalized(saved) ?: return Reply.Stop(DisconnectKind.LOGIN_PASSCODE)
        return Reply.Send(pin.toByteArray(Charsets.US_ASCII))
    }
}

sealed class SessionState {
    data object Connecting : SessionState()
    data object Streaming : SessionState()
    data class Disconnected(val kind: DisconnectKind, val detail: String? = null) : SessionState()
}

/**
 * Son PS5 aramasının sonucu ve "bulunamadı" etiketi (Mac/iPhone ve Windows'taki ConsoleSearchState ile aynı kural).
 * Oturum ağ hatasıyla düşer ve PS5 son aramada da yanıt vermediyse neden "bulunamadı"dır. Eskiden aramanın sonucu PS5'e
 * bağlanınca unutulmuyordu: arama yanıtı kaçıp "yine de bağlanılıyor" ile kurulan oturum saatlerce sürse de sonraki her
 * kopma (görüntü bekçisininki dahil) "PS5 … adresinde bulunamadı" diye gösteriliyordu (X'te bildirim, iPad, 60-70 dk
 * sonra). Art arda yanıtsız aramalarda bu cihazın ağ durumu günlüğe yazılır (bkz. [DeviceDiagnostics]).
 */
class ConsoleSearchState {
    companion object {
        /** İlk yanıtsız aramada ve sonra her bu kadar yanıtsız aramada bir tanı satırı yazılır. */
        const val DIAGNOSE_EVERY = 5
    }

    /** Son aramada PS5 yanıt verdi mi (ya da o aramadan sonra PS5'e bağlanıldı mı). */
    var answered = true
        private set
    /** Art arda yanıtsız arama sayısı. */
    var unanswered = 0
        private set

    fun reset() {
        answered = true
        unanswered = 0
    }

    /** Arama bitti; tanı satırı yazılacaksa true. */
    fun searched(answered: Boolean): Boolean {
        this.answered = answered
        if (answered) {
            unanswered = 0
            return false
        }
        unanswered++
        return unanswered == 1 || unanswered % DIAGNOSE_EVERY == 0
    }

    /** Oturum bağlandı: PS5'e ulaşılıyor, sonraki kopma "bulunamadı" sayılmaz. */
    fun connected() {
        answered = true
        unanswered = 0
    }

    fun classify(state: SessionState.Disconnected, host: String): SessionState.Disconnected =
        if (!answered && (state.kind == DisconnectKind.NETWORK || state.kind == DisconnectKind.OTHER))
            SessionState.Disconnected(DisconnectKind.NOT_FOUND, host) else state
}

/**
 * PS5 aramaya yanıt vermeyince bu cihazın kendi ağ durumu (Mac/iPhone ve Windows'taki DeviceDiagnostics ile aynı satır):
 * açık dosya tanıtıcısı sayısı ve sınırı, IPv4 ağları. "PS5 ağdan düştü" ile "bu cihaz PS5'e paket gönderemiyor"
 * günlükten ayrılsın.
 */
object DeviceDiagnostics {
    fun line(): String = describe(openFiles(), openFileLimit(), ipv4Networks())

    fun describe(openFiles: Int, limit: Int?, networks: List<String>): String =
        "açık tanıtıcı $openFiles/${limit?.toString() ?: "-"}; " +
            if (networks.isEmpty()) "IPv4 ağı yok" else "IPv4 " + networks.joinToString(", ")

    private fun openFiles(): Int = java.io.File("/proc/self/fd").list()?.size ?: -1

    private fun openFileLimit(): Int? = try {
        java.io.File("/proc/self/limits").readLines().firstOrNull { it.startsWith("Max open files") }
            ?.split(Regex("\\s{2,}"))?.getOrNull(1)?.trim()?.toIntOrNull()
    } catch (error: Exception) {
        null
    }

    private fun ipv4Networks(): List<String> = try {
        java.net.NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { adapter ->
                adapter.interfaceAddresses.filter { it.address is java.net.Inet4Address }
                    .map { "${adapter.name} ${it.address.hostAddress}/${it.networkPrefixLength}" }
            }
    } catch (error: Exception) {
        listOf("okunamadı (${error.javaClass.simpleName})")
    }
}

/**
 * PS5'teki Uzaktan Oynatma çöktüyse ([DisconnectKind.CONSOLE_RP_CRASHED]) kaç kez yeniden denenir (Mac/iPhone ve
 * Windows'taki CrashRetryLimit ile aynı kural). PS5 tamamen kapatılıp açılmadan her oturum isteği aynı yanıtı alır; eskiden
 * sonsuza kadar "yeniden bağlanılıyor" deneniyordu (GitHub #519). Art arda [MAX_RETRIES] denemeden sonra durulur ve
 * kullanıcıya PS5'i tamamen kapatıp açması söylenir. Sayaç çeviri başlayınca, ağ değişince ve bağlanınca sıfırlanır.
 */
class CrashRetryLimit {
    companion object {
        const val MAX_RETRIES = 2
    }

    /** Art arda bildirilen çökme sayısı. */
    var crashes = 0
        private set

    fun reset() {
        crashes = 0
    }

    /** PS5 çöktü dedi: yeniden denenecekse true, durulacaksa false. */
    fun crashed(): Boolean = ++crashes <= MAX_RETRIES
}

/**
 * Bağlantı koptuğunda yeniden deneme aralıkları: 2, 4, 8, 16, 32, en çok 60 sn (Mac/iPhone ve Windows ile aynı). Aralık
 * bağlanınca hemen değil, oturum [STABLE_AFTER_MS] kadar sürdükten sonra kapanınca baştan başlar. Eskiden her bağlanışta
 * sıfırlanıyordu: PS5 oturumu açılıp birkaç saniyede düşürünce 2 sn sonra yeniden bağlanılıyor, PS5'te ikinci hesap
 * durmadan girip çıkıyordu.
 *
 * Akış sürerken kopan oturumdan sonra en az 8 sn beklenir; aralık 2 dk süren oturumdan sonra baştan başlar. Eskiden
 * 60 sn yetiyordu ve en çok 30 sn beklenirdi: kablosuz ağ bozulunca oturumlar birer dakika sürüp düşüyor, her seferinde
 * 2 sn sonra yeniden deneniyor, bağlan-kop döngüsü uzun süre sürüyordu (Redmi Pad, iPad). Yeni oturum istekleri PS5'in
 * eski oturumu bırakmasını beklemeden geldikçe PS5 30 sn ile birkaç dakika yanıt vermiyordu (GitHub #593). Bir ara
 * 5 dk'ydı: üç dört dakikada bir kopan ağda bekleme 8, 16, 32, 60 sn diye büyüyüp 60 sn'de kalıyor, her kopma bir
 * dakikadan uzun sürüyordu ("sürekli kopuyor").
 */
class ReconnectPolicy {
    companion object {
        const val STABLE_AFTER_MS = 2 * 60_000L
        const val MAX_DELAY_SECONDS = 60
        /** Akış sürerken kopan oturumdan sonraki en kısa bekleme: 2 shl 2 = 8 sn. */
        const val AFTER_DROP_ATTEMPT = 2
    }

    private var attempt = 0
    private var connectedAt: Long? = null

    /** [inUse]: Uzaktan Oynatma başka cihazda; sık denemek boşuna, en az 8 sn beklenir (8, 16, 32). */
    fun nextDelaySeconds(inUse: Boolean = false): Int {
        if (inUse) attempt = maxOf(attempt, 2)
        val delay = minOf(MAX_DELAY_SECONDS, 2 shl attempt)
        attempt = minOf(attempt + 1, 5)
        return delay
    }

    fun reset() {
        attempt = 0
        connectedAt = null
    }

    fun connected(nowMs: Long) {
        connectedAt = nowMs
    }

    /**
     * Oturum kapandı: uzun sürdüyse aralık baştan başlar, kısa sürdüyse büyümeye devam eder. Bağlı oturum kapandıysa PS5
     * eski oturumu bıraksın diye en az 8 sn beklenir.
     */
    fun ended(nowMs: Long) {
        val at = connectedAt
        if (at != null) {
            if (nowMs - at >= STABLE_AFTER_MS) attempt = 0
            attempt = maxOf(attempt, AFTER_DROP_ATTEMPT)
        }
        connectedAt = null
    }
}

/**
 * Dinlenme modundaki PS5 uyandırılsın mı (Mac/iPhone ve Windows'taki WakePolicy ile aynı kural). Yalnız kullanıcı çeviriyi
 * başlattıktan sonra, PS5'e henüz bağlanılmamışken uyandırılır. Eskiden yeniden bağlanma döngüsü de uyandırıyordu: oyuncu
 * PS5'i kapatınca (dinlenme modu) uygulama birkaç saniye sonra PS5'i yeniden açıp bağlanıyor, TV kapalıyken ana ekran
 * "PS5 bağlı" diyordu. Bu çeviride akış bir kez kurulduysa dinlenmedeki PS5'e dokunulmaz; açılınca bağlanılır.
 */
class WakePolicy {
    enum class Action {
        /** PS5 uyanık ya da aramaya yanıt vermedi: oturum açılmaya çalışılır. */
        CONNECT,
        /** PS5 dinlenmede, çeviri yeni başladı: uyandırılır. */
        WAKE,
        /** PS5 dinlenmede ve bu çeviride zaten bağlanılmıştı (kullanıcı kapattı): açılması beklenir. */
        WAIT_UNTIL_ON,
    }

    private var hasStreamed = false

    /** Kullanıcı çeviriyi başlattı. */
    fun reset() {
        hasStreamed = false
    }

    /** PS5'e bağlanıldı. */
    fun streamed() {
        hasStreamed = true
    }

    /** [awake]: aramada PS5'in durumu (null: yanıt vermedi). */
    fun action(awake: Boolean?): Action = when {
        awake != false -> Action.CONNECT
        hasStreamed -> Action.WAIT_UNTIL_ON
        else -> Action.WAKE
    }
}

/**
 * Bağlantı sık kopuyorsa görüntü 720p'ye düşürülür (Mac/iPhone ve Windows'taki QualityFallback ile aynı kural). 1080p akış
 * ~15 Mbit/sn, 720p ~10 Mbit/sn ister. Kablosuz ağda PS5 akışı birkaç dakikada bir kopuyor ya da görüntü takılıyordu
 * (GitHub #388, #401); altyazı okumak için 720p yeterlidir. [WINDOW_MS] içinde [DROPS_TO_LOWER] kopma olursa bu çeviri
 * boyunca 720p kullanılır.
 */
class QualityFallback {
    companion object {
        const val WINDOW_MS = 10 * 60_000L
        const val DROPS_TO_LOWER = 2

        /**
         * Kopma ağ kaynaklı mı (akış sürerken PS5 ile bağlantı gitti ya da görüntü kesildi). PS5'in reddi, başka cihazda
         * kullanım ya da durdurma sayılmaz: düşük çözünürlük bunlara çare değildir.
         */
        fun countsAsDrop(kind: DisconnectKind) = kind == DisconnectKind.NETWORK || kind == DisconnectKind.OTHER
    }

    private val drops = ArrayDeque<Long>()

    /** Görüntü 720p'ye düşürüldü mü. */
    var lowered = false
        private set

    /** Akış sürerken bağlantı koptu ya da görüntü takıldı. Bu kopmayla 720p'ye geçildiyse true. */
    fun dropped(nowMs: Long): Boolean {
        if (lowered) return false
        drops.addLast(nowMs)
        while (drops.isNotEmpty() && nowMs - drops.first() > WINDOW_MS) drops.removeFirst()
        if (drops.size < DROPS_TO_LOWER) return false
        lowered = true
        return true
    }
}

/**
 * Bağlı oturumda PS5'ten görüntü gelmiyor mu (Mac ve Windows'taki PictureWatchdog ile aynı kural).
 * libchiaki bir karenin FEC onarımı tutmayınca PS5'ten yeni anahtar kare (IDR) ister ve o gelene kadar bütün kareleri
 * atlar (enable_idr_on_fec_failure). İstek ya da IDR karesi kaybolursa eskiden bir daha istenmiyordu: bağlantı açık
 * kalıyor, ama bir daha hiç kare gelmiyordu. chiaki-stream-recovery.patch ile istek saniyede bir yinelenir. Bağlıyken
 * [STALL_AFTER_MS] boyunca hiç görüntü gelmezse oturum yine yeniden kurulur; yeni oturum anahtar kareyle başlar.
 * [STALL_AFTER_MS] eskiden 8 sn'ydi: ağ birkaç saniye bozulunca IDR yinelenmeden oturum kapatılıyor, PS5 ardından 30 sn
 * ile birkaç dakika yanıt vermiyordu (GitHub #593).
 */
class PictureWatchdog {
    companion object {
        /** Saniyede bir yinelenen IDR isteğine ve libchiaki'nin 5 sn'lik yeniden gönderme süresine yer kalır. */
        const val STALL_AFTER_MS = 15_000L
        /** Bağlandıktan sonra ilk kare bu sürede gelmezse çözücü türü değiştirilip yeniden denenir. */
        const val FIRST_PICTURE_MS = 5_000L
        /** Art arda bu kadar oturumda hiç görüntü gelmezse yeniden bağlanma bırakılır. */
        const val MAX_NO_PICTURE_SESSIONS = 3
        /** Yeniden bağlanırken görünen neden. */
        const val REASON = "no picture from the PS5"
    }

    /** Takılma sonrası ne yapılacak. */
    enum class Next {
        /** Oturumda görüntü gelmişti, sonra kesildi: aynı çözücüyle yeniden kur. */
        RECONNECT,
        /** Oturumda hiç görüntü gelmedi: çözücü türünü değiştirip ([swapDecoder]) yeniden kur. */
        RECONNECT_OTHER_DECODER,
        /** Art arda [MAX_NO_PICTURE_SESSIONS] oturumda görüntü yok: döngüyü bırak. */
        GIVE_UP,
    }

    /** Bağlıyken son görüntünün (ya da bağlanmanın) anı; bağlı değilken null. */
    private var since: Long? = null
    /** Bu oturumda görüntü geldi mi. */
    private var hasPicture = false
    /** Art arda hiç görüntü gelmeyen oturum sayısı; görüntü gelince sıfırlanır. */
    private var noPictureSessions = 0
    /** Oturumun bağlandığı an (ms) ve o andan beri gelen görüntü sayısı: kopma günlüğü için. */
    private var connectedAt = 0L
    private var pictures = 0L

    /** Bir sonraki oturum, üreticiye göre seçilen çözücü türünün (yazılım/donanım) tersiyle başlasın mı. */
    val swapDecoder: Boolean @Synchronized get() = noPictureSessions % 2 == 1

    /** Art arda görüntüsüz oturum sayısı (tanı). */
    val noPictureStreak: Int @Synchronized get() = noPictureSessions

    /** Kullanıcı başlattı ya da ağ değişti: sayaç sıfırdan. */
    @Synchronized fun reset() {
        since = null
        hasPicture = false
        noPictureSessions = 0
    }

    /** Oturum bağlandı: süre bağlanma anından sayılır (ilk kare hiç gelmezse de yakalanır). */
    @Synchronized fun connected(nowMs: Long) {
        since = nowMs
        hasPicture = false
        connectedAt = nowMs
        pictures = 0
    }

    /** Görüntü geldi (kare iş parçacığından). */
    @Synchronized fun picture(nowMs: Long) {
        if (since != null) {
            since = nowMs
            hasPicture = true
            pictures++
            noPictureSessions = 0
        }
    }

    /**
     * Kopma günlüğüne eklenen özet: oturum kaç saniye sürdü, kaç görüntü geldi, son görüntü kaç saniye önceydi. Bağlı
     * değilken null. Kopmanın nedenini ayırır: görüntü son ana kadar geliyorsa bağlantıyı PS5 ya da ağ kesmiştir;
     * saniyelerdir gelmiyorsa akış önce donmuştur.
     */
    @Synchronized fun summary(nowMs: Long): String? {
        val last = since ?: return null
        val lasted = (nowMs - connectedAt) / 1000
        return if (hasPicture) "oturum $lasted sn sürdü, $pictures görüntü geldi, sonuncusu ${(nowMs - last) / 100 / 10.0} sn önce"
        else "oturum $lasted sn sürdü, hiç görüntü gelmedi"
    }

    /** [stalledMs] boşluk bildirdi; oturum kapatılırken ne yapılacağı. */
    @Synchronized fun stalled(): Next {
        if (hasPicture) return Next.RECONNECT
        noPictureSessions++
        return if (noPictureSessions >= MAX_NO_PICTURE_SESSIONS) Next.GIVE_UP else Next.RECONNECT_OTHER_DECODER
    }

    /** Oturum kapandı ya da yeniden kuruluyor. */
    @Synchronized fun ended() {
        since = null
    }

    /**
     * Bağlıyken [STALL_AFTER_MS]'den (oturumda henüz hiç görüntü gelmediyse [FIRST_PICTURE_MS]'den) uzun süredir
     * görüntü yoksa boşluğun süresi (ms); yoksa null.
     */
    @Synchronized fun stalledMs(nowMs: Long): Long? {
        val last = since ?: return null
        val gap = nowMs - last
        return if (gap >= (if (hasPicture) STALL_AFTER_MS else FIRST_PICTURE_MS)) gap else null
    }
}

/**
 * PS5'e (ikinci hesapla) Remote Play bağlantısı kurar; görüntü MediaCodec'le yüzeysiz çözülür, her karenin parlaklık
 * düzlemi yerel tarafta kopyalanıp [onFrame]'e verilir (kare yalnız çağrı süresince geçerlidir; çözücünün iş
 * parçacığında çağrılır, kısa sürmeli). Ses kapalıdır, kol girdisi gönderilmez. Bağlantı koparsa
 * kendiliğinden yeniden bağlanır; PS5 uyuyorsa uyandırılır, adresi değiştiyse ağda yeniden bulunur. Windows'taki
 * StreamSession.cs ile aynı akış.
 */
class StreamSession(
    console: RegisteredConsole,
    private val accountId: ByteArray,
    private val onFrame: (VideoFrame) -> Unit,
    private val onState: (SessionState) -> Unit,
    private val onConsoleMoved: (RegisteredConsole) -> Unit = {},
    private val width: Int = 1920,
    private val height: Int = 1080,
    /** PS5 bu hesap için giriş şifresi isterse gönderilecek 4 hane (Ayarlar'da kayıtlıysa). */
    private val loginPasscode: String? = null,
) : FrameSource {
    private companion object {
        const val TAG = "CouchSubsSession"
        const val RELOCATE_INTERVAL_MS = 30_000L
    }

    @Volatile private var console = console
    private val queue = Executors.newSingleThreadScheduledExecutor { Thread(it, "CouchSubs session").apply { isDaemon = true } }
    private val policy = ReconnectPolicy()
    /** Dinlenmedeki PS5 yalnız çeviri başlarken uyandırılır (yalnız kuyrukta). */
    private val wakePolicy = WakePolicy()
    /** Bağlantı sık koparsa görüntü 720p'ye düşürülür (yalnız kuyrukta). */
    private val quality = QualityFallback()
    /** Geçerli oturum bağlandı mı (yalnız kuyrukta): yalnız akış sürerken olan kopmalar sayılır. */
    private var streaming = false
    /** Bağlıyken görüntü gelmezse oturum yeniden kurulur. */
    private val watchdog = PictureWatchdog()
    /** PS5'teki Uzaktan Oynatma çöktüyse en çok iki kez yeniden denenir (yalnız kuyrukta). */
    private val crashLimit = CrashRetryLimit()
    private val stateLock = Any()
    private var running = false
    private var generation = 0
    private var nextRelocate = 0L
    /** Son aramanın sonucu ve "bulunamadı" etiketi (yalnız kuyrukta). */
    private val search = ConsoleSearchState()

    /** Yalnız kuyrukta okunur/yazılır. */
    private var native = 0L
    private var nativeGeneration = 0

    override fun start() {
        val current = bump(true)
        queue.execute {
            policy.reset()
            wakePolicy.reset()
            watchdog.reset()
            crashLimit.reset()
            search.reset()
            connect(current)
        }
    }

    /** Bloklamaz: oturum arka planda kapatılır. */
    fun stop() {
        bump(false)
        queue.execute(::closeNative)
    }

    override fun dispose() {
        stop()
        queue.execute { queue.shutdown() }
    }

    /** Ağ değiştiğinde uygulama çağırır. */
    fun reconnectNow() {
        if (!isRunning) return
        val current = bump(true)
        queue.execute {
            closeNative()
            policy.reset()
            watchdog.reset()
            crashLimit.reset()
            connect(current)
        }
    }

    /** Çözücüden gelen kare sayısı (tanı: görüntü geliyor mu). */
    @Volatile override var framesReceived = 0L
        private set

    private val isRunning get() = synchronized(stateLock) { running }

    private fun bump(value: Boolean) = synchronized(stateLock) {
        running = value
        ++generation
    }

    private fun isCurrent(value: Int) = synchronized(stateLock) { running && generation == value }

    private fun connect(current: Int) {
        if (!isCurrent(current) || native != 0L) return
        emit(SessionState.Connecting)
        // Kayıtlı adreste başka bir PS5 yanıt verirse (aynı evde iki PS5, modem adresleri değiştirmiş; GitHub #425)
        // kayıtlı PS5 adıyla ağda aranır; bulunamazsa eskisi gibi o adrese bağlanılır.
        val atHost = ConsoleDiscovery.discover(console.host, 2000).firstOrNull()
        val info = if (atHost != null && ConsoleDiscovery.isRegistered(atHost, console.name)) atHost else {
            if (atHost != null) Log.i(TAG, "PS5 ${console.host} adresinde başka PS5 yanıt verdi (${atHost.name}), ${console.name} aranıyor")
            relocate() ?: atHost
        }
        if (search.searched(answered = info != null)) {
            val text = "PS5 aranıyor: art arda ${search.unanswered}. yanıtsız arama; bu cihaz: ${DeviceDiagnostics.line()}"
            Log.w(TAG, text)
            Backend.breadcrumb(text)
        }
        val action = wakePolicy.action(info?.isAwake)
        Log.i(TAG, if (info == null) "PS5 ${console.host} aramaya yanıt vermedi, yine de bağlanılıyor"
            else "PS5 ${info.name} ${info.host} " + when {
                info.isAwake -> "uyanık"
                action == WakePolicy.Action.WAKE -> "dinlenmede, uyandırılıyor"
                else -> "dinlenmede, açılması bekleniyor"
            })
        when (action) {
            WakePolicy.Action.CONNECT -> openSession(current)
            WakePolicy.Action.WAKE -> {
                try {
                    ConsoleDiscovery.wake(console)
                } catch (error: Exception) {
                    Log.w(TAG, "wake: ${error.message}")
                }
                waitForWake(current, System.currentTimeMillis() + 20_000)
            }
            // Kullanıcı PS5'i kapattı: yeniden açılmaz; aralıklı bakılır, PS5 açılınca bağlanılır.
            WakePolicy.Action.WAIT_UNTIL_ON ->
                scheduleReconnect(current, SessionState.Disconnected(DisconnectKind.CONSOLE_ASLEEP))
        }
    }

    private fun relocate(): ConsoleInfo? {
        val now = System.currentTimeMillis()
        if (now < nextRelocate) return null
        nextRelocate = now + RELOCATE_INTERVAL_MS
        val moved = ConsoleDiscovery.pickMoved(ConsoleDiscovery.discover(null, 3000), console.name)
        if (moved == null || moved.host == console.host) return null
        Log.i(TAG, "PS5 yeni adreste: ${console.host} -> ${moved.host}")
        console = console.withHost(moved.host)
        onConsoleMoved(console)
        return moved
    }

    private fun waitForWake(current: Int, deadline: Long) {
        queue.schedule({
            if (!isCurrent(current)) return@schedule
            when {
                ConsoleDiscovery.discover(console.host, 2000).any { it.isAwake } -> openSession(current)
                System.currentTimeMillis() < deadline -> waitForWake(current, deadline)
                else -> scheduleReconnect(current, SessionState.Disconnected(DisconnectKind.CONSOLE_ASLEEP))
            }
        }, 2, TimeUnit.SECONDS)
    }

    private fun openSession(current: Int) {
        if (!isCurrent(current) || native != 0L) return
        var described = false
        // Çözücünün çıkış iş parçacığından gelir. Kare Java'nın arabelleğindedir (Image.getPlanes yok): okunamayan
        // kare yerel tarafta atlanır, burada JNI'yi durduracak bir çağrı kalmadı.
        val frames = NativeFrameListener { buffer, frameWidth, frameHeight, rowStride, colorFormat, chroma ->
            framesReceived++
            watchdog.picture(SystemClock.elapsedRealtime())
            if (!described) {
                described = true
                val text = "PS5: ilk kare ${frameWidth}x$frameHeight biçim 0x${Integer.toHexString(colorFormat)}"
                Log.i(TAG, text)
                Backend.breadcrumb(text)
            }
            try {
                onFrame(VideoFrame(buffer, frameWidth, frameHeight, rowStride, colorFormat,
                    if (chroma) ChromaPlanes.after(buffer, frameWidth, frameHeight) else null))
            } catch (error: RuntimeException) {
                Log.e(TAG, "frame handler", error)
            }
        }
        val outcome = NativeOutcome()
        val listener = NativeSessionListener { type, reason, text -> handle(type, reason, text, current) }
        val c = console
        val swapDecoder = watchdog.swapDecoder
        if (swapDecoder) Backend.breadcrumb("PS5: önceki oturumda görüntü gelmedi; öbür çözücü türüyle deneniyor")
        // Bağlantı sık koptuysa 720p (yerel taraf yüksekliğe göre 720p ön ayarını seçer).
        val low = quality.lowered && height > 720
        val ptr = NativeBridge.sessionStart(c.host, c.registKey, c.morning, accountId, if (low) 1280 else width,
            if (low) 720 else height, frames,
            swapDecoder, listener, outcome)
        if (ptr == 0L) {
            Log.w(TAG, "PS5 oturumu başlatılamadı (${c.host}): ${outcome.errors}")
            scheduleReconnect(current, SessionState.Disconnected(DisconnectKind.OTHER, outcome.errorLines.lastOrNull() ?: "session could not be started"))
            return
        }
        native = ptr
        nativeGeneration = current
    }

    /** Oturumu kapatır (join içerir; yalnız kuyrukta, asla yerel geri çağrıdan değil). */
    private fun closeNative() {
        streaming = false
        val ptr = native
        if (ptr != 0L) {
            native = 0L
            // Çözücünün çıkış iş parçacığını da bekler: dönünce [onFrame] bir daha çağrılmaz.
            NativeBridge.sessionStop(ptr)
        }
        // Kapanırken gelen son kare bekçiyi yeniden kurmasın diye durdurmadan sonra.
        watchdog.ended()
    }

    /** libchiaki'nin iş parçacığından çağrılır. */
    private fun handle(type: Int, reason: Int, text: String?, eventGeneration: Int) {
        when (type) {
            NativeBridge.EVENT_CONNECTED -> queue.execute {
                if (nativeGeneration != eventGeneration || native == 0L) return@execute
                policy.connected(SystemClock.elapsedRealtime())
                wakePolicy.streamed()
                crashLimit.reset()
                search.connected()
                streaming = true
                watchdog.connected(SystemClock.elapsedRealtime())
                emit(SessionState.Streaming)
                scheduleWatch(eventGeneration)
            }
            // libchiaki olayı kilit tutarken verir; şifre kuyrukta gönderilir.
            NativeBridge.EVENT_LOGIN_PIN -> {
                val reply = LoginPasscode.reply(loginPasscode, incorrect = reason == 1)
                queue.execute {
                    if (nativeGeneration != eventGeneration || native == 0L) return@execute
                    when (reply) {
                        is LoginPasscode.Reply.Send -> {
                            Log.i(TAG, "PS5 giriş şifresi istedi; Ayarlar'daki şifre gönderiliyor")
                            NativeBridge.sessionSetLoginPin(native, reply.pin)
                        }
                        // Şifre yok ya da yanlış: yeniden denemek aynı yere çıkar.
                        is LoginPasscode.Reply.Stop -> {
                            bump(false)
                            closeNative()
                            emit(SessionState.Disconnected(reply.kind))
                        }
                    }
                }
            }
            NativeBridge.EVENT_QUIT -> {
                val general = DisconnectKind.fromNative(reason)
                queue.execute {
                    if (nativeGeneration != eventGeneration || native == 0L) return@execute
                    // "Unknown Session Request Error": asıl neden libchiaki'nin hata satırlarındadır (iPhone ve Mac ile aynı).
                    // Satırlarda neden yoksa PS5 oturumu başlatmamıştır: anlamsız İngilizce metin yerine REJECTED.
                    val hint = if (general == DisconnectKind.OTHER && text?.contains("Session Request", ignoreCase = true) == true)
                        DisconnectKind.sessionRequestHint(NativeBridge.sessionErrors(native)?.split('\n').orEmpty())
                        else null
                    val state = hint
                        ?: if (general == DisconnectKind.OTHER && text == DisconnectKind.UNKNOWN_SESSION_REQUEST)
                            SessionState.Disconnected(DisconnectKind.REJECTED)
                        else SessionState.Disconnected(general, text)
                    val kind = state.kind
                    Log.i(TAG, "Oturum kapandı: $kind ${state.detail.orEmpty()} $text")
                    // Bekçi değil libchiaki kapattı (PS5 ya da ağ); görüntünün son ana kadar gelip gelmediği nedeni ayırır.
                    watchdog.summary(SystemClock.elapsedRealtime())?.let {
                        val note = "PS5 oturumunu libchiaki kapattı ($kind); $it"
                        Log.i(TAG, note)
                        Backend.breadcrumb(note)
                    }
                    val wasStreaming = streaming
                    closeNative()
                    policy.ended(SystemClock.elapsedRealtime())
                    if (wasStreaming && QualityFallback.countsAsDrop(kind)) noteDrop()
                    if (kind == DisconnectKind.REGISTRATION_INVALID) {
                        // Kayıt geçersiz: yeniden denemek aynı yere çıkar (eskiden sonsuza kadar "Yeniden bağlanılıyor…").
                        bump(false)
                        emit(SessionState.Disconnected(kind, text))
                        return@execute
                    }
                    if (kind == DisconnectKind.CONSOLE_RP_CRASHED) {
                        val retry = crashLimit.crashed()
                        val note = "PS5'teki Uzaktan Oynatma çöktü (art arda ${crashLimit.crashes}); " +
                            if (retry) "yeniden deneniyor" else "yeniden bağlanma bırakıldı, PS5 tamamen kapatılıp açılmalı"
                        Log.w(TAG, note)
                        Backend.breadcrumb(note)
                        if (!retry) {
                            // PS5 kapatılıp açılmadan her deneme aynı yanıtı alır (eskiden sonsuz "yeniden bağlanılıyor").
                            bump(false)
                            emit(SessionState.Disconnected(kind))
                            return@execute
                        }
                    }
                    // PS5'in adresi TCP bağlantısını reddetti: PS5 yeni uyanıyor olabilir ya da adres başka bir cihaza geçmiş
                    // olabilir. Bir sonraki denemede beklemeden ağda da aranır (eşlemeyi yenilemek bunu çözmez).
                    if (kind == DisconnectKind.REFUSED) nextRelocate = 0L
                    scheduleReconnect(eventGeneration, state)
                }
            }
        }
    }

    /**
     * Bağlıyken saniyede bir bakılır: görüntü [PictureWatchdog.STALL_AFTER_MS]'den uzun süredir gelmiyorsa bağlantı açık
     * görünse de oturum kapatılıp yeniden kurulur (bkz. [PictureWatchdog]).
     */
    private fun scheduleWatch(sessionGeneration: Int) {
        try {
            queue.schedule({
                if (nativeGeneration != sessionGeneration || native == 0L || !isCurrent(sessionGeneration)) return@schedule
                val gap = watchdog.stalledMs(SystemClock.elapsedRealtime())
                if (gap == null) {
                    scheduleWatch(sessionGeneration)
                    return@schedule
                }
                val next = watchdog.stalled()
                val streak = watchdog.noPictureStreak
                val text = "PS5: ${gap / 1000} sn'dir görüntü yok (bağlantı açık, kare $framesReceived, " +
                    "art arda görüntüsüz oturum $streak); oturumu görüntü bekçisi kapatıyor: ${next.name}; " +
                    watchdog.summary(SystemClock.elapsedRealtime()).orEmpty()
                Log.w(TAG, text)
                Backend.breadcrumb(text)
                Telemetry.event("no_picture", "next" to next.name.lowercase(), "streak" to streak, "frames" to framesReceived)
                closeNative()
                policy.ended(SystemClock.elapsedRealtime())
                noteDrop()
                if (next == PictureWatchdog.Next.GIVE_UP) {
                    // İki çözücü türüyle de görüntü gelmedi: sonsuz "yeniden bağlanılıyor" döngüsü yerine dur ve söyle.
                    bump(false)
                    Backend.recordError(NoPictureException(text))
                    emit(SessionState.Disconnected(DisconnectKind.NO_PICTURE, PictureWatchdog.REASON))
                    return@schedule
                }
                scheduleReconnect(sessionGeneration, SessionState.Disconnected(DisconnectKind.OTHER, PictureWatchdog.REASON))
            }, 1, TimeUnit.SECONDS)
        } catch (error: java.util.concurrent.RejectedExecutionException) {
            // Oturum kapatıldı (dispose); bakacak bir şey yok.
        }
    }

    /** Akış sürerken bağlantı koptu: sık oluyorsa sonraki oturumlar 720p açılır. */
    private fun noteDrop() {
        if (!quality.dropped(SystemClock.elapsedRealtime())) return
        val text = "PS5 bağlantısı ${QualityFallback.WINDOW_MS / 60_000} dk içinde ${QualityFallback.DROPS_TO_LOWER} kez koptu; " +
            "görüntü 720p'ye düşürülüyor (daha az bant genişliği)"
        Log.w(TAG, text)
        Backend.breadcrumb(text)
    }

    private fun scheduleReconnect(current: Int, state: SessionState.Disconnected) {
        // Ağ hatasıyla düştüyse ve PS5 aramaya da yanıt vermediyse neden "bulunamadı"dır.
        val classified = search.classify(state, console.host)
        emit(classified)
        if (!isCurrent(current)) return
        queue.schedule({ connect(current) }, policy.nextDelaySeconds(inUse = state.kind == DisconnectKind.IN_USE).toLong(), TimeUnit.SECONDS)
    }

    private fun emit(state: SessionState) {
        try {
            onState(state)
        } catch (error: RuntimeException) {
            Log.e(TAG, "state handler", error)
        }
    }
}
