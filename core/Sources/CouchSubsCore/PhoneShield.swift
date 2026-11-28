// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Telefon açıkken telefonun alanı telefon okuyucusunundur: başka yolların (görev satırı, hazır yardım/mesaj alanı, kenar
/// bildirimi, kullanıcının ek alanı) o alanda okuduğu satırlar atılır. #1443 (beta-108, Mac günlüğü): görev satırı yolu
/// telefon açıkken telefonun mesajlarını okuyup çeviriyordu ("ek alan Mission: \"been locked up. I know this is a … REMEMBER
/// DON'T TEXT BACK\" → motor"); görev satırı yol önceliğinde (#1446) en üstte olduğundan kutusu telefonun önüne
/// çiziliyordu. Otomatik ekran yazısının telefona değen alanı zaten önerilmez (`ScreenTextDetector.outsidePhone`); burada
/// alanın tamamı değil yalnız telefonun içine düşen satırlar atılır, alanın telefon dışındaki yazısı çevrilmeye devam eder.
/// Windows (PhoneShield.cs) ve Android (PhoneShield.kt) aynı kural.
public enum PhoneShield {
    /// `reading`'in (satır kutuları `region`'a oranla) telefonun (`phone`, kareye oranla; `ScreenTextDetector.paddedPhone`
    /// payıyla) içine düşen satırları atılmış hâli ve atılan satır sayısı. Satırın merkezi telefonun içindeyse satır
    /// telefonundur; kutusu bilinmeyen satır kalır. `phone` nil ise okuma olduğu gibi.
    public static func filter(_ reading: Reading, region: CropRegion, phone: CropRegion?) -> (kept: Reading, dropped: Int) {
        guard let phone else { return (reading, 0) }
        let padded = ScreenTextDetector.paddedPhone(phone)
        let kept = reading.lines.filter { line in
            guard let box = line.box else { return true }
            let x = region.left + (box.left + box.right) / 2 * (region.right - region.left)
            let y = region.top + (box.top + box.bottom) / 2 * (region.bottom - region.top)
            return !(x >= padded.left && x <= padded.right && y >= padded.top && y <= padded.bottom)
        }
        return kept.count == reading.lines.count ? (reading, 0) : (Reading(lines: kept), reading.lines.count - kept.count)
    }

    /// Kutu (kareye oranla) telefonun alanında mı: merkezi `paddedPhone`'un içinde.
    public static func covers(_ box: TextBox, phone: CropRegion) -> Bool {
        let padded = ScreenTextDetector.paddedPhone(phone)
        let x = (box.left + box.right) / 2, y = (box.top + box.bottom) / 2
        return x >= padded.left && x <= padded.right && y >= padded.top && y <= padded.bottom
    }
}
