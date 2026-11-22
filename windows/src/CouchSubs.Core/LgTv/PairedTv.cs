// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.LgTv;

/// <summary>
/// TV'nin kendisi başlattığı eşleşme ("TV eşleşmek istiyor", kodla onay) onaylanınca TV'nin TV kaydına alınması
/// (Mac/iPhone <c>PairedTV</c>, Android <c>PairedTv</c> ile aynı kural). Eskiden yalnız altyazı anahtarı TV'ye veriliyor,
/// TV kaydı (adres, marka, ad, TV izni/jetonu) hiç tutulmuyordu: TV bekçisi (otomatik açma) çalışmıyor, ana ekranda TV
/// kartı çıkmıyordu. Onaylanan TV, kullanıcı onu listeden elle seçmiş gibi eşlenir (<c>PairAsync</c>).
/// </summary>
public static class PairedTv
{
    /// <summary>
    /// İsteği gönderen TV kaydedilsin mi. <paramref name="host"/>: isteğin geldiği adres; <paramref name="saved"/>: kayıtlı
    /// TV; <paramref name="hasKey"/>: kayıtlı TV'nin izni/jetonu saklı mı. Kullanıcının seçtiği (izinli) başka bir TV'nin
    /// yerine geçilmez; adresi bilinmeyen kayıt bu TV'nin adresiyle tamamlanır.
    /// </summary>
    public static bool ShouldAdopt(string host, LgTv? saved, bool hasKey) =>
        host.Length > 0 && (saved is null || !hasKey || saved.Host.Length == 0);

    /// <summary>
    /// Adresteki TV (marka ve ad TV'ye sorulur: Samsung 8001 <c>/api/v2/</c>, LG 1990 cihaz tanımı ya da 3000, Android TV
    /// portları; bkz. <see cref="LgDiscovery.ManualTvAsync"/>). Tür tanınmazsa null: yanlış markayla eşlenip TV'de boşuna
    /// izin sorulmaz.
    /// </summary>
    public static async Task<LgTv?> IdentifyAsync(string host)
    {
        var found = await LgDiscovery.ManualTvAsync(host);
        return found.Recognised ? found.Tv : null;
    }
}
