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
    /// <summary>Açık telefon sıkı aramada ve gevşek doğrulamada bulunamadı, son yerindeki iziyle tutuldu (<see cref="PhonePrint"/>; benzerlik %).</summary>
    public static string Held(double similarity) => $"telefon aramada görünmedi, son yerinde iziyle tutuluyor (benzerlik %{Percent(similarity)})";

    /// <summary>Telefon kapandı: son yerdeki iz de tutmadı (en iyi benzerlik %).</summary>
    public static string PrintLost(double similarity) => $"telefonun izi son yerinde tutmadı (benzerlik %{Percent(similarity)})";

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
    /// ıska, en iyi adayın zayıf yanı (yan eşiğine oranla; aday yoksa yazılmaz), tek görülüp doğrulanmayan gözlemler ve üst
    /// şeridin ortalama parlaklığı (<paramref name="level"/>, 0–255; -1: ölçülmedi). Karanlık sahnede
    /// (<see cref="GamePhoneGeometry.DarkLevel"/>) en ileri ölçüte ulaşan aramanın kazancı da yazılır (<paramref name="gain"/>,
    /// 256 = ×1,0).
    /// </summary>
    public static string MissedFirst(int samples, string furthest, string common, int commonCount, int side, int unconfirmed, int strict,
        int level = -1, int gain = 256)
    {
        var candidate = side >= 0 ? $", en iyi aday yan gücü {side}/{GamePhoneGeometry.SideThreshold}" : "";
        var light = "";
        if (level >= 0)
        {
            light = $", parlaklık {level}/255";
            if (level < GamePhoneGeometry.DarkLevel)
                light += gain == GamePhoneGeometry.Equalized ? " (karanlık, ton eşitleme)" : $" (karanlık, kazanç ×{Times(gain)})";
        }
        return $"telefon ilk aramada bulunamadı ({samples} arama): en ileri ölçüt {furthest}, en sık {common} ({commonCount}){candidate}, "
               + $"doğrulanmayan gözlem {unconfirmed} ({strict} sıkı){light}";
    }

    /// <summary>Kazanç (256 = 1) bir ondalıkla, virgülle ("2,5").</summary>
    internal static string Times(int gain)
    {
        int tenths = (gain * 10 + 128) / 256;
        return $"{tenths / 10},{tenths % 10}";
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
/// (<see cref="PhoneTrace.MissedFirst"/>). Karanlık sahnede (pencerenin ortalama parlaklığı
/// <see cref="GamePhoneGeometry.DarkLevel"/>'dan az) hoparlör yarığı bulunan pencere de yazılır: karanlıkta telefon kameranın ya
/// da alt çentiğin önünde kalıyordu ve satır hiç yazılmıyordu (X, beta.104: "karanlıksa olmuyor"). Telefonsuz oyunda
/// aramaların hemen hepsi "hoparlör yarığı yok"ta kalır, satır yazılmaz. Mac/iPhone (PhoneMissLog, PhoneTrace.swift) ve Android (PhoneTrace.kt) ile aynı.
/// </summary>
internal sealed class PhoneMissLog
{
    /// <summary>Özet penceresi (ms): en çok bu aralıkla bir satır.</summary>
    internal const long WindowMs = 20_000;
    private long? windowStart;
    private int samples, unconfirmed, unconfirmedStrict, side = -1;
    private GamePhoneGeometry.Step furthest;
    private readonly Dictionary<GamePhoneGeometry.Step, int> counts = [];
    /// <summary>Ölçülen parlaklıkların toplamı ve sayısı; en ileri ölçüte ulaşan aramanın kazancı.</summary>
    private int levelSum, levels, gain = 256;

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
        if (probe.Step > furthest)
        {
            furthest = probe.Step;
            gain = probe.Gain;
        }
        if (probe.Side > side) side = probe.Side;
        if (probe.Level >= 0)
        {
            levelSum += probe.Level;
            levels++;
        }
        if (now - start < WindowMs) return;
        if (Suspicious)
        {
            var common = counts.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key).First();
            log(PhoneTrace.MissedFirst(samples, PhoneTrace.Reason(furthest), PhoneTrace.Reason(common.Key), common.Value, side,
                unconfirmed, unconfirmedStrict, Level, gain));
        }
        Begin(now);
    }

    /// <summary>Pencerenin ortalama parlaklığı (0–255); ölçülmediyse -1.</summary>
    private int Level => levels > 0 ? levelSum / levels : -1;

    /// <summary>Pencerede telefona benzer bir şey görüldü mü; karanlık sahnede hoparlör yarığı yeter.</summary>
    private bool Suspicious => furthest >= GamePhoneGeometry.Step.NoBottomSlot || unconfirmed > 0
        || counts.ContainsKey(GamePhoneGeometry.Step.TopCrowded) || counts.ContainsKey(GamePhoneGeometry.Step.BottomCrowded)
        || (Level >= 0 && Level < GamePhoneGeometry.DarkLevel && furthest >= GamePhoneGeometry.Step.NoCamera);

    /// <summary>Telefon açıldı ya da izleyici sıfırlandı: pencere baştan.</summary>
    internal void Reset() => Begin(null);

    private void Begin(long? now)
    {
        windowStart = now;
        samples = unconfirmed = unconfirmedStrict = 0;
        side = -1;
        furthest = GamePhoneGeometry.Step.NoPicture;
        counts.Clear();
        levelSum = levels = 0;
        gain = 256;
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

/// <summary>
/// Telefon aramasının durumu, GTA 6 oynanırken <see cref="WindowMs"/>'de bir tek satır (beta-105, X: "telefon komple
/// çalışmıyor"; #1385'in beta-104 günlüğünde telefon hiç bulunamayınca tek satır yoktu: <see cref="PhoneMissLog"/> yalnız
/// telefona benzer bir şey görüldüğünde yazar). Satır telefonun açık mı kapalı mı olduğunu, pencerede kaç arama yapılıp
/// kaçında bulunduğunu, en sık ve en ileri ıska ölçütünü, üst şeridin ortalama parlaklığını, karenin ortanca parlaklığını ve
/// boyunu verir (Mac/iPhone renk uzayını, Android çözücü biçimini ve ham Y aralığını da ekler). Mac/iPhone
/// (PhoneSearchStatus, PhoneTrace.swift) ve Android (PhoneSearchStatus, PhoneTrace.kt) aynı metin; ortak deneme
/// Fixtures/phone-search-status.json.
/// </summary>
internal sealed class PhoneSearchStatus
{
    internal const long WindowMs = 30_000;
    internal const int Columns = 64, Rows = 36;
    private long? windowStart;
    private int searches, found, levelSum, levels;
    private GamePhoneGeometry.Step? furthest;
    private readonly Dictionary<GamePhoneGeometry.Step, int> counts = [];

    /// <summary>Bir arama: sıkı aramanın sonucu (yoksa null), telefon bu aramada bulundu mu. Satır zamanı geldiyse true.</summary>
    internal bool Note(GamePhoneGeometry.Probe? probe, bool seen, long now)
    {
        if (windowStart is not { } start || now < start) windowStart = start = now;
        searches++;
        if (seen) found++;
        if (probe is { } p)
        {
            counts[p.Step] = counts.GetValueOrDefault(p.Step) + 1;
            if (furthest is not { } f || p.Step > f) furthest = p.Step;
            if (p.Level >= 0)
            {
                levelSum += p.Level;
                levels++;
            }
        }
        return now - start >= WindowMs;
    }

    /// <summary>Pencerenin satırı; pencere baştan başlar. <paramref name="median"/>: karenin ortanca parlaklığı (0–255).</summary>
    internal string Line(bool open, int width, int height, int median, string? frame)
    {
        var level = levels > 0 ? levelSum / levels : -1;
        var text = new System.Text.StringBuilder($"telefon arama durumu ({WindowMs / 1000} sn): telefon {(open ? "açık" : "kapalı")}, ");
        text.Append($"{searches} arama, {found} bulundu, ");
        if (counts.Count > 0)
        {
            var common = counts.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key).First();
            text.Append($"en sık ölçüt {PhoneTrace.Reason(common.Key)} ({common.Value})");
        }
        else text.Append("en sık ölçüt yok");
        text.Append(", en ileri ölçüt ").Append(furthest is { } f ? PhoneTrace.Reason(f) : "yok");
        text.Append(", üst şerit parlaklığı ").Append(level >= 0 ? $"{level}/255" : "ölçülmedi");
        if (level >= 0 && level < GamePhoneGeometry.DarkLevel) text.Append(" (karanlık)");
        text.Append($", ortanca parlaklık {median}/255, kare {width}x{height}");
        if (!string.IsNullOrEmpty(frame)) text.Append(", ").Append(frame);
        Reset();
        return text.ToString();
    }

    internal void Reset()
    {
        windowStart = null;
        searches = found = levelSum = levels = 0;
        furthest = null;
        counts.Clear();
    }

    /// <summary>Tonların (0–255) ortancası; boşsa 0.</summary>
    internal static int Median(int[] tones)
    {
        if (tones.Length == 0) return 0;
        var sorted = (int[])tones.Clone();
        Array.Sort(sorted);
        return sorted[(sorted.Length - 1) / 2];
    }

    /// <summary>Karenin (BGRA) ortanca parlaklığı (0–255): <see cref="Columns"/>×<see cref="Rows"/> noktada 77·R + 150·G + 29·B.</summary>
    internal static int Median(Frame frame)
    {
        if (frame.Width <= 0 || frame.Height <= 0 || !frame.IsConsistent) return 0;
        var tones = new int[Columns * Rows];
        for (var y = 0; y < Rows; y++)
            for (var x = 0; x < Columns; x++)
            {
                var px = Math.Clamp((int)((x + 0.5) * frame.Width / Columns), 0, frame.Width - 1);
                var py = Math.Clamp((int)((y + 0.5) * frame.Height / Rows), 0, frame.Height - 1);
                var p = py * frame.Stride + px * 4;
                tones[y * Columns + x] = (frame.Pixels[p] * 29 + frame.Pixels[p + 1] * 150 + frame.Pixels[p + 2] * 77) >> 8;
            }
        return Median(tones);
    }
}
