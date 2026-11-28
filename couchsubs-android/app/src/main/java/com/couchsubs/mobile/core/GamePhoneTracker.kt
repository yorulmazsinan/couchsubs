// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * Oyun telefonu kurallarının baktığı kare: [width]×[height] piksel, üstten ve soldan. Android'de çözücünün karesi YUV'dur;
 * kurallar Mac/iPhone (CGImage) ve Windows'takiyle aynı değerleri görsün diye renk burada RGB'ye çevrilmiş okunur.
 */
interface PhoneImage {
    val width: Int
    val height: Int

    /** (x, y) pikselinin tonu: 77·R + 150·G + 29·B (0–65280; 256'ya bölünce parlaklık). */
    fun tone(x: Int, y: Int): Int

    /** (x, y) pikselinin rengi, 0xRRGGBB. */
    fun rgb(x: Int, y: Int): Int

    /** [region]'ın gri kopyası (kumanda simgeleri ondan kesilir); kare bunu veremiyorsa null. */
    fun gray(region: CropRegion): GrayFrame? = null

    /** [region]'ın 64×12 gri izi ([RegionSignature]): her hücrenin ortasındaki piksel. */
    fun signature(region: CropRegion): ByteArray {
        val out = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT)
        if (width <= 0 || height <= 0) return out
        val left = region.left * width
        val top = region.top * height
        val w = (region.right - region.left) * width
        val h = (region.bottom - region.top) * height
        for (y in 0 until RegionSignature.HEIGHT) {
            val sy = (top + (y + 0.5) * h / RegionSignature.HEIGHT).toInt().coerceIn(0, height - 1)
            for (x in 0 until RegionSignature.WIDTH) {
                val sx = (left + (x + 0.5) * w / RegionSignature.WIDTH).toInt().coerceIn(0, width - 1)
                out[y * RegionSignature.WIDTH + x] = (tone(sx, sy) shr 8).toByte()
            }
        }
        return out
    }
}

/**
 * GTA 6'nın oyun içi telefonunu izler ("GTA 6'daki telefonu otomatik çevir"). Uyumlu gözlemlerle açılır ([OPEN_POINTS]):
 * iki sıkı gözlem, ya da bir sıkı gözlem ve onun yerinde gevşek doğrulama / yanları zayıf aday, ya da üç zayıf gözlem.
 * Tek bir menü ya da altyazı karesi telefon oturumu açmaz (Mac/iPhone GamePhoneTracker.swift, Windows
 * GamePhoneTracker.cs ile aynı kurallar).
 */
class GamePhoneTracker internal constructor(
    private val sight: (PhoneImage, GamePhoneGeometry.Pose?) -> Sighting,
    @Suppress("UNUSED_PARAMETER") marker: Unit,
) {
    constructor() : this({ image, near ->
        val search = GamePhoneGeometry.search(image, near)
        Sighting(search.pose, search.pose != null && search.probe.step == GamePhoneGeometry.Step.FOUND, search.probe)
    }, Unit) {
        holds = true
        glows = true
    }

    /**
     * Açık telefon arama ve izde ıskalanınca son yerinde ekranının ışığına bakılır mı ([PhoneGlow]; gerçek aramada ve ışık
     * denemelerinde).
     */
    internal var glows = false
    /** Son gerçek gözlemde ışıklı ekran (karanlık sahnede; yoksa null), alındığı an, ışıkla tutuluyor mu ve son ölçülen ışık. */
    private var glow: PhoneGlow.Glow? = null
    private var glowAt: Long? = null
    private var glowing = false
    private var lastGlow: PhoneGlow.Glow? = null

    /** Açık telefon ıskalanınca son yerinde izi karşılaştırılır mı ([PhonePrint]; gerçek aramada; denemelerin sahte gözlemlerinde kapalı). */
    private var holds = false
    /** Açık telefonun izi (son gerçek gözlemden), alındığı an ve iz tutuyor mu. */
    private var print: IntArray? = null
    private var printAt = 0L
    private var holding = false
    private var lastSimilarity = 0.0
    constructor(locateNear: (PhoneImage, GamePhoneGeometry.Pose?) -> GamePhoneGeometry.Pose?) :
        this({ image, near -> Sighting(locateNear(image, near), true, null) }, Unit)
    constructor(locate: (PhoneImage) -> GamePhoneGeometry.Pose?) : this({ image, _ -> Sighting(locate(image), true, null) }, Unit)

    /** Gözlem: bulunan yer, sıkı aramayla mı bulundu ve sıkı aramanın sonucu (gerçek aramada; denemelerde null). */
    class Sighting(val pose: GamePhoneGeometry.Pose?, val strict: Boolean, val probe: GamePhoneGeometry.Probe?)

    class Sample(val sampled: Boolean, val pose: GamePhoneGeometry.Pose?)

    private var lastTime: Long? = null
    private var shown: GamePhoneGeometry.Pose? = null
    private var clock = 0L
    private val trace = DropLog({ clock })

    /** Telefonun açılması, kapanması ve oynadığı için açılmaması altyazı günlüğüne ([PhoneTrace]; sınırlı). null: uygulamanın günlüğü. */
    @Volatile var onLog: ((String) -> Unit)? = null

    private fun note(reason: String) = trace.note(PhoneTrace.COMPONENT, reason, "", onLog)

    private var pending: GamePhoneGeometry.Pose? = null
    private var pendingAt = 0L
    private var pendingPoints = 0
    private var pendingMisses = 0
    private var pendingStrict = false
    private val missLog = PhoneMissLog()
    private val status = PhoneSearchStatus()

    /**
     * [frame]: platformun kare biçimi, durum satırı için ([PhoneSearchStatus]; Android: çözücü biçimi ve ham Y aralığı).
     * Yalnız satır yazılırken (30 sn'de bir) çağrılır.
     */
    @Synchronized
    fun sample(image: PhoneImage, now: Long, frame: (() -> String)? = null): Sample {
        lastTime?.let { if (now >= it && now - it < INTERVAL_MS) return Sample(false, shown) }
        lastTime = now
        clock = now
        val wasShown = shown != null
        // Açık telefonun ya da doğrulanmayı bekleyen gözlemin yerinde gevşek doğrulama da denenir ([GamePhoneGeometry.locate]
        // near): beyaz ya da mavi ekranlı uygulamada (haber, ayarlar, hava) telefonun yanları zemine karışıyor, sıkı arama
        // ıskalıyordu. Yeni telefonda sıkı arama ıskalarsa yanları zayıf aday ([GamePhoneGeometry.Probe.weak]) zayıf gözlem
        // sayılır.
        val seen = sight(image, shown ?: if (pendingFresh(now)) pending else null)
        var found = seen.pose
        var strict = seen.strict
        var probe = seen.probe
        if (found == null && shown == null) probe?.weak?.let {
            found = it
            strict = false
        }
        // Akıl sınırı: telefon ekranın küçük, dikey bir parçasıdır. Dışındaki bir aday (menüde ya da koyu ekranda yanlış
        // eşleşme) kabul edilmez; TV'de büyük opak telefon kutusu oyun görüntüsünü kapatırdı.
        found?.let {
            if (!plausible(it.bounds, image.width, image.height)) {
                if (strict) probe = probe?.copy(step = GamePhoneGeometry.Step.IMPLAUSIBLE)
                found = null
                strict = false
            }
        }
        // Açık telefon bu örnekte bulunamadı: son yerinde izi tutuyorsa telefon yerinde sayılır ([PhonePrint]). Karanlıkta
        // sıkı arama telefonu ara sıra buluyor, açılan telefon iki ıskada kapanıp yeniden açılmıyordu (X, beta-107: "bir kez
        // çevrildi, sonra kayboldu").
        var held = false
        lastSimilarity = 0.0
        val open = shown
        val kept = print
        if (holds && found == null && open != null && kept != null) {
            val hold = GamePhoneGeometry.hold(image, open, kept)
            lastSimilarity = hold.similarity
            if (hold.pose != null) {
                found = hold.pose
                strict = false
                held = true
            }
        }
        // Açık telefon aramada da izde de ıskalandı: karanlık sahnede ekranı son gerçek gözlemdeki kadar aydınlıksa ve çevresi
        // karanlıksa telefon yerinde sayılır, [PhoneGlow.HOLD_MS] dolana dek kapanmaz (#1443: kasa koyu ve düz, iz tutmuyor,
        // telefon ~1 sn'de bir kapanıp açılıyordu). Telefon indirilince son yerde ışık kalmaz, her zamanki sürede kapanır.
        var glowHeld = false
        var glowExpired = false
        lastGlow = null
        val recorded = glow
        if (glows && found == null && open != null && recorded != null) {
            if (elapsed(lastSeen, now) < PhoneGlow.HOLD_MS) {
                val measured = GamePhoneGeometry.glow(image, open)
                lastGlow = measured
                glowHeld = measured != null && PhoneGlow.holds(recorded, measured)
            } else {
                glowExpired = true
            }
        }
        val points = if (found == null) 0 else if (strict) STRONG_POINTS else WEAK_POINTS
        val current = shown
        var unseenMs = 0L
        var unseenMisses = 0
        var movedFrom: GamePhoneGeometry.Pose? = null
        val sighted = found
        if (current != null && sighted != null &&
            sighted.bounds.isClose(current.bounds, if (strict) STRICT_MOVE_TOLERANCE else SAME_TOLERANCE)) {
            // Açık telefonun yakınında tek gözlem: aynı telefon, yeri güncellenir. Sıkı aramanın bulduğu telefon daha çok
            // oynamış da olabilir (el hızlı oynadı): yine aynı telefon sayılır, önceden ıska sayılıp telefonu kapatıyordu.
            shown = sighted
            misses = 0
            lastSeen = now
            if (!held) {
                keepPrint(image, sighted, now)
                keepGlow(image, sighted, now)
            }
        } else if (current != null && (glowHeld || !closes(misses + 1, elapsed(lastSeen, now)))) {
            // Açık telefon tek bir karede bulunamadı ya da el titredi: hemen kapanmaz. Önceden tek ıska paneli kapatıyor,
            // yeniden açılış iki gözlem bekleyip bütün sayfayı yeniden çeviriyordu; çeviriler gidip geliyordu (X'teki
            // bildirim). Telefon gerçekten indirilince [MISS_GRACE_MS] sonra kapanır ([closes]).
            misses++
        } else if (current != null) {
            unseenMs = elapsed(lastSeen, now)
            unseenMisses = misses + 1
            shown = null
            misses = 0
            clearPending()
        } else if (sighted != null) {
            // Yeni telefon: doğrulanmayı bekleyen gözlemin yakınındaysa puanı eklenir, değilse yeni bekleyen gözlem olur.
            val waiting = pending
            if (waiting != null && sighted.bounds.isClose(waiting.bounds, SAME_TOLERANCE) && (pendingMisses == 0 || pendingFresh(now))) {
                pendingPoints += points
            } else {
                if (waiting != null && pendingMisses == 0) movedFrom = waiting
                if (waiting != null) missLog.unconfirmed(pendingStrict)
                pendingPoints = points
                pendingStrict = false
            }
            pending = sighted
            pendingAt = now
            pendingMisses = 0
            pendingStrict = pendingStrict || strict
            if (pendingPoints >= OPEN_POINTS) {
                shown = sighted
                misses = 0
                lastSeen = now
                clearPending()
                print = null
                glow = null
                glowAt = null
                keepPrint(image, sighted, now)
                keepGlow(image, sighted, now)
            }
        } else if (pending != null) {
            pendingMisses++
            if (!pendingFresh(now)) {
                missLog.unconfirmed(pendingStrict)
                clearPending()
            }
        }
        if (!wasShown && shown != null) note(PhoneTrace.OPENED)
        else if (wasShown && shown == null) {
            note(PhoneTrace.closed(unseenMs, unseenMisses))
            if (holds && print != null) note(PhoneTrace.printLost(lastSimilarity))
            val lost = lastGlow
            if (glowExpired) note(PhoneTrace.GLOW_EXPIRED)
            else if (glows && glow != null && lost != null) note(PhoneTrace.glowLost(lost.screen, lost.ring))
            print = null
            glow = null
            glowAt = null
            lastGlow = null
        }
        if (held && !holding) note(PhoneTrace.held(lastSimilarity))
        holding = held && shown != null
        val litNow = lastGlow
        if (glowHeld && !glowing && litNow != null) note(PhoneTrace.glowHeld(litNow.screen, litNow.ring))
        glowing = glowHeld && shown != null
        // Telefon art arda iki örnekte bulundu ama yeri çok oynadı: hiç açılmıyor, okuma da başlamıyor (önceden sessizdi).
        val moved = movedFrom
        if (shown == null && sighted != null && moved != null) note(PhoneTrace.moving(PhoneTrace.shift(sighted.bounds, moved.bounds)))
        // İlk açılış ıskalanınca nedeni (en ileri geçilen ölçüt, en iyi aday) sınırlı aralıkla günlüğe (#1251).
        val missed = probe
        if (shown != null) missLog.reset()
        else if (missed != null) missLog.note(missed, now) { note(it) }
        // Arama durumu 30 sn'de bir (telefon hiç bulunamasa da): ıska ölçütü, parlaklık, kare biçimi.
        if (status.note(probe, sighted != null, now)) {
            note(status.line(shown != null, image.width, image.height, PhoneSearchStatus.median(image), frame?.invoke()))
        }
        return Sample(true, shown)
    }

    /** Açık telefonun izini gerçek gözlemden alır (en çok [PRINT_REFRESH_MS]'de bir). */
    private fun keepPrint(image: PhoneImage, pose: GamePhoneGeometry.Pose, now: Long) {
        if (!holds) return
        if (print != null && now >= printAt && now - printAt < PRINT_REFRESH_MS) return
        print = GamePhoneGeometry.print(image, pose) ?: return
        printAt = now
    }

    /**
     * Açık telefonun ekran ışığını gerçek gözlemden alır (en çok [PRINT_REFRESH_MS]'de bir): karanlık sahnede ışıklı ekran
     * ([PhoneGlow.lit]) değilse null.
     */
    private fun keepGlow(image: PhoneImage, pose: GamePhoneGeometry.Pose, now: Long) {
        if (!glows) return
        val taken = glowAt
        if (taken != null && now >= taken && now - taken < PRINT_REFRESH_MS) return
        glow = GamePhoneGeometry.glow(image, pose)?.takeIf { PhoneGlow.lit(it) }
        glowAt = now
    }

    private fun pendingFresh(now: Long): Boolean = pending != null && now >= pendingAt && now - pendingAt <= PENDING_MS

    private fun clearPending() {
        pending = null
        pendingPoints = 0
        pendingMisses = 0
        pendingStrict = false
    }

    private var misses = 0
    /** Telefonun en son görüldüğü an (ms). */
    private var lastSeen = 0L

    @Synchronized
    fun reset() {
        lastTime = null
        shown = null
        misses = 0
        lastSeen = 0L
        clearPending()
        print = null
        holding = false
        glow = null
        glowAt = null
        glowing = false
        lastGlow = null
        missLog.reset()
        status.reset()
    }

    companion object {
        /**
         * Açık telefonun yeni gözlemi en çok bu kadar oynadıysa (kutunun her kenarı, kareye oranla) aynı telefondur; sıkı
         * aramanın gözleminde [STRICT_MOVE_TOLERANCE] (Mac/iPhone ve Windows ile aynı).
         */
        const val SAME_TOLERANCE = 0.035
        const val STRICT_MOVE_TOLERANCE = 0.1
        const val INTERVAL_MS = 330L

        /** Sıkı aramayla bulunan telefonun gözlem puanı. */
        const val STRONG_POINTS = 2
        /**
         * Gevşek doğrulamanın (doğrulanmayı bekleyen gözlemin yerinde hoparlör, kamera ve alt çentik) ya da yanları zayıf
         * adayın ([GamePhoneGeometry.WEAK_SIDE]) gözlem puanı.
         */
        const val WEAK_POINTS = 1
        /**
         * Yeni telefon, art arda uyumlu gözlemlerin puanı buna varınca açılır: iki sıkı gözlem (önceki kural), sıkı gözlem
         * ve gevşek doğrulama, ya da üç zayıf gözlem. Önceden yalnız art arda iki sıkı gözlem açıyordu: sıkı arama telefonu
         * ara sıra bulunca (açık kasa açık zeminde, el örtüyor, karanlık) telefon hiç açılmıyor, mesajları altyazı gibi
         * okunuyordu (#1251, beta-102; Mac/iPhone ve Windows ile aynı).
         */
        const val OPEN_POINTS = 3
        /**
         * Doğrulanmayı bekleyen gözlem, arada ıskalı örnek olsa da bu kadar süre (ms) geçerli kalır; ıskasız art arda
         * örnekler süreye bakılmadan birleşir (seyrek örneklemede de telefon açılır).
         */
        const val PENDING_MS = 1000L

        /** İz gerçek gözlemde en çok bu aralıkla (ms) yenilenir. */
        const val PRINT_REFRESH_MS = 1000L

        /** Denemeler: gözlem ve gücü (strict: sıkı arama; değilse gevşek doğrulama ya da yanları zayıf aday). */
        internal fun sighting(sight: (PhoneImage) -> Pair<GamePhoneGeometry.Pose, Boolean>?): GamePhoneTracker =
            GamePhoneTracker({ image, _ -> sight(image)?.let { Sighting(it.first, it.second, null) } ?: Sighting(null, false, null) }, Unit)

        /**
         * Açık telefon bu kadar süre (ms) görülmezse kapanır; çevirisi hemen kalkar (izleyici closePhone). Önceden süre
         * değil örnek sayılıyordu (art arda 4 ıska): örnekler seyrek geldiğinde (Android'de ağır kare, takılan akış) telefon
         * indirildikten 3–4 sn sonra kalkıyordu (#1334). Tek karelik ıska yine kapatmaz: en az [MINIMUM_MISSES] ıska
         * gerekir; yalnız telefon 2 × [MISS_GRACE_MS] boyunca hiç görülmediyse tek ıska yeter. 330 ms aralıkla ~1 sn (Mac ve
         * Windows ile aynı).
         */
        const val MISS_GRACE_MS = 900L
        /**
         * Altyazı süzgecinin açık telefonu bulunamadığı aramalarda tuttuğu arama sayısı ([SubtitlePipeline]); telefon
         * oturumunun kapanması süreyle ölçülür ([MISS_GRACE_MS]).
         */
        const val MISS_GRACE = 3
        const val MINIMUM_MISSES = 2
        /** Saat geri giderse süre ölçülemez: art arda bu kadar ıskada her durumda kapanır (eski kural). */
        const val MAXIMUM_MISSES = 4

        /** Açık telefon [misses] ıskadan, [unseenMs] görülmeden sonra kapansın mı. */
        fun closes(misses: Int, unseenMs: Long): Boolean =
            misses >= MAXIMUM_MISSES || (misses >= MINIMUM_MISSES && unseenMs >= MISS_GRACE_MS) || unseenMs >= 2 * MISS_GRACE_MS

        private fun elapsed(since: Long, now: Long): Long = if (now >= since) now - since else 0L

        /** Telefon kutusunun alanı (kareye oranla) bu aralıkta olmalı. */
        const val MIN_AREA = 0.04
        const val MAX_AREA = 0.35

        /**
         * Telefon kutusu akla yatkın mı: alanı karenin %4–%35'i, piksel olarak dikey (yükseklik/genişlik 0,9–2,6; eğik
         * telefonun sınır kutusu dikey telefondan geniştir), yüksekliği karenin en çok %85'i, genişliği en çok yarısı,
         * merkezi karenin sol kenarında ([GamePhoneGeometry.MIN_CENTER_X]'in solu; sol eldeki telefon geçer) ya da üst üçte
         * birinde değil.
         */
        fun plausible(region: CropRegion, width: Int, height: Int): Boolean {
            val w = region.right - region.left
            val h = region.bottom - region.top
            if (!(w > 0 && h > 0 && h <= 0.85 && w <= 0.5)) return false
            val area = w * h
            if (area < MIN_AREA || area > MAX_AREA) return false
            if (width >= 64) {
                val aspect = h * maxOf(1, height) / (w * maxOf(1, width))
                if (aspect < 0.9 || aspect > 2.6) return false
            }
            return (region.left + region.right) / 2 >= GamePhoneGeometry.MIN_CENTER_X && (region.top + region.bottom) / 2 >= 1.0 / 3
        }
    }
}

object GamePhoneGeometry {
    /** Telefonun üst (hoparlör) ve alt (tuş) yuvalarının karedeki yeri, kenarlara oranla. */
    data class Pose(val topX: Double, val topY: Double, val bottomX: Double, val bottomY: Double) {
        val bounds: CropRegion
            get() {
                val h = bottomY - topY
                val w = h * 225 / 400 * 0.25
                return CropRegion(top = topY + h * 0.012, bottom = bottomY - h * 0.015,
                    left = minOf(topX, bottomX) - w, right = maxOf(topX, bottomX) + w)
            }
    }

    private class Slot(val x: Double, val y: Int, val length: Int, val contrast: Int)

    /**
     * Yayın çözünürlüğünden bağımsız tek 400×225 algılama ızgarası, eksen başına iki örnek: kare 800×450'ye en yakın
     * komşuyla küçültülmüş gibi okunur (örnekler istenince, doğrudan kareden alınır).
     */
    private class Grid(
        private val image: PhoneImage,
        private val xs: IntArray = IntArray(800) { ((it + 0.5) * image.width / 800).toInt().coerceIn(0, image.width - 1) },
        private val ys: IntArray = IntArray(450) { ((it + 0.5) * image.height / 450).toInt().coerceIn(0, image.height - 1) },
        /** Parlaklık kazancı (256 = 1×; [darkGains]). */
        private val gain: Int = 256,
        /** Ton eşitleme ([equalization]): ham tonun (dört noktanın toplamı / 256) eşlendiği ton; null: kazanç. */
        private val map: IntArray? = null,
    ) {
        /** Kazançsız ham toplam: dört noktanın tonu × 256 (0–261120; bir ton 1024; [PhonePrint]). */
        fun raw(x: Int, y: Int): Int {
            val cx = (2 * x).coerceIn(0, 798)
            val cy = (2 * y).coerceIn(0, 448)
            return image.tone(xs[cx], ys[cy]) + image.tone(xs[cx + 1], ys[cy]) +
                image.tone(xs[cx], ys[cy + 1]) + image.tone(xs[cx + 1], ys[cy + 1])
        }

        fun at(x: Int, y: Int): Int {
            val sum = raw(x, y)
            if (map != null) return map[minOf(map.size - 1, sum shr 8)]
            return if (gain == 256) sum shr 10 else minOf(255L, (sum.toLong() * gain) shr 18).toInt()
        }

        fun withGain(gain: Int): Grid = Grid(image, xs, ys, gain)

        /** Ton eşitlemeli kopya ([equalization]). */
        fun equalized(): Grid {
            val counts = IntArray(1021)
            var total = 0
            for (y in 0 until 225 step 2) {
                for (x in 0 until 400 step 2) {
                    counts[minOf(1020, raw(x, y) shr 8)]++
                    total++
                }
            }
            return Grid(image, xs, ys, 256, equalization(counts, total))
        }

        /** Üst şeridin (satır 0–89, sütun 95–305) ortanca tonu, kazançsız; her üç noktada bir örnek. */
        fun level(): Int {
            val counts = IntArray(256)
            var total = 0
            for (y in 0 until 90 step 3) {
                for (x in 95..305 step 3) {
                    counts[raw(x, y) shr 10]++
                    total++
                }
            }
            var sum = 0
            for (tone in 0 until 256) {
                sum += counts[tone]
                if (2 * sum >= total) return tone
            }
            return 255
        }
    }

    private fun rounded(value: Double): Int = Math.rint(value).toInt()
    private fun limit(n: Int, low: Int, high: Int): Int = minOf(high, maxOf(low, n))

    /** Karenin içindeki dikdörtgen (piksel). */
    data class Area(val x: Int, val y: Int, val width: Int, val height: Int)

    /** Simsiyah şerit: örneklerin hepsi bu tondan koyu (0–255). Önceden 24'tü: karanlık sahnede (gece, karartılmış oyun) görüntünün kenar sütunları ve alt satırları da şerit sayılıp kırpılıyor, 16:9 olmayan pencerede (Remote Play, şeritli ya da başlık çubuklu) oyun görüntüsü küçük ve kaymış bulunuyor, telefon aranamıyordu. Oyun penceresinin şeritleri simsiyahtır (0–3). */
    const val DARK_TONE = 8

    private fun widescreen(width: Int, height: Int) = abs(width.toDouble() / height - 400.0 / 225) <= 0.04

    /**
     * Karedeki 16:9 oyun görüntüsü (piksel). Pencereden okunan kare (PS Remote Play, chiaki-ng, OBS penceresi) başlık
     * çubuğunu ve pencere görüntüden farklı oransa siyah şeritleri de taşır; önceden telefon yalnız tam 16:9 karede
     * aranıyordu, pencerede hiç bulunmuyordu (ne otomatik telefon okuması ne "Ekranı çevir"in telefon kartı). Alttaki ve
     * yanlardaki simsiyah şeritler atılır, görüntü kalan genişliğin 16:9'u kadar yüksekliktedir ve alta yaslıdır (başlık
     * çubuğu üstte). Kare zaten 16:9 ise tamamı; görüntü bulunamazsa null (Mac/iPhone ve Windows ile aynı kural). Android
     * kendi akışını okur (hep 16:9); kural platformlar aynı kalsın diye burada da var.
     */
    fun picture(width: Int, height: Int, tone: (Int, Int) -> Int): Area? {
        if (width < 400 || height < 225) return null
        if (widescreen(width, height)) return Area(0, 0, width, height)
        val columns = IntArray(64) { minOf(width - 1, ((it + 0.5) * width / 64).toInt()) }
        fun darkRow(y: Int) = columns.all { tone(it, y) < DARK_TONE }
        var bottom = height
        while (bottom > height / 2 && darkRow(bottom - 1)) bottom--
        // Yan şeritlere başlık çubuğunun altından bakılır (başlık çubuğu bütün genişlikte uzanır).
        val from = height * 2 / 5
        val rows = IntArray(48) { from + ((it + 0.5) * (bottom - from) / 48).toInt() }
        fun darkColumn(x: Int) = rows.all { tone(x, it) < DARK_TONE }
        var left = 0
        var right = width
        while (left < width / 4 && darkColumn(left)) left++
        while (right > width * 3 / 4 && darkColumn(right - 1)) right--
        var w = right - left
        var h = Math.round(w * 9 / 16.0).toInt()
        if (h > bottom) {
            h = bottom
            w = Math.round(h * 16 / 9.0).toInt()
            left = (left + right - w) / 2
        }
        if (w < 400 || h < 225 || left < 0 || left + w > width) return null
        return Area(left, bottom - h, w, h)
    }

    /** Karenin bir parçası, kendi başına bir kare gibi. */
    private class Cropped(private val image: PhoneImage, private val area: Area) : PhoneImage {
        override val width: Int get() = area.width
        override val height: Int get() = area.height
        override fun tone(x: Int, y: Int): Int = image.tone(area.x + x, area.y + y)
        override fun rgb(x: Int, y: Int): Int = image.rgb(area.x + x, area.y + y)
    }

    /**
     * Karedeki telefon. [near]: açık telefonun son yeri; sıkı arama ıskalarsa o yerin hemen çevresinde gevşek doğrulama
     * yapılır ([confirmPicture]): hoparlör yarığı ve kamera üstte, alt çentik altta aynı yerde duruyorsa telefon
     * yerindedir. Sinan Bey (beta.100, 3418–3425): beyaz/mavi ekranlı uygulamalarda (haber, makale, hava, ayarlar,
     * eklenti) telefonun yan kenarları elin ve gövdenin rengine karışıyor, sıkı arama telefonu kaybediyordu; telefon
     * kaybolunca balonlar kalkıyor ("arada kaçıyor", 3417), telefonun yazıları altyazıya (3418, 3420, 3421) ve ekran
     * yazısı kutularına (3420–3425) gidiyordu. Gevşek doğrulama yalnız açık telefonun yerinde yapılır: yeni telefon yine
     * sıkı aramayla ve iki gözlemle açılır (Mac/iPhone ve Windows ile aynı).
     */
    fun locate(image: PhoneImage, near: Pose? = null): Pose? = search(image, near).pose

    /**
     * Sıkı aramanın ıska nedeni: aramanın geçemediği ilk ölçüt (sırayla). Telefon ekrandayken ilk açılış ıskalanınca
     * hangi ölçütün tuttuğu günlükte görünsün diye (#1251; Mac/iPhone ve Windows ile aynı adlar ve sıra).
     */
    enum class Step {
        /** Karede 16:9 oyun görüntüsü yok. */
        NO_PICTURE,
        /** Üst şeritte hoparlör yarığına benzer koyu çizgi yok. */
        NO_TOP_SLOT,
        /** Üst şeritte çok aday (menü, yazı satırları): arama bırakıldı. */
        TOP_CROWDED,
        /** Hoparlör yarığının yanında ön kamera yok. */
        NO_CAMERA,
        /** Alt şeritte alt çentiğe benzer koyu çizgi yok. */
        NO_BOTTOM_SLOT,
        /** Alt şeritte çok aday: arama bırakıldı. */
        BOTTOM_CROWDED,
        /** Yarık ile çentik telefon boyunda ve oranında değil. */
        SHAPE,
        /** Yarığın ya da çentiğin çevresi düz kasa değil. */
        RIM,
        /** Telefonun yan kenarları zayıf (açık kasa açık zeminde, el örtüyor). */
        SIDES,
        /** Sıkı arama buldu ama kutu akla yatkın değil ([GamePhoneTracker.plausible]; izleyici koyar). */
        IMPLAUSIBLE,
        /** Bulundu. */
        FOUND,
    }

    /** Yan kenarların sıkı aramadaki eşiği (ikisi de en az bu kadar güçlü olmalı). */
    const val SIDE_THRESHOLD = 12

    /**
     * Yanları zayıf adayın zayıf gözlem sayılması için zayıf yanının en az gücü. Gerçek telefonsuz karelerin
     * (testdata/frames; karartılmış, açılmış, düşük karşıtlıklı hâlleriyle) hiçbiri yan ölçütüne gelmiyor; gerçek telefon
     * (480p akış, yukarıda tutulan) 10–11'de kalıp bulunmuyordu (Mac/iPhone ve Windows ile aynı).
     */
    const val WEAK_SIDE = 8

    /**
     * Sıkı aramanın sonucu: [step] ıskanın nedeni; [side] yan ölçütüne gelen adaylardan zayıf yanı en güçlü olanın zayıf
     * yanı (yoksa -1); [candidate] o aday (yarık, kamera, çentik, oran ve kasa tutuyor, yanları zayıf). Aday tek başına
     * telefon açmaz.
     */
    data class Probe(
        val step: Step,
        val side: Int = -1,
        val candidate: Pose? = null,
        /** Üst şeridin ortanca tonu (0–255; -1: ölçülmedi). */
        val level: Int = -1,
        /** Sonucu veren aramanın kazancı (256 = 1×; [darkGains]). */
        val gain: Int = 256,
    ) {
        /** Zayıf gözlem sayılan aday ([WEAK_SIDE]). */
        val weak: Pose? get() = if (side >= WEAK_SIDE) candidate else null
    }

    /** Karedeki 16:9 oyun görüntüsü ([picture]) ve yerlerin kare ile görüntü arasında taşınması. */
    private class View(val image: PhoneImage, private val area: Area, private val w: Double, private val h: Double) {
        /** Karedeki yer görüntünün içine. */
        fun inside(pose: Pose) = Pose((pose.topX * w - area.x) / area.width, (pose.topY * h - area.y) / area.height,
            (pose.bottomX * w - area.x) / area.width, (pose.bottomY * h - area.y) / area.height)

        /** Görüntüdeki yer karenin içine. */
        fun outside(pose: Pose) = Pose((area.x + pose.topX * area.width) / w, (area.y + pose.topY * area.height) / h,
            (area.x + pose.bottomX * area.width) / w, (area.y + pose.bottomY * area.height) / h)
    }

    private fun view(image: PhoneImage): View? {
        if (image.width < 400 || image.height < 225) return null
        val w = image.width.toDouble()
        val h = image.height.toDouble()
        if (widescreen(image.width, image.height)) return View(image, Area(0, 0, image.width, image.height), w, h)
        val area = picture(image.width, image.height) { x, y -> image.tone(x, y) shr 8 } ?: return null
        return View(Cropped(image, area), area, w, h)
    }

    /** Telefonun izi ([PhonePrint]): [pose]'taki telefonun kasasından üst ve alt şeritte örnekler (kazançsız ham ton). */
    fun print(image: PhoneImage, pose: Pose): IntArray? {
        val view = view(image) ?: return null
        val grid = Grid(view.image)
        return PhonePrint.samples(view.inside(pose), 0, 0, grid::raw)
    }

    /** Telefonun ekran ışığı ([PhoneGlow]); görüntü bulunamazsa null. */
    fun glow(image: PhoneImage, pose: Pose): PhoneGlow.Glow? {
        val view = view(image) ?: return null
        val grid = Grid(view.image)
        return PhoneGlow.measure(view.inside(pose), grid::raw)
    }

    /** İzin sonucu: tutarsa bulunduğu yer (kayma kadar oynamış), tutmazsa null; en iyi benzerlik. */
    class Hold(val pose: Pose?, val similarity: Double)

    /** Açık telefonun son yerinde izi tutuyor mu ([PhonePrint.match]). */
    fun hold(image: PhoneImage, pose: Pose, print: IntArray): Hold {
        val view = view(image) ?: return Hold(null, 0.0)
        val grid = Grid(view.image)
        val local = view.inside(pose)
        val match = PhonePrint.match(print, local, grid::raw)
        if (match.similarity < PhonePrint.HOLD_SIMILARITY) return Hold(null, match.similarity)
        val moved = Pose(local.topX + match.dx / 400.0, local.topY + match.dy / 225.0,
            local.bottomX + match.dx / 400.0, local.bottomY + match.dy / 225.0)
        return Hold(view.outside(moved), match.similarity)
    }

    /** Arama: bulunan telefon (sıkı arama ya da [near]'da gevşek doğrulama) ve sıkı aramanın sonucu. */
    class Search(val pose: Pose?, val probe: Probe)

    /** [locate]; [Search.probe]: sıkı aramanın ıska nedeni ve en iyi adayı (karenin tamamına göre). */
    fun search(image: PhoneImage, near: Pose? = null): Search {
        if (image.width < 400 || image.height < 225) return Search(null, Probe(Step.NO_PICTURE))
        if (widescreen(image.width, image.height)) return locatePicture(image, near)
        val area = picture(image.width, image.height) { x, y -> image.tone(x, y) shr 8 } ?: return Search(null, Probe(Step.NO_PICTURE))
        val w = image.width.toDouble()
        val h = image.height.toDouble()
        // Açık telefonun yeri görüntünün içine taşınır.
        val local = near?.let { pose ->
            Pose((pose.topX * w - area.x) / area.width, (pose.topY * h - area.y) / area.height,
                (pose.bottomX * w - area.x) / area.width, (pose.bottomY * h - area.y) / area.height)
        }
        val inside = locatePicture(Cropped(image, area), local)
        fun x(value: Double) = (area.x + value * area.width) / w
        fun y(value: Double) = (area.y + value * area.height) / h
        fun outside(pose: Pose) = Pose(x(pose.topX), y(pose.topY), x(pose.bottomX), y(pose.bottomY))
        return Search(inside.pose?.let(::outside), inside.probe.copy(candidate = inside.probe.candidate?.let(::outside)))
    }

    private fun locatePicture(image: PhoneImage, near: Pose? = null): Search {
        if (image.width < 400 || image.height < 225 || !widescreen(image.width, image.height)) return Search(null, Probe(Step.NO_PICTURE))
        val whole = Grid(image)
        val level = whole.level()
        val first = strictPicture(whole)
        if (first.pose != null) return Search(first.pose, first.probe.copy(level = level))
        var probe = first.probe.copy(level = level)
        val gains = darkGains(level)
        // Karanlık sahnede kazançlardan sonra ton eşitleme ([equalization]).
        val passes = if (level < DARK_LEVEL) gains + EQUALIZED else gains
        for (gain in passes) {
            val dark = strictPicture(if (gain == EQUALIZED) whole.equalized() else whole.withGain(gain))
            if (dark.pose != null) return Search(dark.pose, dark.probe.copy(level = level, gain = gain))
            // Iskada en ileri geçilen ölçüt ve en iyi aday bütün aramalardan.
            if (dark.probe.step > probe.step) probe = probe.copy(step = dark.probe.step, gain = gain)
            if (dark.probe.side > probe.side) probe = probe.copy(side = dark.probe.side, candidate = dark.probe.candidate)
        }
        if (near == null) return Search(null, probe)
        val confirmed = confirmPicture(whole, near) ?: gains.firstNotNullOfOrNull { confirmPicture(whole.withGain(it), near) }
            ?: if (level < DARK_LEVEL) confirmPicture(whole.equalized(), near) else null
        return Search(confirmed, probe)
    }

    /** Karanlık sahne: üst şeridin ortanca tonu bundan azsa (0–255) sıkı arama kazançla da yapılır ([darkGains]). */
    const val DARK_LEVEL = 56
    /** Kazançlı aramada üst şeridin ortanca tonunun en çok taşındığı ton; denenen kazançlar (256 = 1×). */
    const val DARK_TARGET = 96
    val GAIN_STEPS = intArrayOf(384, 640, 1024)

    /** Kazanç yerine ton eşitleme ([equalization]): [Probe.gain]'de bu değer. */
    const val EQUALIZED = 0

    /**
     * Ton eşitleme: ızgaranın ham tonlarının (çeyrek ton adımıyla; [counts], toplam [total]) sırası 0–255'e yayılır (her ton,
     * kendinden koyu ve yarısı kendisiyle aynı noktaların oranı). Parlaklıktan, gamadan ve gece renk ayarından bağımsızdır:
     * tonları aynı sırada kalan her karartma aynı ızgarayı verir. Kazanç ([darkGains]) karanlık sahnede yalnız ×4'e kadar
     * aydınlatıyor, çok karanlıkta (üst şerit 10/255'ten koyu) ve gamayla koyulaşmış görüntüde (açık kasa açık kalır,
     * gölgeler kararır) sıkı arama hoparlör yarığında, kamerada ya da kasa kenarında kalıyordu (X, beta-107: telefon gündüz
     * çevriliyor, gece ve kapalı yerde çevrilmiyor; günlükte parlaklık 7–60/255). Karanlık sahnede kazançlardan sonra
     * denenir (Mac/iPhone ve Windows ile aynı).
     */
    fun equalization(counts: IntArray, total: Int): IntArray {
        val map = IntArray(counts.size)
        var below = 0
        for (tone in counts.indices) {
            map[tone] = minOf(255, 255 * (2 * below + counts[tone]) / maxOf(1, 2 * total))
            below += counts[tone]
        }
        return map
    }

    /**
     * Karanlık sahnede denenen kazançlar (256 = 1×; küçükten büyüğe); sahne karanlık değilse boş. Kullanıcı bildirimi (X,
     * beta.104): "telefonda parlaklık varsa çeviri oluyor karanlıksa olmuyor". Gece ya da karanlık odada telefonun kasası
     * koyu, hoparlör yarığıyla kasa arasındaki fark mutlak eşiğin (14–20 ton) altında kalıyordu; sıkı arama hoparlör
     * yarığında kalıyor, telefon hiç açılmıyordu. Ölçütler aynı, yalnız ızgara aydınlatılır. Sahne karanlık ama telefon
     * aydınlıksa büyük kazanç kasayı doyurur: kazançlar küçükten denenir, üst şeridi [DARK_TARGET]'tan çok aydınlatan
     * kazanç denenmez (Mac/iPhone ve Windows ile aynı).
     */
    fun darkGains(level: Int): List<Int> {
        if (level >= DARK_LEVEL) return emptyList()
        val most = 256 * DARK_TARGET / maxOf(8, level)
        val steps = GAIN_STEPS.filter { it <= most }
        return steps.ifEmpty { listOf(GAIN_STEPS[0]) }
    }

    /**
     * Gevşek doğrulamada yarıklar açık telefonun son yerinden yatayda ve dikeyde en çok bu kadar (400×225 ızgarada) uzak
     * olabilir: izleyicinin aynı telefon saydığı oynama kadar ([GamePhoneTracker.SAME_TOLERANCE], karenin %3,5'i). Önceden
     * her yönde 4'tü (yatayda %1, dikeyde %1,8): el titreyince ya da telefon kaldırılınca 330 ms'de %2 oynayan telefon,
     * sıkı arama da ıskalarsa ~1,1 sn sonra kapanıyordu (#1251, beta-104 günlüğü: "telefon kapandı (1141 ms görülmedi,
     * 3 ıska)", telefon ekranda; Mac/iPhone ve Windows ile aynı).
     */
    const val CONFIRM_REACH_X = 14.0
    const val CONFIRM_REACH_Y = 8.0

    /**
     * Yarıkların arandığı en sağ sütun (400×225 ızgarada; arama [SCAN_LEFT]'ten başlar). Önceden 294'tü (karenin %73,5'i): GTA 6
     * telefonu sağ elde ~%70'te durur, hoparlör yarığının sağ ucu sınıra değiyordu; telefon %1,5 sağa oynayınca yarık
     * kesiliyor, sıkı arama da gevşek doğrulama da "hoparlör yarığı yok"ta kalıyordu (#1251, beta-104 günlüğü; Mac/iPhone
     * ve Windows ile aynı).
     */
    const val SCAN_RIGHT = 324

    /**
     * Yarıkların arandığı en sol sütun: [SCAN_RIGHT]'ın aynası (400 − 324). Telefon sol elde tutulunca (#1385, beta-105)
     * görüntü aynalanır, hoparlör yarığı karenin ~%30'unda durur; arama önceden 105'ten (%26) başlıyordu, telefon biraz sola
     * oynayınca yarık kesiliyordu (Mac/iPhone ve Windows ile aynı).
     */
    const val SCAN_LEFT = 400 - SCAN_RIGHT

    /**
     * Telefon kutusunun merkezi bu sınırın solundaysa akla yatkın değil (karenin sol kenarındaki HUD, harita). Önceden 0,35'ti:
     * sol eldeki telefonun merkezi ~0,30'da kaldığından izleyici onu hiç açmıyordu, telefon ne okunuyor ne de ekran yazısından
     * dışlanıyordu (#1385; Mac/iPhone ve Windows ile aynı).
     */
    const val MIN_CENTER_X = 0.2

    /**
     * Açık telefonun son yerinde gevşek doğrulama: üstte kameralı hoparlör yarığı ve altta alt çentik, son yerin
     * [CONFIRM_REACH_X]/[CONFIRM_REACH_Y] kadar çevresinde, sıkı aramayla aynı boy ve oran kurallarıyla; yan kenarların ve çerçevenin gücüne
     * bakılmaz (beyaz ekranda yanlar zemine karışır). Bulunmazsa null.
     */
    internal fun confirmPicture(image: PhoneImage, near: Pose): Pose? {
        val whole = Grid(image)
        val level = whole.level()
        return confirmPicture(whole, near) ?: darkGains(level).firstNotNullOfOrNull { confirmPicture(whole.withGain(it), near) }
            ?: if (level < DARK_LEVEL) confirmPicture(whole.equalized(), near) else null
    }

    /**
     * Gevşek doğrulamanın tarandığı satırlar: `center ± CONFIRM_REACH_Y`, `low until high` şeridinin içinde; şeritle
     * kesişmiyorsa ya da yer sayı değilse null. #1369 (beta-104, Mac): son yer şeridin dışında kalınca (eksi ya da karenin
     * altını aşan yer) Mac/iPhone'da aralık ters kuruluyor, uygulama çöküyordu; burada çok büyük yer `toInt` sonrası
     * toplamada taşıyordu. Önce kırpılır, boşsa atlanır (Mac/iPhone ve Windows ile aynı).
     */
    internal fun confirmRows(center: Double, low: Int, high: Int): IntRange? {
        if (!center.isFinite() || low >= high) return null
        val reach = CONFIRM_REACH_Y.toInt()
        val c = rounded(center.coerceIn((low - reach - 1).toDouble(), (high + reach + 1).toDouble()))
        val from = maxOf(low, c - reach)
        val to = minOf(high, c + reach + 1)
        return if (from < to) from until to else null
    }

    private fun confirmPicture(grid: Grid, near: Pose): Pose? {
        val topX = near.topX * 400
        val topY = near.topY * 225
        val bottomX = near.bottomX * 400
        val bottomY = near.bottomY * 225
        if (!topX.isFinite() || !bottomX.isFinite()) return null
        val upperRows = confirmRows(topY, 17, 75) ?: return null
        val lowerRows = confirmRows(bottomY, 145, 217) ?: return null
        val upper = slots(grid, upperRows, 8..19, 12).filter { abs(it.x - topX) <= CONFIRM_REACH_X && hasCamera(grid, it) }
        val lower = slots(grid, lowerRows, 5..14, 16).filter { abs(it.x - bottomX) <= CONFIRM_REACH_X }
        var best = Double.POSITIVE_INFINITY
        var pose: Pose? = null
        for (top in upper) {
            for (bottom in lower) {
                val h = (bottom.y - top.y).toDouble()
                val dx = bottom.x - top.x
                if (!(h >= 115 && h <= 179 && abs(dx) <= h * 0.24 &&
                        bottom.length >= top.length * 0.46 && bottom.length <= top.length &&
                        h >= 7.9 * top.length && h <= 16.5 * top.length &&
                        h >= 12 * bottom.length && h <= 30 * bottom.length)) continue
                val distance = abs(top.x - topX) + abs(top.y - topY) + abs(bottom.x - bottomX) + abs(bottom.y - bottomY)
                if (distance < best) {
                    best = distance
                    pose = Pose(top.x / 400, top.y / 225.0, bottom.x / 400, bottom.y / 225.0)
                }
            }
        }
        return pose
    }

    private fun strictPicture(grid: Grid): Search {
        // Olağan oyun görüntüsü burada biter. Gövdeye ancak üst bantta hem hoparlör hem kamera görülünce bakılır.
        val speakers = scan(grid, 17 until 75, 8..19, 12)
        if (speakers.slots.isEmpty()) return Search(null, Probe(if (speakers.crowded) Step.TOP_CROWDED else Step.NO_TOP_SLOT))
        val upper = speakers.slots.filter { hasCamera(grid, it) }
        if (upper.isEmpty()) return Search(null, Probe(Step.NO_CAMERA))
        val notches = scan(grid, 145 until 217, 5..14, 16)
        if (notches.slots.isEmpty()) return Search(null, Probe(if (notches.crowded) Step.BOTTOM_CROWDED else Step.NO_BOTTOM_SLOT))
        var best = 0.0
        var pose: Pose? = null
        var step = Step.SHAPE
        var weakSide = -1
        var weak: Pose? = null
        for (top in upper) {
            for (bottom in notches.slots) {
                val h = (bottom.y - top.y).toDouble()
                val dx = bottom.x - top.x
                if (!(h >= 115 && h <= 179 && abs(dx) <= h * 0.24 &&
                        bottom.length >= top.length * 0.46 && bottom.length <= top.length &&
                        h >= 7.9 * top.length && h <= 16.5 * top.length &&
                        h >= 12 * bottom.length && h <= 30 * bottom.length)) continue
                if (step < Step.RIM) step = Step.RIM
                if (!(smoothRim(grid, top, dx, h) && smoothRim(grid, bottom, dx, h))) continue
                if (step < Step.SIDES) step = Step.SIDES
                val left = sideStrength(grid, top, dx, h, -1)
                val right = sideStrength(grid, top, dx, h, 1)
                val found = Pose(top.x / 400, top.y / 225.0, bottom.x / 400, bottom.y / 225.0)
                if (left < SIDE_THRESHOLD || right < SIDE_THRESHOLD) {
                    if (minOf(left, right) > weakSide) {
                        weakSide = minOf(left, right)
                        weak = found
                    }
                    continue
                }
                val edges = minOf(left, right) + 0.25 * maxOf(left, right)
                val rims = rimBoundary(grid, top, dx, h, lower = false) + rimBoundary(grid, bottom, dx, h, lower = true)
                val score = edges + 0.1 * minOf(top.contrast, bottom.contrast) + 0.5 * rims
                if (score > best) {
                    best = score
                    pose = found
                }
            }
        }
        return if (pose != null) Search(pose, Probe(Step.FOUND)) else Search(null, Probe(step, weakSide, weak))
    }

    private fun slots(grid: Grid, rows: IntRange, lengths: IntRange, maximum: Int): List<Slot> =
        scan(grid, rows, lengths, maximum).slots

    private class Scan(val slots: List<Slot>, val crowded: Boolean)

    /** Şeritteki yarıklar; [maximum]'dan çoksa hiçbiri (crowded: menü ya da yazı satırları, telefon aranmaz). */
    private fun scan(grid: Grid, rows: IntRange, lengths: IntRange, maximum: Int): Scan {
        if (rows.isEmpty() || rows.first < 4 || rows.last > 220) return Scan(emptyList(), false)
        val left = SCAN_LEFT - 10
        val width = SCAN_RIGHT + 11 - left
        val count = rows.last - rows.first + 1
        val band = IntArray((count + 8) * width)
        for (y in (rows.first - 4)..(rows.last + 4)) {
            val row = (y - rows.first + 4) * width
            for (i in 0 until width) band[row + i] = grid.at(left + i, y)
        }
        val found = mutableListOf<Slot>()
        for (y in rows) {
            val row = (y - rows.first + 4) * width
            var start: Int? = null
            for (x in (SCAN_LEFT - left)..(SCAN_RIGHT - left)) {
                val p = row + x
                val surround = minOf(band[p - 3 * width], band[p + 3 * width])
                if (x < SCAN_RIGHT - left && surround - band[p] >= limit(surround / 3, 14, 25)) {
                    if (start == null) start = x
                    continue
                }
                val s = start
                if (s != null && (x - s) in lengths) {
                    val center = row + s + (x - s) / 2
                    val end = p + 1
                    val border = row + s - 2
                    val rim = intArrayOf(
                        band[border - 4 * width], band[center - 4 * width], band[end - 4 * width],
                        band[border + 4 * width], band[center + 4 * width], band[end + 4 * width],
                        band[border], band[end],
                    ).sortedArray()
                    val tone = (rim[3] + rim[4]) / 2
                    val contrast = tone - band[center]
                    if (contrast >= limit(tone / 3, 20, 33) && rim[7] - rim[0] <= maxOf(24, contrast * 3 / 4)) {
                        if (found.size >= maximum) return Scan(emptyList(), true)
                        found.add(Slot(left + (s + x - 1) / 2.0, y, x - s, contrast))
                    }
                }
                start = null
            }
        }
        return Scan(found, false)
    }

    private fun hasCamera(grid: Grid, top: Slot): Boolean {
        for (side in intArrayOf(-1, 1)) {
            for (d in maxOf(5, rounded(top.length * 0.62))..rounded(top.length * 1.15)) {
                for (y in (top.y - 2)..(top.y + 2)) {
                    val x = rounded(top.x) + side * d
                    val above = grid.at(x, y - 3)
                    val below = grid.at(x, y + 3)
                    val left = grid.at(x - 3, y)
                    val right = grid.at(x + 3, y)
                    val low = minOf(minOf(above, below), minOf(left, right))
                    val high = maxOf(maxOf(above, below), maxOf(left, right))
                    if (low - grid.at(x, y) >= limit(low / 3, 15, 23) && (high - low) < maxOf(25.0, top.contrast * 0.9)) return true
                }
            }
        }
        return false
    }

    private fun smoothRim(grid: Grid, slot: Slot, dx: Double, h: Double): Boolean {
        val r = (h * 0.14).toInt()
        return intArrayOf(-r, 3 - r, r - 3, r).count { k ->
            val x = rounded(slot.x) + k
            val y = slot.y + rounded(-k.toDouble() * dx / h)
            abs(grid.at(x, y - 2) - grid.at(x, y + 2)) < 16
        } >= 3
    }

    private fun rimBoundary(grid: Grid, slot: Slot, dx: Double, h: Double, lower: Boolean): Int {
        var best = 0
        var distance = if (lower) -10 else 3
        val last = if (lower) -4 else 7
        while (distance <= last) {
            val samples = (-2..2).map { i ->
                val k = i * 0.08
                val d = distance * 0.01
                val x = rounded(slot.x + k * h + dx * d)
                val y = rounded(slot.y + h * d - (if (lower) 0.8 else 0.52) * dx * k)
                abs(grid.at(x, y - 2) - grid.at(x, y + 2))
            }.sorted()
            best = maxOf(best, samples[2])
            distance += 2
        }
        return best
    }

    private fun sideStrength(grid: Grid, slot: Slot, dx: Double, h: Double, side: Int): Int {
        var best = 0
        for (width in 23..27) {
            val r = (side * width) * 0.01
            val samples = doubleArrayOf(0.10, 0.24, 0.39, 0.54, 0.69, 0.84).map { t ->
                val x = rounded(slot.x + t * dx + r * h)
                val y = rounded(slot.y + t * h - r * dx)
                maxOf(abs(grid.at(x - 4, y) - grid.at(x, y)), abs(grid.at(x - 2, y) - grid.at(x + 2, y)), abs(grid.at(x, y) - grid.at(x + 4, y)))
            }.sorted()
            best = maxOf(best, (samples[2] + samples[3]) / 2)
        }
        return best
    }
}
