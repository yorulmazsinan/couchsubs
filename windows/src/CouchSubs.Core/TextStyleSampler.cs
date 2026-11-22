// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Yazı bloğunun görünüşü (çeviri özgün yazının stilinde çizilsin diye): kalın mı, dar mı, hizası, BÜYÜK HARF mi ve
/// zemin düz mü. Düz zeminde kutu zemin rengiyle tam opak doldurulur; değilse (harita, dünya) %85 opak kaplanır.
/// TV'ye region bloklarının <c>style</c> alanıyla (<c>flat</c> <c>surface</c> içinde) gider; eski TV yok sayar.
/// </summary>
public sealed record TextLook(bool Bold, bool Condensed, string Align, bool Upper, bool Flat);

/// <summary>
/// Otomatik bulunan ekran yazısının stilini kareden çıkarır (Mac/Android: TextStyleSampler ile aynı kurallar). Blok
/// kutusundaki pikseller parlaklığa göre iki kümeye ayrılır (Otsu eşiği): az olan küme yazı, çok olan zemin.
/// </summary>
public static class TextStyleSampler
{
    /// <summary>Yazı pikseli oranı (satır kutularında) en az bu kadarsa kalın.</summary>
    public const double BoldInk = 0.28;
    /// <summary>Ortalama harf genişliği / satır yüksekliği bundan küçükse dar yazı ailesi.</summary>
    public const double CondensedWidth = 0.45;
    /// <summary>Özgün harflerin en az bu kadarı büyükse çeviri de büyük harfe çevrilir.</summary>
    public const double UpperShare = 0.8;
    /// <summary>Zemin kümesinin renk sapması bundan küçükse düz zemin.</summary>
    public const double FlatDeviation = 16;

    public static readonly PhoneTextStyle Neutral = new("#000000", "#FFFFFF");

    private const int SamplesX = 48;
    private const int SamplesY = 10;

    /// <summary>
    /// <paramref name="frame"/>: okunan alanın görüntüsü; <paramref name="box"/> ve <paramref name="lines"/> ona oranla.
    /// <paramref name="lines"/>: bloğun satırları (metni ve kutusu); boşsa yalnız blok kutusu örneklenir.
    /// </summary>
    public static (PhoneTextStyle Surface, TextLook Look) Sample(Frame frame, TextBox box, IReadOnlyList<TextLine> lines, string source,
                                                                 double flatLimit = FlatDeviation)
    {
        var boxes = lines.Where(line => line.Box is not null).Select(line => line.Box!.Value).ToList();
        if (boxes.Count == 0) boxes = [box];
        var pixels = new List<(int Luma, byte R, byte G, byte B, bool Edge)>();
        foreach (var area in boxes) Collect(frame, area, pixels);
        var upper = IsUpper(source);
        var align = Alignment(boxes);
        var condensed = Condensed(frame, lines);
        if (pixels.Count < 8) return (Neutral, new TextLook(false, condensed, align, upper, false));

        var threshold = Otsu(pixels);
        var low = pixels.Where(pixel => pixel.Luma <= threshold).ToList();
        var high = pixels.Where(pixel => pixel.Luma > threshold).ToList();
        if (low.Count == 0 || high.Count == 0) return (Neutral, new TextLook(false, condensed, align, upper, false));
        var (ink, ground) = low.Count < high.Count ? (low, high) : (high, low);
        // Zemin çok olan küme; ama kutunun hemen dışındaki şerit (yazı yok) öteki kümeye yakınsa zemin odur. Sıkı kutudaki
        // kalın dar yazıda (GTA 6 sekmeleri, tuş ipuçları) harf noktaları zeminden çok olabiliyor, kutu beyaz çiziliyordu
        // (#860). Kutunun kendi kenarı da çok olan kümedeyse (seçili menü satırının ters renkli zemini kutunun kendisidir,
        // şeridi değil) çok olan küme zemin kalır.
        var ring = Surrounding(frame, boxes);
        if (ring is not null)
        {
            var around = (double)ring.Select(p => p.Luma).OrderBy(v => v).ElementAt(ring.Count / 2);
            var lowFirst = Math.Abs(low.Average(p => p.Luma) - around) <= Math.Abs(high.Average(p => p.Luma) - around);
            var groundIsLow = low.Count >= high.Count;
            var edges = pixels.Count(p => p.Edge);
            var edgeShare = edges == 0 ? 0 : (double)ground.Count(p => p.Edge) / edges;
            if (lowFirst != groundIsLow && edgeShare < FilledEdge) (ink, ground) = (ground, ink);
        }
        var bold = (double)ink.Count / pixels.Count >= BoldInk;
        var background = Mean(ground);
        var foreground = Mean(ink);
        var flat = Deviation(ground) < flatLimit;
        var shade = ground.Average(pixel => pixel.Luma);
        // Düz olmayan zeminde kenarlıklı yazı (GTA 6 haritasındaki tuş ipuçları: beyaz harf, koyu kenarlık, açık mavi deniz):
        // kutunun içinde üç ton var, zemin kümesi harfle denizin karışımı çıkıyor, kutu denizin üstünde açık gri
        // çiziliyordu. Yazının hemen çevresindeki şerit düzse zemin odur.
        if (!flat && ring is not null && Deviation(ring) < flatLimit)
        {
            background = Mean(ring);
            shade = ring.Average(pixel => pixel.Luma);
        }
        if (DesignTokens.Contrast(background, foreground) < 3)
            foreground = shade < 128 ? "#FFFFFF" : "#000000";
        return (new PhoneTextStyle(background, foreground), new TextLook(bold, condensed, align, upper, flat));
    }

    /// <summary>Türkçe kurallarıyla büyük harf (i → İ, ı → I); yazı tanıma ve sistem diline bağlı değildir.</summary>
    public static string TurkishUpper(string text) =>
        text.Replace('i', 'İ').Replace('ı', 'I').ToUpperInvariant();

    /// <summary>Harflerin en az %80'i büyük mü.</summary>
    public static bool IsUpper(string text)
    {
        var letters = text.Where(char.IsLetter).ToList();
        return letters.Count > 0 && letters.Count(char.IsUpper) >= UpperShare * letters.Count;
    }

    private static void Collect(Frame frame, TextBox area, List<(int Luma, byte R, byte G, byte B, bool Edge)> pixels)
    {
        var left = Math.Clamp(area.Left, 0, 1) * frame.Width;
        var right = Math.Clamp(area.Right, 0, 1) * frame.Width;
        var top = Math.Clamp(area.Top, 0, 1) * frame.Height;
        var bottom = Math.Clamp(area.Bottom, 0, 1) * frame.Height;
        if (right - left < 2 || bottom - top < 2) return;
        for (var sy = 0; sy < SamplesY; sy++)
        {
            var y = Math.Min(frame.Height - 1, (int)(top + (sy + 0.5) * (bottom - top) / SamplesY));
            for (var sx = 0; sx < SamplesX; sx++)
            {
                var x = Math.Min(frame.Width - 1, (int)(left + (sx + 0.5) * (right - left) / SamplesX));
                var p = y * frame.Stride + x * 4;
                byte b = frame.Pixels[p], g = frame.Pixels[p + 1], r = frame.Pixels[p + 2];
                pixels.Add(((299 * r + 587 * g + 114 * b) / 1000, r, g, b,
                            sx == 0 || sy == 0 || sx == SamplesX - 1 || sy == SamplesY - 1));
            }
        }
    }

    /// <summary>
    /// Satır kutularının hemen dışındaki şeridin (üstte ve altta satır yüksekliğinin dörtte biri, yanlarda aynı genişlikte)
    /// noktaları; şerit kareden taşıyorsa ya da başka satırın kutusuna giriyorsa o parça atlanır.
    /// </summary>
    public const double RingShare = 0.25;
    /// <summary>Kutunun kenar noktalarının en az bu kadarı çok olan kümedeyse kutu dolu bir zemindir (seçili satır); şeride bakılmaz.</summary>
    public const double FilledEdge = 0.7;

    private static List<(int Luma, byte R, byte G, byte B, bool Edge)>? Surrounding(Frame frame, IReadOnlyList<TextBox> boxes)
    {
        var pixels = new List<(int Luma, byte R, byte G, byte B, bool Edge)>();
        var aspect = (double)frame.Width / Math.Max(1, frame.Height);
        foreach (var box in boxes)
        {
            var dy = (box.Bottom - box.Top) * RingShare;
            var dx = dy / aspect;
            TextBox[] strips =
            [
                new(box.Left, box.Top - dy, box.Right, box.Top),
                new(box.Left, box.Bottom, box.Right, box.Bottom + dy),
                new(box.Left - dx, box.Top, box.Left, box.Bottom),
                new(box.Right, box.Top, box.Right + dx, box.Bottom),
            ];
            foreach (var strip in strips)
                if (strip.Left >= 0 && strip.Top >= 0 && strip.Right <= 1 && strip.Bottom <= 1
                    && !boxes.Any(other => ScreenTranslation.Overlap(other, strip) > 0.2))
                    Collect(frame, strip, pixels);
        }
        return pixels.Count < 16 ? null : pixels;
    }

    private static int Otsu(List<(int Luma, byte R, byte G, byte B, bool Edge)> pixels)
    {
        var histogram = new int[256];
        foreach (var pixel in pixels) histogram[pixel.Luma]++;
        double total = pixels.Count, sum = 0;
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
            var meanBelow = belowSum / below;
            var meanAbove = (sum - belowSum) / above;
            var between = below * above * (meanBelow - meanAbove) * (meanBelow - meanAbove);
            if (between > best) (best, threshold) = (between, t);
        }
        return threshold;
    }

    private static string Mean(List<(int Luma, byte R, byte G, byte B, bool Edge)> pixels) =>
        $"#{(int)pixels.Average(p => p.R):X2}{(int)pixels.Average(p => p.G):X2}{(int)pixels.Average(p => p.B):X2}";

    private static double Deviation(List<(int Luma, byte R, byte G, byte B, bool Edge)> pixels)
    {
        double Spread(Func<(int, byte R, byte G, byte B, bool), double> channel)
        {
            var mean = pixels.Average(channel);
            return Math.Sqrt(pixels.Average(p => (channel(p) - mean) * (channel(p) - mean)));
        }
        return (Spread(p => p.R) + Spread(p => p.G) + Spread(p => p.B)) / 3;
    }

    private static bool Condensed(Frame frame, IReadOnlyList<TextLine> lines)
    {
        var ratios = lines
            .Where(line => line.Box is not null && line.Text.Trim().Length > 0)
            .Select(line =>
            {
                var b = line.Box!.Value;
                var height = Math.Max(1, (b.Bottom - b.Top) * frame.Height);
                return (b.Right - b.Left) * frame.Width / line.Text.Trim().Length / height;
            })
            .ToList();
        return ratios.Count > 0 && ratios.Average() < CondensedWidth;
    }

    private static string Alignment(IReadOnlyList<TextBox> boxes)
    {
        if (boxes.Count < 2) return "left";
        var width = Math.Max(1e-6, boxes.Max(b => b.Right) - boxes.Min(b => b.Left));
        double Spread(Func<TextBox, double> edge) => (boxes.Max(edge) - boxes.Min(edge)) / width;
        var left = Spread(b => b.Left);
        var center = Spread(b => (b.Left + b.Right) / 2);
        var right = Spread(b => b.Right);
        // Eşitlikte (aynı genişlikteki satırlar) sola yaslı sayılır.
        if (left <= center + 0.01 && left <= right + 0.01) return "left";
        return center <= right + 0.01 ? "center" : "right";
    }
}
