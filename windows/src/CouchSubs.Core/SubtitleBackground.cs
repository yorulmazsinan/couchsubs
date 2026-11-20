// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// GTA 6'nın koyu lacivert altyazı zemini: OCR satırının arkasındaki rengi sınar. Panelin dış çizgisini bulmaya
/// çalışmaz; koyu sahnede kenar görünmese de altyazı okunur. Renk aralıkları JPEG/akış sıkıştırmasına pay bırakır.
/// </summary>
public static class SubtitleBackground
{
    private static readonly double[] VerticalSamples = [-0.30, -0.15, 0.10, 0.90, 1.15, 1.30];
    private const int HorizontalSamples = 9;

    /// <summary>Yalnız GTA 6 altyazı zemininin üstündeki OCR satırlarını bırakır.</summary>
    public static Reading Filter(Reading reading, Frame image) =>
        new(reading.Lines.Where(line => line.Box is { } box && HasBackground(image, box)));

    /// <summary>Satırın hemen üstü, içi ve altındaki yatay örnekler aynı lacivert zemini taşıyor mu?</summary>
    public static bool HasBackground(Frame image, TextBox box)
    {
        if (image.Width < 1 || image.Height < 1 || box.Right <= box.Left || box.Bottom <= box.Top) return false;
        var lineHeight = box.Bottom - box.Top;
        var bestRow = 0;
        var total = 0;
        foreach (var offset in VerticalSamples)
        {
            var y = box.Top + lineHeight * offset;
            if (y < 0 || y >= 1) continue;
            var py = Math.Clamp((int)(y * image.Height), 0, image.Height - 1);
            var matches = 0;
            for (var sample = 0; sample < HorizontalSamples; sample++)
            {
                var x = box.Left + (box.Right - box.Left) * (sample + 0.5) / HorizontalSamples;
                var px = Math.Clamp((int)(x * image.Width), 0, image.Width - 1);
                var i = py * image.Stride + px * 4;
                if (IsPanelColor(image.Pixels[i + 2], image.Pixels[i + 1], image.Pixels[i])) matches++;
            }
            bestRow = Math.Max(bestRow, matches);
            total += matches;
        }
        return bestRow >= 7 && total >= 18;
    }

    /// <summary>
    /// Görüntüde ölçülen yaklaşık #21212E; Mac'te #3D3D51'e kadar açık gelebiliyor (#534). Sabit renk yerine kanallar
    /// arası ilişki sınanır: kırmızı ile yeşil yakın, mavi biraz önde (az doygun lacivert), parlaklık geniş aralıkta.
    /// Nötr gri, beyaz/sarı yazı ve doygun mavi (gece göğü, deniz) panel sayılmaz. Mac çekirdeğiyle birebir aynı.
    /// </summary>
    public static bool IsPanelColor(int red, int green, int blue)
    {
        var brightest = Math.Max(red, green);
        if (brightest is < 14 or > 100 || Math.Min(red, green) < 10
            || Math.Abs(red - green) > Math.Max(12, brightest / 5)) return false;
        var lift = blue - brightest;
        return lift >= Math.Max(4, brightest / 10) && lift <= Math.Max(30, brightest / 2);
    }
}
