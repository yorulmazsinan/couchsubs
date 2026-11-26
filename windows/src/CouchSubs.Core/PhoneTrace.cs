// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// GTA 6 telefonunun otomatik okumasında önceden günlüğe hiçbir şey yazmayan yollar (#1251): telefon açıldı/kapandı, telefon
/// oynadığı için açılmadı, tur telefon karede yerinde olmadığı ya da bulunamadığı için atlandı, eğik ekranın düzeltilmiş
/// okuması boş geldi. Telefon ekranda görünürken hiç çeviri gelmeyince hangi yolun takıldığı günlükte görünsün diye.
/// Satırlar <see cref="DropLog"/> ile sınırlıdır (aynı satır 60 sn'de bir, dakikada en çok 20). Mac/iPhone (PhoneTrace.swift)
/// ve Android (PhoneTrace.kt) aynı metinler.
/// </summary>
public static class PhoneTrace
{
    public const string Component = "PhoneTrace";
    public const string Opened = "telefon açıldı";
    public const string Closed = "telefon kapandı";

    /// <summary>Telefon kapandı: kaç ms görülmedi, kaç örnekte bulunamadı (#1334: çevirinin kalkma gecikmesi günlükte görünsün).</summary>
    public static string ClosedAfter(long ms, int misses) => $"{Closed} ({ms} ms görülmedi, {misses} ıska)";
    public const string Missing = "PhoneMissing: telefon bu karede bulunamadı, tur atlandı";
    public const string EmptyFlat = "eğik ekran düzeltilmiş okuması boş";

    /// <summary>Telefon bulundu ama önceki örnekten çok oynadı; iki uyumlu gözlem olmadığı için açılmadı.</summary>
    public static string Moving(double share) => $"telefon oynuyor, açılmadı (%{Percent(share)} oynama)";

    /// <summary>Okunacak karede telefon izlenen yerden çok uzakta: tur atlandı.</summary>
    public static string Displaced(double share) => $"telefon karede yerinde değil, tur atlandı (%{Percent(share)} oynama)";

    /// <summary>Sıkı aramanın ıska ölçütü (<see cref="GamePhoneGeometry.Step"/>) günlükte (Mac/iPhone ve Android ile aynı metinler).</summary>
    internal static string Reason(GamePhoneGeometry.Step step) => step switch
    {
        GamePhoneGeometry.Step.NoPicture => "16:9 görüntü yok",
        GamePhoneGeometry.Step.NoTopSlot => "hoparlör yarığı yok",
        GamePhoneGeometry.Step.TopCrowded => "üst şeritte çok aday",
        GamePhoneGeometry.Step.NoBottomSlot => "alt çentik yok",
        GamePhoneGeometry.Step.BottomCrowded => "alt şeritte çok aday",
        GamePhoneGeometry.Step.NoCamera => "ön kamera yok",
        GamePhoneGeometry.Step.Shape => "boy/oran tutmadı",
        GamePhoneGeometry.Step.Rim => "kasa kenarı düz değil",
        GamePhoneGeometry.Step.Sides => "yan kenarlar zayıf",
        GamePhoneGeometry.Step.Implausible => "kutu akla yatkın değil",
        _ => "bulundu",
    };

    /// <summary>
    /// Telefon açık değilken ilk açılış ıskalandı (#1251): <paramref name="samples"/> aramada en ileri geçilen ölçüt, en sık
    /// ıska, en iyi adayın zayıf yanı (yan eşiğine oranla; aday yoksa yazılmaz) ve tek görülüp doğrulanmayan gözlemler.
    /// </summary>
    public static string MissedFirst(int samples, string furthest, string common, int commonCount, int side, int unconfirmed, int strict)
    {
        var candidate = side >= 0 ? $", en iyi aday yan gücü {side}/{GamePhoneGeometry.SideThreshold}" : "";
        return $"telefon ilk aramada bulunamadı ({samples} arama): en ileri ölçüt {furthest}, en sık {common} ({commonCount}){candidate}, "
               + $"doğrulanmayan gözlem {unconfirmed} ({strict} sıkı)";
    }

    /// <summary>Oranın yüzdesi (tam sayı).</summary>
    public static int Percent(double share) => (int)Math.Round(share * 100, MidpointRounding.AwayFromZero);

    /// <summary>İki bölgenin en çok oynayan kenarı (kareye oranla).</summary>
    public static double Shift(CropRegion a, CropRegion b) =>
        Math.Max(Math.Max(Math.Abs(a.Top - b.Top), Math.Abs(a.Bottom - b.Bottom)),
                 Math.Max(Math.Abs(a.Left - b.Left), Math.Abs(a.Right - b.Right)));
}

/// <summary>
/// İlk açılışın ıskalanma nedenleri (#1251; GamePhoneTracker). Telefon açık değilken her aramanın ıska ölçütü
/// <see cref="WindowMs"/> boyunca toplanır; pencerede telefona benzer bir şey varsa (kameralı hoparlör yarığı bulundu ya da daha
/// ileri, şerit kalabalık, tek görülüp doğrulanmayan gözlem) pencere sonunda tek satır yazılır
/// (<see cref="PhoneTrace.MissedFirst"/>). Telefonsuz oyunda aramaların hemen hepsi "hoparlör yarığı yok"ta kalır, satır
/// yazılmaz. Mac/iPhone (PhoneMissLog, PhoneTrace.swift) ve Android (PhoneTrace.kt) ile aynı.
/// </summary>
internal sealed class PhoneMissLog
{
    /// <summary>Özet penceresi (ms): en çok bu aralıkla bir satır.</summary>
    internal const long WindowMs = 20_000;
    private long? windowStart;
    private int samples, unconfirmed, unconfirmedStrict, side = -1;
    private GamePhoneGeometry.Step furthest;
    private readonly Dictionary<GamePhoneGeometry.Step, int> counts = [];

    /// <summary>Doğrulanmayı bekleyen gözlem süresi dolup ya da başka yerde gözlem gelip bırakıldı.</summary>
    internal void Unconfirmed(bool strict)
    {
        unconfirmed++;
        if (strict) unconfirmedStrict++;
    }

    internal void Note(GamePhoneGeometry.Probe probe, long now, Action<string> log)
    {
        if (windowStart is not { } start || now < start) windowStart = start = now;
        samples++;
        counts[probe.Step] = counts.GetValueOrDefault(probe.Step) + 1;
        if (probe.Step > furthest) furthest = probe.Step;
        if (probe.Side > side) side = probe.Side;
        if (now - start < WindowMs) return;
        if (Suspicious)
        {
            var common = counts.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key).First();
            log(PhoneTrace.MissedFirst(samples, PhoneTrace.Reason(furthest), PhoneTrace.Reason(common.Key), common.Value, side,
                unconfirmed, unconfirmedStrict));
        }
        Begin(now);
    }

    /// <summary>Pencerede telefona benzer bir şey görüldü mü.</summary>
    private bool Suspicious => furthest >= GamePhoneGeometry.Step.NoBottomSlot || unconfirmed > 0
        || counts.ContainsKey(GamePhoneGeometry.Step.TopCrowded) || counts.ContainsKey(GamePhoneGeometry.Step.BottomCrowded);

    /// <summary>Telefon açıldı ya da izleyici sıfırlandı: pencere baştan.</summary>
    internal void Reset() => Begin(null);

    private void Begin(long? now)
    {
        windowStart = now;
        samples = unconfirmed = unconfirmedStrict = 0;
        side = -1;
        furthest = GamePhoneGeometry.Step.NoPicture;
        counts.Clear();
    }
}

/// <summary>
/// Okunan telefon satırlarının günlük özeti (X, 26 Kas, beta.104: en üstteki uzun mesaj çevrilmiyor, cevap seçenekleri karışık
/// görünüyordu; hangi satırın okunup hangi rolle panele girdiği günlükte yoktu). Her grubun türü (header, bubble, option, note,
/// list, card) ve ilk sözcükleri (<see cref="PhoneChat.RowSummary"/>); özet değişince yazılır, en çok <see cref="IntervalMs"/>'de
/// bir, aynı özet yinelenmez. Mac (PhoneRowsLog, PhoneTrace.swift) ve Android (PhoneRowsLog, PhoneTrace.kt) aynı.
/// </summary>
internal sealed class PhoneRowsLog
{
    internal const long IntervalMs = 5_000;
    /// <summary>Özetin en uzun hâli (karakter).</summary>
    internal const int MaxLength = 400;
    private string? last;
    private long? at;

    /// <summary>Yazılacak satır; okuma boşsa, özet aynıysa ya da son satırdan bu yana <see cref="IntervalMs"/> geçmediyse null.</summary>
    internal string? Line(IReadOnlyCollection<ScreenTranslation.Group> groups, long now)
    {
        if (groups.Count == 0) return null;
        var summary = PhoneChat.RowSummary(groups);
        if (summary == last) return null;
        if (at is { } previous && now >= previous && now - previous < IntervalMs) return null;
        last = summary;
        at = now;
        var shown = summary.Length > MaxLength ? summary[..MaxLength] + "…" : summary;
        return $"telefon satırları: {shown}";
    }
}
