// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Altyazı kutusunun zemin opaklığı (Mac/iPhone OverlayCover.boxOpacity, Windows OverlayPlacement.BoxOpacity, TV app.js
 * ownBackground ve OBS katmanı aynı kural). Telefon kutuyu kendisi çizmez (TV ve OBS çizer); ayar ekranının önizlemesi ve
 * "Koyuluk" notu bu kurala göre gösterilir. Ortak vakalar fixtures/box-opacity.json (Mac, Windows aynı).
 */
object OverlayCover {
    /**
     * "Örtsün"ün en yeni satırı "Koyuluk"tan bağımsız tam opaktır (#1378): oyundaki İngilizce altyazıyı kapatmak bu
     * yerleşimin işi. Öbür yerleşimlerde ve önceki satırlarda koyuluk geçerli (önceki satır %83'ü). "Zeminsiz" (0) hiçbir
     * yerleşimde zemin çizmez (#1399).
     */
    fun boxOpacity(background: Int, covering: Boolean, current: Boolean): Double {
        val percent = background.coerceIn(0, 100)
        if (percent == 0) return 0.0
        if (covering && current) return 1.0
        return percent / 100.0 * (if (current) 1.0 else 0.83)
    }

    /**
     * "Koyuluk"un altına "Örtsün"de en yeni satırın hep tam koyu kaldığını söyleyen not çıksın mı. İki kullanıcı (X ve Google
     * Play, beta.107) "zemin koyuluğu ayarlanamıyor" dedi: ayar ekranı bunu söylemiyor, önizleme de saydam çiziyordu. Örtüyü
     * koyuluğa göre açmak İngilizceyi geri getirir (testdata/frames: %80'de ΔL* ≈ 20, ancak %95 üstünde fark edilmez).
     */
    fun darknessFixedByCover(placement: SubtitlePlacement, background: Int): Boolean =
        placement == SubtitlePlacement.COVER && background > 0
}
