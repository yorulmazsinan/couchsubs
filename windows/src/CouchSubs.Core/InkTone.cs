// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Açık zemin üzerindeki koyu yazı (duvardaki kâğıt ilan, tabela, afiş) altyazı değildir. Kullanıcı bildirimi (GitHub
/// #1124, GTA 6): altyazı alanına denk gelen otel odasındaki kâğıt ilan ("SOILED SHEETS, … WILL BE BILLED TO YOUR ROOM";
/// beyaz kâğıt, siyah yazı) altyazı sanılıp çevriliyordu; plaka/tabela kuralı (SceneText.IsSign, #1052) uzun cümleli
/// ilanı yakalamıyor. Oyun altyazısı açık renkli yazıdır (beyaz/sarı), koyu dış çizgiyle ya da yarı saydam koyu zeminde.
/// Satır kutusunun içindeki ve hemen dışındaki şeridin parlaklığına bakılır (<see cref="IsDarkOnLight"/>). Zemin satır
/// boyunca değişen bir çizgidir: üst ve alt şeridin her sütunu için komşu sütunların ortancası (<see cref="ProfileReach"/>),
/// kutunun içinde üst ile alt arasında doğrusal; kâğıda vuran ışık şeridi ve satır boyunca kararan kâğıt zemin sayılır
/// (#1124, beta.89: açık mavi kâğıtta lacivert yazı, çapraz ışık şeridi). Zemin açık (pastel kâğıt da), yumuşak ve düz;
/// kutunun içindeki koyu küme (Otsu eşiği, zemine göre) zeminden belirgin koyu ve zeminin en çok <see cref="InkShade"/>
/// katı (renkli mürekkep kontrastıyla koyu sayılır), yazı payı makul ve kutuda zeminden parlak harf yoksa yazı koyu, zemin
/// açıktır. Bloğun satırlarının yarıdan çoğu böyleyse blok sahne yazısıdır (<see cref="IsDarkBlock"/>); konuşan adlı blok
/// hep altyazıdır. Koyu altyazılı oyun bozulmasın diye kural oturumda kendini kapatır (<see cref="DarkInkStyle"/>).
/// Mac/iPhone (InkTone.swift) ve Android (InkTone.kt) aynı kuralları ve eşikleri uygular; ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/dark-ink.json.
/// </summary>
public static class InkTone
{
    /// <summary>Yerel zemin (zemin çizgisinin ortancası) en az bu kadarsa açıktır (açık mavi kâğıt #BFE0F0 ≈ 216).</summary>
    public const int LightGround = 140;
    /// <summary>Yazı kümesinin ortalama parlaklığı, altındaki zeminin en çok bu katıysa koyudur (kontrast; lacivert mürekkep de).</summary>
    public const double InkShade = 0.66;
    /// <summary>Yazı kümesi zeminden en az bu kadar koyu olmalı.</summary>
    public const int InkGap = 70;
    /// <summary>Kutudaki yazı noktalarının payı bu aralıkta olmalı.</summary>
    public const double MinInk = 0.04;
    public const double MaxInk = 0.5;
    /// <summary>Zeminden bu kadar (en çok GlowCeiling'e kadar) parlak nokta harftir; payı GlowShare'i aşarsa yazı açık renklidir.</summary>
    public const int Glow = 20;
    public const int GlowCeiling = 250;
    public const double GlowShare = 0.03;
    /// <summary>Yerel zemin düz olmalı: şeridin zemin çizgisinden sapmasının çeyrekler açıklığı en çok bu kadar.</summary>
    public const int GroundSpread = 40;
    /// <summary>Zemin çizgisi yumuşak olmalı: komşu iki sütun arasındaki fark en çok bu kadar.</summary>
    public const int GroundStep = 40;
    /// <summary>Zemin çizgisinin bir sütunu, iki yanındaki bu kadar sütunla birlikte şeridin ortancasıdır.</summary>
    public const int ProfileReach = 4;
    /// <summary>Kutunun dışındaki şeridin kalınlığı (satır yüksekliğine oranla).</summary>
    public const double RingShare = 0.3;
    /// <summary>Altyazı günlüğündeki atılma nedeni.</summary>
    public const string Reason = "koyu yazı açık zeminde (kâğıt/tabela)";

    private const int SamplesX = 48;
    private const int SamplesY = 10;
    private const int RingSamples = 2;
    private const int MinSamples = 16;

    /// <summary><paramref name="box"/> (görüntüye oranla) açık zemin üzerinde koyu yazı mı. <paramref name="luma"/>: (x, y) pikselinin parlaklığı, 0–255.</summary>
    public static bool IsDarkOnLight(TextBox box, int width, int height, Func<int, int, int> luma)
    {
        if (width <= 0 || height <= 0) return false;
        double w = width, h = height;
        var left = Math.Clamp(box.Left, 0, 1) * w;
        var right = Math.Clamp(box.Right, 0, 1) * w;
        var top = Math.Clamp(box.Top, 0, 1) * h;
        var bottom = Math.Clamp(box.Bottom, 0, 1) * h;
        if (right - left < 2 || bottom - top < 2) return false;
        var inside = Grid(left, top, right, bottom, SamplesX, SamplesY, width, height, luma);
        var d = (bottom - top) * RingShare;
        // Şeritler: üst ve alt (SamplesX × RingSamples), sol ve sağ (RingSamples × SamplesY); görüntüden taşan şerit yok.
        var strips = new List<int>?[4];
        if (d >= 1)
        {
            (double L, double T, double R, double B, int Nx, int Ny)[] bounds =
            [
                (left, top - d, right, top, SamplesX, RingSamples),
                (left, bottom, right, bottom + d, SamplesX, RingSamples),
                (left - d, top, left, bottom, RingSamples, SamplesY),
                (right, top, right + d, bottom, RingSamples, SamplesY),
            ];
            for (var i = 0; i < bounds.Length; i++)
            {
                var s = bounds[i];
                if (s.L >= 0 && s.T >= 0 && s.R <= w && s.B <= h)
                    strips[i] = Grid(s.L, s.T, s.R, s.B, s.Nx, s.Ny, width, height, luma);
            }
        }
        return Decide(inside, strips[0], strips[1], strips[2], strips[3]);
    }

    /// <summary>Kutunun içindeki (SamplesX × SamplesY) ve dışındaki şeritlerin parlaklıklarıyla karar.</summary>
    internal static bool Decide(List<int> inside, List<int>? top, List<int>? bottom, List<int>? left, List<int>? right)
    {
        var ringCount = (top?.Count ?? 0) + (bottom?.Count ?? 0) + (left?.Count ?? 0) + (right?.Count ?? 0);
        if (inside.Count != SamplesX * SamplesY || ringCount < MinSamples) return false;
        // Zemin çizgisi: üst ve alt şeridin sütun sütun ortancası; biri yoksa öteki, ikisi de yoksa yan şeritlerin ortancası.
        var upper = top is null ? null : Profile(top);
        var lower = bottom is null ? null : Profile(bottom);
        if (upper is null && lower is null)
        {
            var sides = (left ?? new List<int>()).Concat(right ?? new List<int>()).OrderBy(v => v).ToList();
            upper = Enumerable.Repeat(sides[sides.Count / 2], SamplesX).ToList();
        }
        var up = upper ?? lower!;
        var down = lower ?? upper!;
        int Ground(int column, int row) => up[column] + ((down[column] - up[column]) * ((2 * row) + 1) / (2 * SamplesY));
        var line = up.Concat(down).OrderBy(v => v).ToList();
        if (line[line.Count / 2] < LightGround || line[0] < LightGround - GroundSpread) return false;
        foreach (var p in new[] { up, down })
            for (var c = 1; c < SamplesX; c++)
                if (Math.Abs(p[c] - p[c - 1]) > GroundStep) return false;
        var residuals = new List<int>();
        if (top is not null) residuals.AddRange(top.Select((v, i) => v - up[i % SamplesX]));
        if (bottom is not null) residuals.AddRange(bottom.Select((v, i) => v - down[i % SamplesX]));
        if (left is not null) residuals.AddRange(left.Select((v, i) => v - Ground(0, i / RingSamples)));
        if (right is not null) residuals.AddRange(right.Select((v, i) => v - Ground(SamplesX - 1, i / RingSamples)));
        residuals.Sort();
        if (residuals[residuals.Count * 3 / 4] - residuals[residuals.Count / 4] > GroundSpread) return false;
        var grounds = inside.Select((_, i) => Ground(i % SamplesX, i / SamplesX)).ToList();
        // Zemine göre parlaklık (128 zemin); Otsu eşiğinin altı yazıdır.
        var relative = inside.Select((v, i) => Math.Clamp(v - grounds[i] + 128, 0, 255)).ToList();
        var threshold = Otsu(relative);
        var ink = Enumerable.Range(0, inside.Count).Where(i => relative[i] <= threshold).ToList();
        if (ink.Count == 0 || ink.Count == inside.Count) return false;
        var share = (double)ink.Count / inside.Count;
        if (share < MinInk || share > MaxInk) return false;
        var inkMean = (double)ink.Sum(i => inside[i]) / ink.Count;
        var groundMean = (double)ink.Sum(i => grounds[i]) / ink.Count;
        if (groundMean - inkMean < InkGap || inkMean > groundMean * InkShade) return false;
        var glowing = Enumerable.Range(0, inside.Count).Count(i => inside[i] >= Math.Min(grounds[i] + Glow, GlowCeiling));
        return (double)glowing / inside.Count < GlowShare;
    }

    /// <summary>Şeridin (SamplesX × RingSamples) zemin çizgisi: her sütun için ProfileReach komşusuyla birlikte ortanca.</summary>
    private static List<int> Profile(List<int> strip)
    {
        var profile = new List<int>(SamplesX);
        for (var c = 0; c < SamplesX; c++)
        {
            var values = new List<int>();
            for (var r = 0; r < RingSamples; r++)
                for (var k = Math.Max(0, c - ProfileReach); k <= Math.Min(SamplesX - 1, c + ProfileReach); k++)
                    values.Add(strip[(r * SamplesX) + k]);
            values.Sort();
            profile.Add(values[values.Count / 2]);
        }
        return profile;
    }

    /// <summary>Bloğun kutulu satırlarının yarıdan çoğu açık zeminde koyu yazı mı.</summary>
    public static bool IsDarkBlock(Reading block, Func<TextBox, bool> dark)
    {
        var boxes = block.Lines.Where(line => line.Box is not null).Select(line => line.Box!.Value).ToList();
        if (boxes.Count == 0) return false;
        return boxes.Count(dark) * 2 > boxes.Count;
    }

    /// <summary>Okunan alanın görüntüsü (BGRA) için satır kutusu denetimi (kutular görüntüye oranla).</summary>
    public static Func<TextBox, bool> Sampler(Frame frame) => box =>
        frame.IsConsistent && IsDarkOnLight(box, frame.Width, frame.Height, (x, y) =>
        {
            var p = (y * frame.Stride) + (x * 4);
            int b = frame.Pixels[p], g = frame.Pixels[p + 1], r = frame.Pixels[p + 2];
            return ((299 * r) + (587 * g) + (114 * b)) / 1000;
        });

    private static List<int> Grid(double left, double top, double right, double bottom, int nx, int ny, int width, int height,
                                  Func<int, int, int> luma)
    {
        var values = new List<int>(nx * ny);
        for (var sy = 0; sy < ny; sy++)
        {
            var y = Math.Min(height - 1, (int)(top + ((sy + 0.5) * (bottom - top) / ny)));
            for (var sx = 0; sx < nx; sx++)
            {
                var x = Math.Min(width - 1, (int)(left + ((sx + 0.5) * (right - left) / nx)));
                values.Add(Math.Clamp(luma(x, y), 0, 255));
            }
        }
        return values;
    }

    private static int Otsu(List<int> values)
    {
        var histogram = new int[256];
        foreach (var value in values) histogram[value]++;
        double total = values.Count;
        var sum = 0.0;
        for (var i = 0; i < 256; i++) sum += i * histogram[i];
        double below = 0, belowSum = 0, best = -1;
        var threshold = 127;
        for (var t = 0; t < 255; t++)
        {
            below += histogram[t];
            if (below == 0) continue;
            var above = total - below;
            if (above == 0) break;
            belowSum += t * histogram[t];
            var gap = (belowSum / below) - ((sum - belowSum) / above);
            var between = below * above * gap * gap;
            if (between > best)
            {
                best = between;
                threshold = t;
            }
        }
        return threshold;
    }
}

/// <summary>
/// Oturumun koyu yazılı altyazı biçimi: ortalanmış, birbirinden farklı (biri ötekini içermeyen, benzemeyen) en az
/// <see cref="DistinctBlocks"/> koyu yazılı blok atılınca oyunun altyazısı koyu yazı sayılır ve <see cref="InkTone"/>
/// kuralı o oturumda kapanır. Duvardaki ilan hep aynı yazıdır (kısmi okunsa da), sayılmaz. Hat sıfırlanınca unutulur
/// (Mac/iPhone ve Android: DarkInkStyle).
/// </summary>
public sealed class DarkInkStyle
{
    public const int DistinctBlocks = 4;

    private readonly List<string> texts = [];

    /// <summary>
    /// Oyunun altyazısı bilinen açık renkli yazı (GTA 6: beyaz): kural hiç kapanmaz, koyu bloklar sayılmaz. Kullanıcı
    /// bildirimi (X, beta-104, Windows): telefon bulunamadığı anlarda sohbet balonları atılıyor, dört farklı mesaj
    /// sayılınca kural kapanıyor, sonraki balonlar altyazı sanılıp telefonun ortasından geçen satır olarak ya da balonların
    /// üstüne üst üste çiziliyordu (Mac/iPhone ve Android DarkInkStyle.lightInk ile aynı).
    /// </summary>
    public bool LightInk { get; set; }

    public bool IsGameStyle => !LightInk && texts.Count >= DistinctBlocks;

    /// <summary>Koyu yazılı diye atılan blok (satır kutuları <paramref name="area"/>'ya oranlı). Kural bu blokla kapandıysa true.</summary>
    public bool Observe(Reading block, TextBox area)
    {
        if (LightInk || IsGameStyle || block.Box is not { } whole || !SceneText.IsCentered(whole.PlacedIn(area))) return false;
        var text = TextMatch.Normalize(block.Text);
        if (text.Length == 0
            || texts.Any(seen => seen.Contains(text, StringComparison.Ordinal) || text.Contains(seen, StringComparison.Ordinal)
                                 || TextMatch.IsSimilar(seen, text)))
            return false;
        texts.Add(text);
        return IsGameStyle;
    }

    public void Reset() => texts.Clear();
}
