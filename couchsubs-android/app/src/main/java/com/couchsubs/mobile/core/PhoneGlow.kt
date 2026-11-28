// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Açık telefonun ekran ışığı: karanlık sahnede telefonun ekranı kendi ışığıyla aydınlık kalır, kasası ve çevresi kararır.
 * #1443 (beta-108, Mac günlüğü): karanlık mekânda üst şeridin parlaklığı 2–10/255, ortanca parlaklık 3–9/255; sıkı arama
 * telefonu 30 sn'de 84 aramanın yalnız 27–72'sinde buluyor, kasanın izi ([PhonePrint]) düz ve koyu kasada tutmuyor
 * ("benzerlik %0"), telefon ~1,1 sn'de bir kapanıp açılıyordu; her kapanışta telefonun kutuları siliniyor, ekran yazısı ve
 * görev satırı telefonun yazılarını okuyordu. Telefon açıkken arama ve iz ıskalarsa son yerinde ekranın ışığına bakılır:
 * çevresi karanlık ve ekran hâlâ son gerçek gözlemdeki kadar aydınlıksa telefon yerinde sayılır ([HOLD_MS]'e dek). Telefon
 * indirilince son yerde karanlık arka plan kalır, ışık tutmaz ve telefon her zamanki sürede kapanır. Mac/iPhone
 * (PhoneGlow.swift) ve Windows (PhoneGlow.cs) aynı örnekler ve eşikler.
 */
object PhoneGlow {
    /** Ekranın içi: telefonun ekseni boyunca (0: hoparlör yarığı, 1: alt çentik) ve eksene dik (boyun oranı) örnekler. */
    val SCREEN_ALONG = doubleArrayOf(0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85)
    val SCREEN_ACROSS = doubleArrayOf(-0.16, -0.08, 0.0, 0.08, 0.16)
    /** Telefonun iki yanı (kasanın dışı; kasa ~0,25 boyda biter). */
    val RING_ALONG = doubleArrayOf(0.2, 0.35, 0.5, 0.65, 0.8)
    val RING_ACROSS = doubleArrayOf(0.4, 0.5)
    /** Telefonun üstü (hoparlör yarığının üstünde, kasanın dışı). */
    val ABOVE_ALONG = doubleArrayOf(-0.12, -0.18)
    val ABOVE_ACROSS = doubleArrayOf(-0.15, 0.0, 0.15)
    /**
     * Çevre karanlık: telefonun iki yanının ve üstünün en aydınlığının ortanca tonu bundan az (0–255; karanlık sahne eşiği
     * GamePhoneGeometry'deki karanlık sahne eşiğiyle aynı). Günlükte telefonun gidip geldiği sahnede ortanca parlaklık 3–9/255.
     */
    const val DARK_RING = 56.0
    /** Ekran çevreden en az bu kadar ton aydınlık olmalı. */
    const val MIN_GLOW = 40.0
    /** Ekranın ortanca tonu son gerçek gözlemdekinden en çok bu oranda sapabilir (yazı kaydı, bildirim). */
    const val SCREEN_SHARE = 0.4
    /**
     * Işıkla tutma en çok bu kadar süre (ms; son gerçek gözlemden): sonra telefon her zamanki gibi kapanır. Günlükte telefon
     * kapandıktan sonra yeniden bulunana dek görülmediği süre 2,2–5,9 sn (sekiz kapanış).
     */
    const val HOLD_MS = 6000L

    /** Ekranın ve çevrenin ortanca tonları (0–255). */
    data class Glow(val screen: Double, val ring: Double)

    /** [pose]'taki (görüntüye göre 0..1) telefonun ekran ışığı; [raw] 400×225 ızgaranın ham tonu (dört noktanın tonu × 256). */
    fun measure(pose: GamePhoneGeometry.Pose, raw: (Int, Int) -> Int): Glow? {
        val topX = pose.topX * 400
        val topY = pose.topY * 225
        val axisX = (pose.bottomX - pose.topX) * 400
        val h = (pose.bottomY - pose.topY) * 225
        if (!topX.isFinite() || !topY.isFinite() || !axisX.isFinite() || !h.isFinite() || h <= 20) return null
        fun tone(t: Double, r: Double): Int {
            val x = Math.rint(topX + t * axisX + r * h).toInt()
            val y = Math.rint(topY + t * h - r * axisX).toInt()
            return raw(min(399, max(0, x)), min(224, max(0, y)))
        }
        val screen = SCREEN_ALONG.flatMap { t -> SCREEN_ACROSS.map { tone(t, it) } }
        val left = RING_ALONG.flatMap { t -> RING_ACROSS.map { tone(t, -it) } }
        val right = RING_ALONG.flatMap { t -> RING_ACROSS.map { tone(t, it) } }
        val above = ABOVE_ALONG.flatMap { t -> ABOVE_ACROSS.map { tone(t, it) } }
        return Glow(median(screen), maxOf(median(left), median(right), median(above)))
    }

    /** Ortanca ton (ham tonlardan, 0–255; çift sayıda örnekte ortadaki ikisinin ortalaması). */
    fun median(raw: List<Int>): Double {
        if (raw.isEmpty()) return 0.0
        val sorted = raw.sorted()
        val n = sorted.size
        val mid = if (n % 2 == 1) sorted[n / 2].toDouble() else (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        return mid / 1024
    }

    /** Karanlık sahnede ışıklı ekran: çevre koyu, ekran çevreden en az [MIN_GLOW] ton aydınlık. */
    fun lit(glow: Glow): Boolean = glow.ring < DARK_RING && glow.screen >= glow.ring + MIN_GLOW

    /** Son gerçek gözlemin ışığı ([recorded]) son yerde hâlâ tutuyor mu. */
    fun holds(recorded: Glow, current: Glow): Boolean =
        lit(recorded) && lit(current) && abs(current.screen - recorded.screen) <= SCREEN_SHARE * recorded.screen
}
