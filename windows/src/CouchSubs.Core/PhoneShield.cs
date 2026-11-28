// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Telefon açıkken telefonun alanı telefon okuyucusunundur: başka yolların (görev satırı, hazır yardım/mesaj alanı, kenar
/// bildirimi, kullanıcının ek alanı) o alanda okuduğu satırlar atılır. #1443 (beta-108, Mac günlüğü): görev satırı yolu
/// telefon açıkken telefonun mesajlarını okuyup çeviriyordu ("ek alan Mission: \"been locked up. I know this is a … REMEMBER
/// DON'T TEXT BACK\" → motor"); görev satırı yol önceliğinde (#1446) en üstte olduğundan kutusu telefonun önüne
/// çiziliyordu. Otomatik ekran yazısının telefona değen alanı zaten önerilmez (<see cref="ScreenTextDetector.OutsidePhone"/>);
/// burada alanın tamamı değil yalnız telefonun içine düşen satırlar atılır, alanın telefon dışındaki yazısı çevrilmeye devam
/// eder. Mac/iPhone (PhoneShield.swift) ve Android (PhoneShield.kt) aynı kural.
/// </summary>
public static class PhoneShield
{
    /// <summary>
    /// <paramref name="reading"/>'in (satır kutuları <paramref name="region"/>'a oranla) telefonun (<paramref name="phone"/>,
    /// kareye oranla; <see cref="ScreenTextDetector.PaddedPhone"/> payıyla) içine düşen satırları atılmış hâli ve atılan satır
    /// sayısı. Satırın merkezi telefonun içindeyse satır telefonundur; kutusu bilinmeyen satır kalır. Telefon null ise okuma
    /// olduğu gibi.
    /// </summary>
    public static (Reading Kept, int Dropped) Filter(Reading reading, CropRegion region, CropRegion? phone)
    {
        if (phone is null) return (reading, 0);
        var padded = ScreenTextDetector.PaddedPhone(phone);
        var kept = reading.Lines.Where(line =>
        {
            if (line.Box is not { } box) return true;
            var x = region.Left + (box.Left + box.Right) / 2 * (region.Right - region.Left);
            var y = region.Top + (box.Top + box.Bottom) / 2 * (region.Bottom - region.Top);
            return !(x >= padded.Left && x <= padded.Right && y >= padded.Top && y <= padded.Bottom);
        }).ToList();
        return kept.Count == reading.Lines.Count ? (reading, 0) : (new Reading(kept), reading.Lines.Count - kept.Count);
    }

    /// <summary>Kutu (kareye oranla) telefonun alanında mı: merkezi <see cref="ScreenTextDetector.PaddedPhone"/>'un içinde.</summary>
    public static bool Covers(TextBox box, CropRegion phone)
    {
        var padded = ScreenTextDetector.PaddedPhone(phone);
        double x = (box.Left + box.Right) / 2, y = (box.Top + box.Bottom) / 2;
        return x >= padded.Left && x <= padded.Right && y >= padded.Top && y <= padded.Bottom;
    }
}
