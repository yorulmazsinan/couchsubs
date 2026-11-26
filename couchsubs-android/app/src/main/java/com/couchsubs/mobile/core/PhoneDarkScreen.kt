// SPDX-License-Identifier: AGPL-3.0-only

package com.couchsubs.mobile.core

/**
 * Koyu ekranlı telefonun (koyu temalı uygulama, gece, kısılmış ekran) okunmadan önceki hazırlığı. Kullanıcı bildirimi (X,
 * beta.104): "telefonda parlaklık varsa çeviri oluyor karanlıksa olmuyor". Düzeltilmiş ekran olduğu gibi okunuyordu: koyu
 * zeminde açık ve soluk yazı (kısılmış ekranda yazı ile zemin arasında 40–60 ton) yazı tanımada sık kayboluyordu. Ekranın
 * ortanca tonu [DARK_LEVEL]'dan azsa ve açık yazı varsa (en açık %1'in tonu ortancadan en az [MIN_SPREAD] fazla) ekran
 * zeminden yazıya gerilir ve ters çevrilir: yazı koyu, zemin açık (aydınlık ekranın okunduğu biçim). Aydınlık ekran
 * değişmez. Mac/iPhone (PhoneDarkScreen.swift) ve Windows (PhoneDarkScreen.cs) aynı kural; ortak deneme dosyası
 * fixtures/phone-dark.json.
 */
object PhoneDarkScreen {
    /** Ortanca tonu bundan az ekran koyu sayılır (0–255). */
    const val DARK_LEVEL = 96
    /** En açık %1'in tonu ortancadan en az bu kadar fazla olmalı (açık yazı var). */
    const val MIN_SPREAD = 40

    /**
     * Tonların dönüşüm tablosu (256 öğe); hazırlık gerekmiyorsa null. Alt sınır en koyu %2'nin, üst sınır en açık %1'in
     * tonu; ton `255 - (ton - alt) × 255 / (üst - alt)` (0–255'e kırpılır).
     */
    fun mapping(counts: IntArray, total: Int): IntArray? {
        if (total <= 0) return null
        fun percentile(share: Int): Int {
            var sum = 0L
            for (tone in 0 until 256) {
                sum += counts[tone]
                if (sum * 100 >= total.toLong() * share) return tone
            }
            return 255
        }
        val low = percentile(2)
        val median = percentile(50)
        val high = percentile(99)
        if (median >= DARK_LEVEL || high - median < MIN_SPREAD || high <= low) return null
        return IntArray(256) { tone -> 255 - minOf(255, maxOf(0, tone - low) * 255 / (high - low)) }
    }

    /** Düz ekranın gri tonları (NV21'in Y düzlemi, ilk [count] bayt) koyuysa yerinde hazırlanır; değilse false. */
    fun prepare(gray: ByteArray, count: Int): Boolean {
        val counts = IntArray(256)
        for (i in 0 until count) counts[gray[i].toInt() and 0xff]++
        val map = mapping(counts, count) ?: return false
        for (i in 0 until count) gray[i] = map[gray[i].toInt() and 0xff].toByte()
        return true
    }
}
