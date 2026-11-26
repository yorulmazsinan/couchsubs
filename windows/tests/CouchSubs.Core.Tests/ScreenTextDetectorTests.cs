// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using CouchSubs.Core;
using Xunit.Abstractions;

namespace CouchSubs.Core.Tests;

/// <summary>Mac ScreenTextDetectorTests ve Android ScreenTextDetectorTest ile aynı sentetik kareler.</summary>
public class ScreenTextDetectorTests(ITestOutputHelper output)
{
    private const int Width = 640;
    private const int Height = 360;
    private static readonly IReadOnlyList<CropRegion> None = [];

    /// <summary>Her karede değişen gürültülü sahne; istenirse üstünde koyu kutu ve beyaz "yazı" çizgileri.</summary>
    private static Frame Scene(int seed, (int X, int Y, int W, int H)? box = null, int width = Width, int height = Height)
    {
        var frame = Frame.Blank(width, height);
        var random = new Random(seed);
        random.NextBytes(frame.Pixels);
        if (box is { } b)
            for (var y = b.Y; y < b.Y + b.H; y++)
                for (var x = b.X; x < b.X + b.W; x++)
                {
                    var p = y * frame.Stride + x * 4;
                    var ink = (y - b.Y) % 9 is 3 or 4 && (x - b.X) % 7 < 4;
                    var value = (byte)(ink ? 240 : 24);
                    frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
                }
        return frame;
    }

    // Sol üstte, 32x18 ızgarada yaklaşık 8x3 karo (karo 20x20 piksel).
    private static readonly (int, int, int, int) TopLeft = (20, 20, 160, 60);

    private static void Run(ScreenTextDetector detector, long from, long to, Func<int, Frame> frame, IReadOnlyList<CropRegion>? excluded = null)
    {
        for (var time = from; time <= to; time += ScreenTextDetector.SampleIntervalMs)
            detector.Sample(frame((int)time), time, excluded ?? None);
    }

    [Fact]
    public void BoxThatStaysStillIsProposedAfterItSettles()
    {
        var detector = new ScreenTextDetector();
        // Arayüz kanıtı: düz panel zemini ve en az 600 ms yerinde sabitlik.
        Run(detector, 0, 500, seed => Scene(seed, TopLeft));
        Assert.Empty(detector.Areas);
        Run(detector, 600, 700, seed => Scene(seed, TopLeft));
        var area = Assert.Single(detector.Areas);
        Assert.True(area.Auto);
        Assert.StartsWith("auto-", area.Id);
        Assert.Equal(ScreenTextDetector.AreaName, area.Name);
        // Kutu (0.031..0.281 x 0.056..0.222) bölgenin içinde; bölge kutudan çok büyük değil.
        Assert.True(area.Region.Left <= 0.04 && area.Region.Right >= 0.27 && area.Region.Top <= 0.06 && area.Region.Bottom >= 0.22);
        Assert.True(area.Region.Right <= 0.36 && area.Region.Bottom <= 0.32);
    }

    [Fact]
    public void NoisySceneAloneProposesNothing()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 2000, seed => Scene(seed));
        Assert.Empty(detector.Areas);
    }

    [Fact]
    public void BoxThatMovesEverySampleIsNotProposed()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 1500, time => Scene(time, (20 + time / 100 * 20, 20, 160, 60)));
        Assert.Empty(detector.Areas);
    }

    [Fact]
    public void BoxInsideTheSubtitleAreaIsNotProposed()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 1000, seed => Scene(seed, (200, 260, 240, 60)), [new CropRegion()]);
        Assert.Empty(detector.Areas);
        // Aynı kutu altyazı alanı dışında sayılırsa önerilir.
        Run(detector, 1100, 1600, seed => Scene(seed, (200, 260, 240, 60)));
        Assert.Single(detector.Areas);
    }

    [Fact]
    public void RejectedAreaIsNotProposedAgainUntilItChanges()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 700, seed => Scene(seed, TopLeft));
        var id = Assert.Single(detector.Areas).Id;
        detector.Reject(id);
        Assert.Empty(detector.Areas);
        Run(detector, 800, 2300, seed => Scene(seed, TopLeft));
        Assert.Empty(detector.Areas);
        // Kutunun içeriği değişti (yeni yazı): yeniden önerilir, yeni kimlikle.
        Run(detector, 2400, 3200, seed => Scene(seed, (20, 25, 160, 60)));
        Assert.NotEqual(id, Assert.Single(detector.Areas).Id);
    }

    [Fact]
    public void AreaLeavesSevenHundredMillisecondsAfterTheBoxIsGone()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 700, seed => Scene(seed, TopLeft));
        var id = Assert.Single(detector.Areas).Id;
        Run(detector, 800, 1300, seed => Scene(seed));
        Assert.Equal(id, Assert.Single(detector.Areas).Id);
        Run(detector, 1400, 1400, seed => Scene(seed));
        Assert.Empty(detector.Areas);
    }

    [Fact]
    public void AreaKeepsItsIdWhileTheBoxGrows()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 700, seed => Scene(seed, TopLeft));
        var first = Assert.Single(detector.Areas);
        Run(detector, 800, 1700, seed => Scene(seed, (20, 20, 160, 100)));
        var grown = Assert.Single(detector.Areas);
        Assert.Equal(first.Id, grown.Id);
        Assert.True(grown.Region.Bottom > first.Region.Bottom);
    }

    [Fact]
    public void LargeComponentIsSceneTextureNotATextBox()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 1000, seed => Scene(seed, (0, 0, 560, 300)));
        Assert.Empty(detector.Areas);
    }

    [Fact]
    public void ResetForgetsAreas()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 700, seed => Scene(seed, TopLeft));
        Assert.Single(detector.Areas);
        detector.Reset();
        Assert.Empty(detector.Areas);
    }

    [Fact]
    public void SamplesAtMostTenTimesASecond()
    {
        var detector = new ScreenTextDetector();
        Assert.True(detector.Due(0));
        detector.Sample(Scene(0), 0, None);
        Assert.False(detector.Due(50));
        Assert.True(detector.Due(100));
    }

    [Fact]
    public void SampleOfA1080pFrameIsCheap()
    {
        var detector = new ScreenTextDetector();
        var frames = Enumerable.Range(0, 4).Select(seed => Scene(seed, (40, 40, 600, 160), 1920, 1080)).ToArray();
        for (var i = 0; i < 10; i++) detector.Sample(frames[i % 4], i * 100L, None);
        var times = new List<double>();
        for (var i = 0; i < 100; i++)
        {
            var watch = Stopwatch.StartNew();
            detector.Sample(frames[i % 4], 1000 + i * 100L, None);
            times.Add(watch.Elapsed.TotalMilliseconds);
        }
        output.WriteLine($"1920x1080 örnek: ortalama {times.Average():0.000} ms, en kötü {times.Max():0.000} ms (100 tekrar)");
        Assert.True(times.Average() < 20);
    }

    [Theory]
    [InlineData("$1,250", true)]
    [InlineData("12:45", true)]
    [InlineData("PAUSE", true)]
    [InlineData("HONOR", true)]
    [InlineData("LIQUOR STORE", true)]
    [InlineData("x3 Ammo", true)]
    [InlineData("Go to the Saloon.", false)]
    [InlineData("Follow Paulie to the car.", false)]
    [InlineData("Lamar has sent you a message.", false)]
    [InlineData("Press ✕ to open the map.", false)]
    public void NoiseRules(string text, bool noise) => Assert.Equal(noise, ScreenTextNoise.IsNoise(text));

    /// <summary>
    /// Menüde aynı sütundaki alt alta bileşenler arada bir boş karo satırı olsa da tek alandır (#1339: GTA 6 duraklatma
    /// menüsünün "Settings" satırı ayrı alana düşüp kendi başına altına yazılıyordu); iki boş satır ya da başka sütun ayrı
    /// kalır (Mac ve Android aynı).
    /// </summary>
    [Fact]
    public void MenuColumnMergesAcrossOneEmptyRow()
    {
        var column = ScreenTextDetector.MenuColumns([(new ScreenTextDetector.Cells(3, 5, 7, 11), [5 * 32 + 3]),
                                                     (new ScreenTextDetector.Cells(3, 13, 6, 13), [13 * 32 + 3])]);
        Assert.Equal(new ScreenTextDetector.Cells(3, 5, 7, 13), Assert.Single(column).Cells);
        var far = ScreenTextDetector.MenuColumns([(new ScreenTextDetector.Cells(3, 5, 7, 11), [5 * 32 + 3]),
                                                  (new ScreenTextDetector.Cells(3, 14, 6, 14), [14 * 32 + 3])]);
        Assert.Equal(2, far.Count);
        var other = ScreenTextDetector.MenuColumns([(new ScreenTextDetector.Cells(3, 5, 7, 11), [5 * 32 + 3]),
                                                    (new ScreenTextDetector.Cells(12, 13, 16, 13), [13 * 32 + 12])]);
        Assert.Equal(2, other.Count);
        // Ortalı başlık ve alt başlığı (tek satırlık iki bileşen, sol kenarları bir karo farklı) ayrı kalır.
        var titles = ScreenTextDetector.MenuColumns([(new ScreenTextDetector.Cells(13, 8, 18, 8), [8 * 32 + 13]),
                                                     (new ScreenTextDetector.Cells(14, 10, 17, 10), [10 * 32 + 14])]);
        Assert.Equal(2, titles.Count);
    }

    /// <summary>
    /// Menü şeridinin sekmeleri arasındaki seçili (renkli, aday olmayan) sekme alanı ortadan bölmez: aynı karo satırında
    /// iki boş karoya kadar aralıklı bileşenler birleşir (#859); başka satırdaki bileşen ayrı kalır.
    /// </summary>
    [Fact]
    public void TabsOnOneRowMergeAcrossTheSelectedTab()
    {
        var (row, _) = ScreenTextDetector.Merge([(new ScreenTextDetector.Cells(14, 1, 20, 1), [32 + 14]),
                                                  (new ScreenTextDetector.Cells(23, 1, 29, 1), [32 + 23])]);
        Assert.Equal(new ScreenTextDetector.Cells(14, 1, 29, 1), Assert.Single(row).Cells);
        var (apart, _) = ScreenTextDetector.Merge([(new ScreenTextDetector.Cells(14, 1, 20, 1), [32 + 14]),
                                                    (new ScreenTextDetector.Cells(24, 2, 29, 2), [64 + 24])]);
        Assert.Equal(2, apart.Count);
        // İki yanı da geniş sekmeler üç boş karoya kadar birleşir; tek karoluk etiketler (tekerlek menü) ayrı kalır.
        var (wide, _) = ScreenTextDetector.Merge([(new ScreenTextDetector.Cells(16, 1, 22, 1), [32 + 16]),
                                                   (new ScreenTextDetector.Cells(26, 1, 29, 1), [32 + 26])]);
        Assert.Equal(new ScreenTextDetector.Cells(16, 1, 29, 1), Assert.Single(wide).Cells);
        var (narrow, _) = ScreenTextDetector.Merge([(new ScreenTextDetector.Cells(4, 1, 4, 1), [32 + 4]),
                                                     (new ScreenTextDetector.Cells(8, 1, 8, 1), [32 + 8])]);
        Assert.Equal(2, narrow.Count);
    }

    /// <summary>
    /// #1268: menüde kontur yazı karosu (açık harf + koyu kontur, geri kalanı orta ton; GTA 6 haritasının tuş listesi) aday
    /// olur. Gerçek kare denemesi Mac'te (gta6-harita-kart.jpg) ve Android'de.
    /// </summary>
    [Fact]
    public void KonturYaziKarosu()
    {
        Assert.True(ScreenTextDetector.Outlined(48, 74));
        Assert.False(ScreenTextDetector.Outlined(8, 71));
        Assert.False(ScreenTextDetector.Outlined(0, 576));
        Assert.False(ScreenTextDetector.Outlined(400, 100));
    }
}
