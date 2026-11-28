// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Telefon açıkken telefonun alanı telefon okuyucusunundur: başka yolların (görev satırı, hazır yardım/mesaj alanı, kenar
 * bildirimi, kullanıcının ek alanı) o alanda okuduğu satırlar atılır. #1443 (beta-108, Mac günlüğü): görev satırı yolu
 * telefon açıkken telefonun mesajlarını okuyup çeviriyordu ("ek alan Mission: \"been locked up. I know this is a … REMEMBER
 * DON'T TEXT BACK\" → motor"); görev satırı yol önceliğinde (#1446) en üstte olduğundan kutusu telefonun önüne
 * çiziliyordu. Otomatik ekran yazısının telefona değen alanı zaten önerilmez (ScreenTextDetector.outsidePhone); burada
 * alanın tamamı değil yalnız telefonun içine düşen satırlar atılır, alanın telefon dışındaki yazısı çevrilmeye devam eder.
 * Mac/iPhone (PhoneShield.swift) ve Windows (PhoneShield.cs) aynı kural.
 */
object PhoneShield {
    class Filtered(val kept: Reading, val dropped: Int)

    /**
     * [reading]'in (satır kutuları [region]'a oranla) telefonun ([phone], kareye oranla; ScreenTextDetector.paddedPhone
     * payıyla) içine düşen satırları atılmış hâli ve atılan satır sayısı. Satırın merkezi telefonun içindeyse satır
     * telefonundur; kutusu bilinmeyen satır kalır. [phone] null ise okuma olduğu gibi.
     */
    fun filter(reading: Reading, region: CropRegion, phone: CropRegion?): Filtered {
        if (phone == null) return Filtered(reading, 0)
        val padded = ScreenTextDetector.paddedPhone(phone)
        val kept = reading.lines.filter { line ->
            val box = line.box ?: return@filter true
            val x = region.left + (box.left + box.right) / 2 * (region.right - region.left)
            val y = region.top + (box.top + box.bottom) / 2 * (region.bottom - region.top)
            !(x >= padded.left && x <= padded.right && y >= padded.top && y <= padded.bottom)
        }
        return if (kept.size == reading.lines.size) Filtered(reading, 0) else Filtered(Reading(kept), reading.lines.size - kept.size)
    }

    /** Kutu (kareye oranla) telefonun alanında mı: merkezi ScreenTextDetector.paddedPhone'un içinde. */
    fun covers(box: TextBox, phone: CropRegion): Boolean {
        val padded = ScreenTextDetector.paddedPhone(phone)
        val x = (box.left + box.right) / 2
        val y = (box.top + box.bottom) / 2
        return x >= padded.left && x <= padded.right && y >= padded.top && y <= padded.bottom
    }
}
