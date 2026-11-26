// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * GTA 6 telefonunun otomatik okumasında önceden günlüğe hiçbir şey yazmayan yollar (#1251): telefon açıldı/kapandı, telefon
 * oynadığı için açılmadı, eğik ekranın düzeltilmiş okuması boş geldi (tur atlama satırları Mac/iPhone ve Windows'ta; Android'de
 * kare yalnız izleyici telefonu bulduğunda alınır). Satırlar [DropLog] ile sınırlıdır (aynı satır 60 sn'de bir, dakikada en
 * çok 20). Windows (PhoneTrace.cs) ve Mac/iPhone (PhoneTrace.swift) aynı metinler.
 */
object PhoneTrace {
    const val COMPONENT = "PhoneTrace"
    const val OPENED = "telefon açıldı"
    const val CLOSED = "telefon kapandı"

    /** Telefon kapandı: kaç ms görülmedi, kaç örnekte bulunamadı (#1334: çevirinin kalkma gecikmesi günlükte görünsün). */
    fun closed(afterMs: Long, misses: Int) = "$CLOSED ($afterMs ms görülmedi, $misses ıska)"
    const val MISSING = "PhoneMissing: telefon bu karede bulunamadı, tur atlandı"
    const val EMPTY_FLAT = "eğik ekran düzeltilmiş okuması boş"

    /** Telefon bulundu ama önceki örnekten çok oynadı; iki uyumlu gözlem olmadığı için açılmadı. */
    fun moving(share: Double) = "telefon oynuyor, açılmadı (%${percent(share)} oynama)"

    /** Okunacak karede telefon izlenen yerden çok uzakta: tur atlandı. */
    fun displaced(share: Double) = "telefon karede yerinde değil, tur atlandı (%${percent(share)} oynama)"

    /** Sıkı aramanın ıska ölçütü ([GamePhoneGeometry.Step]) günlükte (Mac/iPhone ve Windows ile aynı metinler). */
    fun reason(step: GamePhoneGeometry.Step): String = when (step) {
        GamePhoneGeometry.Step.NO_PICTURE -> "16:9 görüntü yok"
        GamePhoneGeometry.Step.NO_TOP_SLOT -> "hoparlör yarığı yok"
        GamePhoneGeometry.Step.TOP_CROWDED -> "üst şeritte çok aday"
        GamePhoneGeometry.Step.NO_CAMERA -> "ön kamera yok"
        GamePhoneGeometry.Step.NO_BOTTOM_SLOT -> "alt çentik yok"
        GamePhoneGeometry.Step.BOTTOM_CROWDED -> "alt şeritte çok aday"
        GamePhoneGeometry.Step.SHAPE -> "boy/oran tutmadı"
        GamePhoneGeometry.Step.RIM -> "kasa kenarı düz değil"
        GamePhoneGeometry.Step.SIDES -> "yan kenarlar zayıf"
        GamePhoneGeometry.Step.IMPLAUSIBLE -> "kutu akla yatkın değil"
        GamePhoneGeometry.Step.FOUND -> "bulundu"
    }

    /**
     * Telefon açık değilken ilk açılış ıskalandı (#1251): [samples] aramada en ileri geçilen ölçüt, en sık ıska, en iyi
     * adayın zayıf yanı (yan eşiğine oranla; aday yoksa yazılmaz), tek görülüp doğrulanmayan gözlemler ve üst şeridin
     * ortalama parlaklığı ([level], 0–255; -1: ölçülmedi). Karanlık sahnede ([GamePhoneGeometry.DARK_LEVEL]) en ileri ölçüte
     * ulaşan aramanın kazancı da yazılır ([gain], 256 = ×1,0).
     */
    fun missedFirst(
        samples: Int, furthest: String, common: String, commonCount: Int, side: Int, unconfirmed: Int, strict: Int,
        level: Int = -1, gain: Int = 256,
    ): String {
        val candidate = if (side >= 0) ", en iyi aday yan gücü $side/${GamePhoneGeometry.SIDE_THRESHOLD}" else ""
        var light = ""
        if (level >= 0) {
            light = ", parlaklık $level/255"
            if (level < GamePhoneGeometry.DARK_LEVEL) light += " (karanlık, kazanç ×${times(gain)})"
        }
        return "telefon ilk aramada bulunamadı ($samples arama): en ileri ölçüt $furthest, en sık $common ($commonCount)$candidate, " +
            "doğrulanmayan gözlem $unconfirmed ($strict sıkı)$light"
    }

    /** Kazanç (256 = 1) bir ondalıkla, virgülle ("2,5"). */
    fun times(gain: Int): String {
        val tenths = (gain * 10 + 128) / 256
        return "${tenths / 10},${tenths % 10}"
    }

    /** Oranın yüzdesi (tam sayı). */
    fun percent(share: Double): Int = (share * 100).roundToInt()

    /** İki bölgenin en çok oynayan kenarı (kareye oranla). */
    fun shift(a: CropRegion, b: CropRegion): Double =
        max(max(abs(a.top - b.top), abs(a.bottom - b.bottom)), max(abs(a.left - b.left), abs(a.right - b.right)))
}

/**
 * İlk açılışın ıskalanma nedenleri (#1251; [GamePhoneTracker]). Telefon açık değilken her aramanın ıska ölçütü [WINDOW_MS]
 * boyunca toplanır; pencerede telefona benzer bir şey varsa (kameralı hoparlör yarığı bulundu ya da daha ileri, şerit
 * kalabalık, tek görülüp doğrulanmayan gözlem) pencere sonunda tek satır yazılır ([PhoneTrace.missedFirst]). Karanlık
 * sahnede (pencerenin ortalama parlaklığı [GamePhoneGeometry.DARK_LEVEL]'dan az) hoparlör yarığı bulunan pencere de yazılır:
 * karanlıkta telefon kameranın ya da alt çentiğin önünde kalıyordu ve satır hiç yazılmıyordu (X, beta.104: "karanlıksa
 * olmuyor"). Telefonsuz
 * oyunda aramaların hemen hepsi "hoparlör yarığı yok"ta kalır, satır yazılmaz. Mac/iPhone (PhoneMissLog, PhoneTrace.swift)
 * ve Windows (PhoneMissLog, PhoneTrace.cs) ile aynı.
 */
internal class PhoneMissLog {
    companion object {
        /** Özet penceresi (ms): en çok bu aralıkla bir satır. */
        const val WINDOW_MS = 20_000L
    }

    private var windowStart: Long? = null
    private var samples = 0
    private var unconfirmed = 0
    private var unconfirmedStrict = 0
    private var side = -1
    private var furthest = GamePhoneGeometry.Step.NO_PICTURE
    private val counts = sortedMapOf<GamePhoneGeometry.Step, Int>()
    /** Ölçülen parlaklıkların toplamı ve sayısı; en ileri ölçüte ulaşan aramanın kazancı. */
    private var levelSum = 0
    private var levels = 0
    private var gain = 256

    /** Doğrulanmayı bekleyen gözlem süresi dolup ya da başka yerde gözlem gelip bırakıldı. */
    fun unconfirmed(strict: Boolean) {
        unconfirmed++
        if (strict) unconfirmedStrict++
    }

    fun note(probe: GamePhoneGeometry.Probe, now: Long, log: (String) -> Unit) {
        val start = windowStart?.takeIf { now >= it } ?: now.also { windowStart = it }
        samples++
        counts[probe.step] = (counts[probe.step] ?: 0) + 1
        if (probe.step > furthest) {
            furthest = probe.step
            gain = probe.gain
        }
        if (probe.side > side) side = probe.side
        if (probe.level >= 0) {
            levelSum += probe.level
            levels++
        }
        if (now - start < WINDOW_MS) return
        if (suspicious) {
            val common = counts.entries.sortedWith(compareByDescending<Map.Entry<GamePhoneGeometry.Step, Int>> { it.value }.thenBy { it.key }).first()
            log(PhoneTrace.missedFirst(samples, PhoneTrace.reason(furthest), PhoneTrace.reason(common.key), common.value, side,
                unconfirmed, unconfirmedStrict, level, gain))
        }
        begin(now)
    }

    /** Pencerenin ortalama parlaklığı (0–255); ölçülmediyse -1. */
    private val level: Int get() = if (levels > 0) levelSum / levels else -1

    /** Pencerede telefona benzer bir şey görüldü mü; karanlık sahnede hoparlör yarığı yeter. */
    private val suspicious: Boolean
        get() = furthest >= GamePhoneGeometry.Step.NO_BOTTOM_SLOT || unconfirmed > 0 ||
            GamePhoneGeometry.Step.TOP_CROWDED in counts || GamePhoneGeometry.Step.BOTTOM_CROWDED in counts ||
            (level >= 0 && level < GamePhoneGeometry.DARK_LEVEL && furthest >= GamePhoneGeometry.Step.NO_CAMERA)

    /** Telefon açıldı ya da izleyici sıfırlandı: pencere baştan. */
    fun reset() = begin(null)

    private fun begin(now: Long?) {
        windowStart = now
        samples = 0
        unconfirmed = 0
        unconfirmedStrict = 0
        side = -1
        furthest = GamePhoneGeometry.Step.NO_PICTURE
        counts.clear()
        levelSum = 0
        levels = 0
        gain = 256
    }
}

/**
 * Okunan telefon satırlarının günlük özeti (X, 26 Kas, beta.104: en üstteki uzun mesaj çevrilmiyor, cevap seçenekleri karışık
 * görünüyordu; hangi satırın okunup hangi rolle panele girdiği günlükte yoktu). Her grubun türü (header, bubble, option, note,
 * list, card) ve ilk sözcükleri ([PhoneChat.rowSummary]); özet değişince yazılır, en çok [INTERVAL_MS]'de bir, aynı özet
 * yinelenmez. iPhone (PhoneRowsLog, PhoneTrace.swift) ve Windows (PhoneRowsLog, PhoneTrace.cs) aynı.
 */
class PhoneRowsLog {
    private var last: String? = null
    private var at: Long? = null

    /** Yazılacak satır; okuma boşsa, özet aynıysa ya da son satırdan bu yana [INTERVAL_MS] geçmediyse null. */
    @Synchronized
    fun line(groups: List<ScreenTranslation.Group>, now: Long): String? {
        if (groups.isEmpty()) return null
        val summary = PhoneChat.rowSummary(groups)
        if (summary == last) return null
        val previous = at
        if (previous != null && now >= previous && now - previous < INTERVAL_MS) return null
        last = summary
        at = now
        val shown = if (summary.length > MAX_LENGTH) summary.take(MAX_LENGTH) + "…" else summary
        return "telefon satırları: $shown"
    }

    companion object {
        const val INTERVAL_MS = 5_000L
        /** Özetin en uzun hâli (karakter). */
        const val MAX_LENGTH = 400
    }
}
