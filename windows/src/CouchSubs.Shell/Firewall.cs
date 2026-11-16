// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>
/// Windows Güvenlik Duvarı'nda CouchSubs'a gelen bağlantı izni. Remote Play (PS5) ve altyazı sunucusu (TV) dışarıdan
/// bağlantı alır; kullanıcı ilk açılıştaki izin sorusunu kapattıysa ya da ağ "Ortak" ise bu bağlantılar engellenir.
/// </summary>
public interface IFirewall
{
    /// <summary>Bu exe için Özel ağdaki yerel cihazlardan TCP/UDP izni hazır mı. Ortak/Etki alanı izni aranmaz. Yönetici gerekmez.</summary>
    bool HasRule();

    /// <summary>Yönetici izniyle (UAC) kuralı ekler; kullanıcı izin vermezse ya da kural yine yoksa false.</summary>
    Task<bool> AddRuleAsync();

    /// <summary>Bağlı ağlardan biri "Ortak" profilde mi. Ortak ağda Windows, TV'nin bilgisayarı bulmasını engelleyebilir.</summary>
    bool HasPublicNetwork() => false;
}

/// <summary>
/// Güvenlik duvarı kartının durumu. Offer: kural eksik ve bağlantı sorunlu, düğme görünür. Working: Windows'un izin
/// sorusu bekleniyor. Allowed: kural eklendi (kısa onay). Failed: kural eklenemedi, düğme yeniden görünür.
/// PublicNetwork: kural var ama yalnız Özel ağda geçerli, bilgisayarın ağı "Ortak"; düğme yok, ağı Özel yapmak önerilir.
/// </summary>
public enum FirewallPrompt { None, Offer, Working, Allowed, Failed, PublicNetwork }
