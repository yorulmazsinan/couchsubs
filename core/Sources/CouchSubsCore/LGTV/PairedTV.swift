// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// TV'nin kendisi başlattığı eşleşme ("TV eşleşmek istiyor", kodla onay) onaylanınca TV'nin TV kaydına alınması
/// (Windows `PairedTv`, Android `PairedTv` ile aynı kural). Eskiden yalnız altyazı anahtarı TV'ye veriliyor, TV kaydı
/// (adres, marka, ad, TV izni/jetonu) hiç tutulmuyordu: TV bekçisi (otomatik açma) çalışmıyor, ana ekranda TV kartı
/// çıkmıyordu. Onaylanan TV, kullanıcı onu listeden elle seçmiş gibi eşlenir (`pair`).
public enum PairedTV {
    /// İsteği gönderen TV kaydedilsin mi. `host`: isteğin geldiği adres (`SubtitlePairing.Ticket.host`); `saved`: kayıtlı TV;
    /// `hasKey`: kayıtlı TV'nin izni/jetonu saklı mı. Kullanıcının seçtiği (izinli) başka bir TV'nin yerine geçilmez; adresi
    /// bilinmeyen kayıt (adsız seçilen Android TV) bu TV'nin adresiyle tamamlanır.
    public static func shouldAdopt(host: String, saved: LGTV?, hasKey: Bool) -> Bool {
        guard !host.isEmpty else { return false }
        guard let saved, hasKey else { return true }
        return saved.host.isEmpty
    }

    /// Adresteki TV (marka ve ad TV'ye sorulur: Samsung 8001 `/api/v2/`, LG 1990 cihaz tanımı ya da 3000, Android TV
    /// portları; bkz. `ManualTV`). TV türü tanınmazsa nil: yanlış markayla eşlenip TV'de boşuna izin sorulmaz.
    public static func identify(host: String) async -> LGTV? {
        let found = await ManualTV.tv(at: host)
        return found.recognised ? found.tv : nil
    }
}
