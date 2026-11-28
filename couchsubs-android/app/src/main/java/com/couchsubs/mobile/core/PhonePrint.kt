// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.sqrt

/**
 * Açık telefonun izi: kasanın üst (hoparlör yarığı, kamera, kasa kenarı) ve alt (alt çentik, çene) şeridinden örnekler.
 * X'te 3+ kullanıcı (beta-107): GTA 6 telefonu gece, kapalı ya da karanlık sahnede bir kez çevrilip kayboluyor, bir daha
 * gelmiyordu. Sıkı arama karanlıkta telefonu ara sıra buluyor (günlük: parlaklık 7–60/255, "hoparlör yarığı yok"), açılan
 * telefon iki ıskada kapanıyor, yeniden açılış yine üç gözlem bekliyordu. Telefon açıkken sıkı arama ve gevşek doğrulama
 * ıskalarsa son yerin çevresinde iz karşılaştırılır (normalleştirilmiş çapraz ilinti: parlaklıktan, karşıtlıktan ve gamadan
 * bağımsız): iz tutuyorsa telefon yerinde sayılır, okuma sürer. Telefon indirilince son yerde artık arka plan vardır, iz
 * tutmaz ve telefon her zamanki sürede kapanır. Mac/iPhone (PhonePrint.swift) ve Windows (PhonePrint.cs) aynı örnekler ve
 * eşikler.
 */
object PhonePrint {
    /** Telefonun ekseni boyunca (0: hoparlör yarığı, 1: alt çentik; boy oranı) örnek satırları. */
    val ALONG = doubleArrayOf(-0.045, -0.02, 0.0, 0.02, 0.04, 0.96, 0.98, 1.0, 1.02, 1.045)
    /** Eksene dik (boyun oranı) örnek sütunları: kasanın içinde, -0,26 … 0,26. */
    val ACROSS = DoubleArray(13) { -0.26 + it * 0.52 / 12 }
    /** İz son yerin bu kadar çevresinde aranır (400×225 ızgarada, her yönde): 330 ms'de el titremesi. */
    const val REACH = 4
    /** İz bu benzerlikten (normalleştirilmiş çapraz ilinti, -1…1) az değilse telefon yerinde sayılır. */
    const val HOLD_SIMILARITY = 0.8
    /** İzdeki örneklerin en az sapması (ham ton; 1024 = 1 ton): düz, simsiyah ya da tek renk yer iz sayılmaz. */
    const val MIN_SPREAD = 2048.0
    /** Güncel izin sapması kayıtlı izinkinin bu oranından az olmamalı (çok karardı, telefon gitti). */
    const val MIN_SPREAD_RATIO = 0.08

    class Match(val dx: Int, val dy: Int, val similarity: Double)

    /**
     * [pose]'taki (görüntüye göre 0..1) telefonun izi, [dx]/[dy] ızgara noktası kaydırılmış; [raw] 400×225 ızgaranın ham
     * tonu (dört noktanın tonu × 256).
     */
    fun samples(pose: GamePhoneGeometry.Pose, dx: Int, dy: Int, raw: (Int, Int) -> Int): IntArray? {
        val topX = pose.topX * 400
        val topY = pose.topY * 225
        val axisX = (pose.bottomX - pose.topX) * 400
        val h = (pose.bottomY - pose.topY) * 225
        if (!topX.isFinite() || !topY.isFinite() || !axisX.isFinite() || !h.isFinite() || h <= 20) return null
        val out = IntArray(ALONG.size * ACROSS.size)
        var i = 0
        for (t in ALONG) {
            for (r in ACROSS) {
                val x = Math.rint(topX + t * axisX + r * h).toInt() + dx
                val y = Math.rint(topY + t * h - r * axisX).toInt() + dy
                out[i++] = raw(x.coerceIn(0, 399), y.coerceIn(0, 224))
            }
        }
        return out
    }

    /**
     * İki izin benzerliği: üst ve alt şeridin (izin iki yarısı) normalleştirilmiş çapraz ilintisinin (-1…1) küçüğü. Tek şerit
     * yetmez: telefonsuz karede geniş bir parlaklık geçişi (koyu üst, açık alt) bütün izle %82 benzeşiyordu; hoparlör yarığı
     * ve kamera üstte, alt çentik altta aynı anda tutmalı. Şerit düzse ([MIN_SPREAD]) ya da güncel şerit kayıtlı şeritten çok
     * sönükse ([MIN_SPREAD_RATIO]) 0.
     */
    fun similarity(print: IntArray, current: IntArray): Double {
        if (print.size != current.size || print.size < 2) return 0.0
        val half = print.size / 2
        return minOf(strip(print, current, 0, half), strip(print, current, half, print.size))
    }

    /** Tek şeridin ([from], [to]) normalleştirilmiş çapraz ilintisi; düz ya da çok sönükse 0. */
    private fun strip(print: IntArray, current: IntArray, from: Int, to: Int): Double {
        val n = (to - from).toDouble()
        var ta = 0L
        var tb = 0L
        for (i in from until to) {
            ta += print[i]
            tb += current[i]
        }
        val ma = ta / n
        val mb = tb / n
        var sab = 0.0
        var saa = 0.0
        var sbb = 0.0
        for (i in from until to) {
            val a = print[i] - ma
            val b = current[i] - mb
            sab += a * b
            saa += a * a
            sbb += b * b
        }
        val sa = sqrt(saa / n)
        val sb = sqrt(sbb / n)
        if (sa < MIN_SPREAD || sb < MIN_SPREAD || sb < sa * MIN_SPREAD_RATIO) return 0.0
        return sab / sqrt(saa * sbb)
    }

    /** İzin son yerin [REACH] çevresindeki en iyi eşleşmesi: kayma (ızgara noktası) ve benzerlik. */
    fun match(print: IntArray, pose: GamePhoneGeometry.Pose, raw: (Int, Int) -> Int): Match {
        var bestX = 0
        var bestY = 0
        var best = -1.0
        for (dy in -REACH..REACH) {
            for (dx in -REACH..REACH) {
                val current = samples(pose, dx, dy, raw) ?: return Match(0, 0, 0.0)
                val s = similarity(print, current)
                // Eşitlikte ilk bulunan (her platformda aynı tarama sırası).
                if (s > best + 1e-9) {
                    best = s
                    bestX = dx
                    bestY = dy
                }
            }
        }
        return Match(bestX, bestY, maxOf(0.0, best))
    }
}
