// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import com.couchsubs.mobile.R
import com.couchsubs.mobile.tv.android.AndroidInstallError
import com.couchsubs.mobile.tv.android.AndroidInstallException

/**
 * Çeviri başlayınca TV uygulamasını kendiliğinden açma neden olmadı (son deneme). Ana ekranda TV uygulaması bağlı değilken
 * tek satırla söylenir. Windows (TvOpenProblem) ve Mac/iPhone'daki (TVOpenProblem) ile aynı. Eskiden açma sessizce
 * başarısız oluyordu: kullanıcı TV'de CouchSubs'ı kendisinin açması gerektiğini bilmiyordu ("ilk başta olmadı, sonra oldu;
 * TV'den de uygulamayı açmak lazımmış", 21 Kas).
 */
enum class TvOpenProblem {
    /** LG/Samsung: TV yanıt vermedi (kapalı, başka ağda ya da açmayı reddetti). */
    UNREACHABLE,
    /** LG/Samsung: bu telefonun TV'den aldığı izin (anahtar) yok; TV'ye yeniden bağlanılmalı. */
    NOT_PAIRED,
    /** Android TV: ADB portuna ulaşılamadı (TV kapalı ya da ağ üzerinden hata ayıklama kapalı). */
    DEBUG_OFF,
    /** Android TV: TV bu telefonun hata ayıklama iznini onaylamamış (ADB eşleşmesi yok). */
    DEBUG_NOT_APPROVED,
    /** Samsung: açma komutu gitti ama TV uygulaması [TvSessionLauncher.SAMSUNG_OPEN_CHECK_MS] içinde bağlanmadı (TV komutu yok saydı). */
    NOT_OPENED,
    /**
     * Samsung: TV, CouchSubs'ın kurulu olduğunu doğrulamadı (listede yok ya da liste 3 sn'de gelmedi); açma komutu
     * gönderilmedi. Kurulu olmayan uygulamaya DEEP_LINK Smart Hub'ı mağazaya yollar, TV "Samsung sunucusuna bağlanılamıyor
     * (AS400)" der (Samsung 7 Series 2018, 21 Kas).
     */
    NOT_INSTALLED;

    companion object {
        /**
         * Bildirilen sorun, ekranda gösterilecek olana çevrilir: LG/Samsung'da kayıtlı anahtar yokken yanıt vermeyen TV "izin
         * yok" sayılır (TV'nin izin sorusu yanıtlanmamış).
         */
        fun shown(reported: TvOpenProblem?, brand: TvBrand, hasKey: Boolean): TvOpenProblem? =
            if (reported == UNREACHABLE && brand != TvBrand.ANDROID_TV && !hasKey) NOT_PAIRED else reported

        /** Android TV'de açılamamanın nedeni: TV hata ayıklama iznini onaylamadıysa ayrı, gerisi "ulaşılamıyor". */
        fun ofAndroidTv(error: Throwable): TvOpenProblem =
            when ((error as? AndroidInstallException)?.error) {
                AndroidInstallError.NOT_APPROVED, AndroidInstallError.NOT_PAIRED -> DEBUG_NOT_APPROVED
                else -> DEBUG_OFF
            }

        /** TV markasına göre tek cümle: CouchSubs TV'de nerede bulunur. */
        fun openOnTv(brand: TvBrand): Int =
            if (brand == TvBrand.ANDROID_TV) R.string.tv_open_on_tv_android else R.string.tv_open_on_tv_app_list

        /** Otomatik açmanın neden olmadığı (bilinmiyorsa null). */
        fun reason(problem: TvOpenProblem?): Int? = when (problem) {
            null -> null
            UNREACHABLE -> R.string.tv_open_unreachable
            NOT_PAIRED -> R.string.tv_open_not_paired
            DEBUG_OFF -> R.string.tv_open_debug_off
            DEBUG_NOT_APPROVED -> R.string.tv_open_debug_not_approved
            NOT_OPENED -> R.string.tv_open_not_opened
            NOT_INSTALLED -> R.string.tv_open_not_installed
        }
    }
}

/**
 * "Otomatik açmayı dene": ana ekrandan istenir, çeviri hizmetindeki açma döngüleri (LG bekçisi, Samsung, Android TV) bir
 * sonraki turda beklemeden açar.
 */
object TvOpenRetry {
    private val requested = java.util.concurrent.atomic.AtomicBoolean(false)
    fun request() = requested.set(true)
    /** İstek varsa bir kez true döner. */
    fun take(): Boolean = requested.getAndSet(false)
    fun clear() = requested.set(false)

    /**
     * En çok [ms] bekler; "Otomatik açmayı dene" istenirse hemen döner (açma döngülerinin varsayılan beklemesi). İstek
     * yüzünden döndüyse true.
     */
    fun waitOrRetry(ms: Long, step: Long = 1_000L): Boolean {
        var left = ms
        while (left > 0) {
            if (take()) return true
            Thread.sleep(minOf(step, left))
            left -= step
        }
        return false
    }
}

/**
 * Android TV bekçisinin "şimdi açmayı dene" kararı (Mac/iPhone'daki AndroidTVOpenRule ve Windows'taki AndroidTvOpenRule ile
 * aynı kural).
 *
 * X'te bildirildi (Android TV 8, çeviri MacBook'tan, beta.74): "TV'den uygulamayı açtığımda çevirili ekran gelip hemen başka
 * bir ekrana geçiyor, HDMI seçemiyorum". Bekçi TV uygulaması bağlı görünmediği her an, 30 sn'de bir ve sınırsız `am start`
 * gönderiyordu; kullanıcı CouchSubs'ı kumandadan açınca katmanın bağlantısı kapanıp sayfanınki kurulana kadar geçen birkaç
 * saniye de buna yetiyordu. TV uygulaması (0.9.54 ve öncesi) parametreli açılışta kayıtlı katman tercihine dönüp ekranı
 * kapatıyordu. Artık: bu çeviride bir kez bağlanan uygulama bir daha açılmaz; hiç bağlanmadıysa en çok [maxOpens] kez,
 * aralarında en az [intervalMs]; "Otomatik açmayı dene" ([reset]) sıfırlar. Uygulama TV'de zaten çalışıyorsa `am start` hiç
 * gönderilmez (AndroidTvInstaller.ALREADY_RUNNING).
 *
 * X'te bildirildi (Android TV, beta.77): "izni sürekli yeniden istiyor". Kanıtlı (kod): sınır yalnız gerçekten gönderilen
 * `am start`'ları sayıyordu. TV bu cihazı "Her zaman izin ver" işaretlenmeden onayladıysa ya da hiç onaylamadıysa her deneme
 * "açılamadı" oluyor, uygulama TV'de çalışıp bağlı değilse "zaten açık" oluyor, ikisi de sayılmıyordu: bekçi çeviri boyunca
 * 30 sn'de bir yeni ADB bağlantısı açıyor, TV her seferinde "Hata ayıklamaya izin verilsin mi?" diye soruyordu. (ADB anahtarı
 * kalıcıdır; soru anahtar değiştiği için değil, onay kalıcı verilmediği için yineleniyordu.) Artık her ADB bağlantısı, sonucu
 * ne olursa olsun bir deneme sayılır: çeviri başına en çok [maxOpens] bağlantı.
 */
class AndroidTvOpenRule(private val maxOpens: Int = DEFAULT_MAX_OPENS, private val intervalMs: Long = DEFAULT_INTERVAL_MS) {
    companion object {
        const val DEFAULT_MAX_OPENS = 3
        const val DEFAULT_INTERVAL_MS = 30_000L
    }

    /** Açılan ADB bağlantıları (açıldı, zaten açık ya da açılamadı); sınır bunu sayar. */
    var attempts = 0
        private set
    /** Gerçekten gönderilen `am start`'lar. */
    var opens = 0
        private set
    var everConnected = false
        private set
    private var lastAttempt: Long? = null

    /**
     * Bu kontrolde ADB bağlantısı açılıp açma denensin mi ([now]: ms, tekdüze saat); true dönerse deneme sayılır. Uygulama
     * bağlıyken hiç bağlantı açılmaz.
     */
    @Synchronized fun shouldTry(connected: Boolean, now: Long): Boolean {
        if (connected) { everConnected = true; return false }
        if (everConnected || attempts >= maxOpens) return false
        lastAttempt?.let { if (now - it < intervalMs) return false }
        lastAttempt = now
        attempts++
        return true
    }

    /** `am start` gerçekten gönderildi (uygulama kapalıydı). */
    @Synchronized fun opened() { opens++ }

    /** "Otomatik açmayı dene": yeniden en çok [maxOpens] deneme, beklemeden. */
    @Synchronized fun reset() {
        attempts = 0
        opens = 0
        everConnected = false
        lastAttempt = null
    }
}
