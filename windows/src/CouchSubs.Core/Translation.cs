// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core.Dubbing;

namespace CouchSubs.Core;

/// <summary>Bir satırı oyun dilinden hedef dile çevirir (cihaz üstünde).</summary>
public interface ITextTranslator
{
    Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default);

    /// <summary>Son çevrilen altyazının seslendirilecek cümleleri (konuşmacısıyla); dublaj için.</summary>
    IReadOnlyList<SpokenLine> SpokenLines(string text) => [];

    /// <summary>
    /// Çevirmen <see cref="Prefetch"/> destekliyor mu. Destekleyen (ör. çevrimiçi) çevirmende okuma hattı satırı ilk
    /// karede çevirmeye başlar; temiz okunmayan satırı TV'ye ancak sonraki kare doğrulayınca gönderir: altyazı
    /// belirirken okunan bozuk ilk kare ekrana hiç çıkmaz, bekleme de çeviri süresine gizlenir.
    /// </summary>
    bool Prefetches => false;

    /// <summary>Satırın çevirisini arka planda başlatır; aynı metin için sonraki <see cref="TranslateAsync"/> onu bekler.</summary>
    void Prefetch(string text) { }

    /// <summary>
    /// <see cref="TranslateAllAsync"/> bütün metinleri tek istekte çevirir (yapay zekâ); öyleyse "ekranı çevir" parça
    /// parça istek göndermez.
    /// </summary>
    bool TranslatesTogether => false;

    /// <summary>
    /// Hat satır başındaki konuşan adını ("PRICE: …") ayırıp çevirmene yalnız cümleyi verir; ad buradan öğrenilir ve
    /// sonraki cümlelerin içinde geçince çeviriden korunur (#287).
    /// </summary>
    void NoteSpeaker(string name) { }

    /// <summary>
    /// Birbirinden bağımsız metinleri ("ekranı çevir"deki menü satırları, görev yazıları) aynı sırada çevirir.
    /// Varsayılan: sırayla tek tek.
    /// </summary>
    async Task<IReadOnlyList<string>> TranslateAllAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
    {
        var result = new List<string>(texts.Count);
        foreach (var text in texts) result.Add(await TranslateAsync(text, cancellationToken).ConfigureAwait(false));
        return result;
    }
}

public enum TranslatorStatus
{
    Ready,
    /// <summary>Çeviri modeli henüz indirilmedi.</summary>
    NeedsDownload,
    /// <summary>Bu dil çifti desteklenmiyor.</summary>
    Unsupported,
    /// <summary>
    /// Model kurulu ama cihaz üstü çeviri motoru bu bilgisayarda açılamadı (ör. CTranslate2 çalışma zamanı
    /// yüklenemedi). Kullanıcı çevrimiçi bir motor seçebilir; oyun paketleri çalışmayı sürdürür.
    /// </summary>
    EngineFailed,
}

/// <summary>Kullanıcının düzeltebileceği çeviri hatası (model eksik, dil desteklenmiyor, motor açılamadı).</summary>
public sealed class TranslatorException(TranslatorStatus status, Exception? innerException = null)
    : Exception($"Translator not available: {status}", innerException)
{
    public TranslatorStatus Status { get; } = status;
}

/// <summary>
/// Çevrimiçi çeviri anahtarı (DeepL ya da yapay zekâ hizmeti) denendiğinde ne çıktı. <c>ModelRejected</c>: hizmet model
/// adını kabul etmedi (yalnız yapay zekâ hizmetlerinde). <c>Busy</c>: hizmete ulaşıldı ama şu an yoğun (5xx), yanıt
/// zamanında gelmedi ya da dakikalık sınıra takıldı; anahtar reddedilmedi, internet de çalışıyor (DeepL'in anahtar
/// denemesinde: 429, çok sık istek).
/// </summary>
/// <remarks><see cref="KeychainWriteFailed"/>: hizmet anahtarı kabul etti ama şifreli depoya yazılamadı (geri okunamadı); kayıt
/// başarılı sayılmaz (Mac'teki Anahtar Zinciri kuralıyla aynı).</remarks>
public enum OnlineKeyState { Valid, Invalid, QuotaExceeded, Unreachable, ModelRejected, Busy, KeychainWriteFailed }

/// <summary>
/// DeepL anahtar denemesinin ayrıntılı nedeni (Mac/iPhone: OnlineKeyReason, Android: KeyCheck.Reason; aynı kurallar).
/// <c>MalformedKey</c>: görünmez karakterler silindikten sonra anahtarda DeepL anahtarında olamayacak karakter kaldı, istek
/// gönderilmedi. <c>RateLimited</c>: 429. <c>HttpStatus</c>: DeepL'in döndürdüğü kod (<see cref="OnlineKeyCheck.Code"/>).
/// <c>Network</c>: istek DeepL'e ulaşmadı.
/// </summary>
public enum OnlineKeyReason { None, MalformedKey, RateLimited, HttpStatus, Network }

/// <param name="Used">Bu ay kullanılan karakter (geçerli anahtarda).</param>
/// <param name="Limit">Aylık sınır; 0: DeepL bildirmedi, <see cref="Unlimited"/> ve üstü: sınır yok.</param>
/// <param name="Reason">Hatanın nedeni (günlük ve ayarlardaki mesaj; anahtarı içermez).</param>
/// <param name="Code">HttpStatus'ta HTTP kodu.</param>
public sealed record OnlineKeyCheck(OnlineKeyState State, long Used = 0, long Limit = 0, OnlineKeyReason Reason = OnlineKeyReason.None, int Code = 0)
{
    /// <summary>Sınır konmamış hesapta DeepL <c>character_limit</c> olarak bunu döndürür (developers.deepl.com, usage-and-quota).</summary>
    public const long Unlimited = 1_000_000_000_000;

    /// <summary>Günlük satırı: durum ve neden ("Busy (HTTP 429 (çok sık istek))"); anahtarı içermez.</summary>
    public string LogDescription => Reason switch
    {
        OnlineKeyReason.MalformedKey => $"{State} (anahtarda geçersiz karakter)",
        OnlineKeyReason.RateLimited => $"{State} (HTTP 429 (çok sık istek))",
        OnlineKeyReason.HttpStatus => $"{State} (HTTP {Code})",
        OnlineKeyReason.Network => $"{State} (ağ hatası)",
        _ => State.ToString(),
    };
}

/// <summary>
/// DeepL anahtarının yazımı (Mac/iPhone ve Android'deki DeepLKey ile aynı kural). Yapıştırırken araya giren boşluk, satır
/// sonu, sekme, bölünmez boşluk (U+00A0), sıfır genişlikli boşluk, BOM, yumuşak tire gibi görünmez karakterler her yerden
/// silinir; DeepL anahtarında bunlar hiç yoktur.
/// </summary>
public static class DeepLKey
{
    public static string Clean(string? key)
    {
        if (string.IsNullOrEmpty(key)) return "";
        var builder = new System.Text.StringBuilder(key.Length);
        foreach (var rune in key.EnumerateRunes())
        {
            switch (System.Text.Rune.GetUnicodeCategory(rune))
            {
                case System.Globalization.UnicodeCategory.Control:
                case System.Globalization.UnicodeCategory.Format:
                case System.Globalization.UnicodeCategory.SpaceSeparator:
                case System.Globalization.UnicodeCategory.LineSeparator:
                case System.Globalization.UnicodeCategory.ParagraphSeparator:
                    continue;
                default:
                    builder.Append(rune.ToString());
                    break;
            }
        }
        return builder.ToString();
    }

    /// <summary>Temizlenmiş anahtar DeepL anahtarı olabilir mi: boş değil, yalnız görünür ASCII (harf, rakam, "-", ":" …).</summary>
    public static bool IsWellFormed(string cleaned) => cleaned.Length > 0 && cleaned.All(c => c is >= '!' and <= '~');
}
