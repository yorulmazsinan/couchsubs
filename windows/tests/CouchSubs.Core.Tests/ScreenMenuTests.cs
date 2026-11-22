// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Ekrandaki menüler (Mac ScreenMenuTests ve Android ScreenMenuTest ile aynı sentetik tekerlek menü).</summary>
public class ScreenMenuTests
{
    private static readonly IReadOnlyList<CropRegion> None = [];

    // 640x360 karede karo 20x20 piksel. Tekerlek menünün sekiz etiketi, ortada başlık ve gri alt başlık.
    private static readonly (int Column, int Row, int Width)[] Labels =
        [(8, 4, 1), (16, 2, 1), (24, 4, 1), (27, 9, 1), (24, 14, 1), (16, 16, 1), (8, 14, 1), (4, 9, 1)];

    private static void Paint(Frame frame, int column, int row, int width, byte ink)
    {
        for (var y = row * 20 + 3; y < row * 20 + 17; y++)
            for (var x = column * 20; x < (column + width) * 20; x++)
            {
                var value = (byte)((y - row * 20) % 6 is 2 or 3 && x % 5 < 2 ? ink : 24);
                var p = y * frame.Stride + x * 4;
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
    }

    /// <summary>Bulanık (düz gri) zeminde tekerlek menü.</summary>
    private static Frame Wheel()
    {
        var frame = Frame.Blank(640, 360);
        Array.Fill(frame.Pixels, (byte)70);
        foreach (var (column, row, width) in Labels) Paint(frame, column, row, width, 240);
        Paint(frame, 13, 8, 6, 240);
        Paint(frame, 14, 10, 4, 175);
        return frame;
    }

    private static Frame Blurred()
    {
        var frame = Frame.Blank(640, 360);
        Array.Fill(frame.Pixels, (byte)70);
        return frame;
    }

    private static void Run(ScreenTextDetector detector, long from, long to, Func<long, Frame> frame)
    {
        for (var time = from; time <= to; time += ScreenTextDetector.SampleIntervalMs)
            detector.Sample(frame(time), time, None);
    }

    [Fact]
    public void WheelMenuIsDetectedWithItsShortLabels()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 400, _ => Wheel());
        Assert.True(detector.InMenu);
        var areas = detector.Areas;
        Assert.Equal(10, areas.Count);
        Assert.All(areas, area => Assert.True(area.Menu && area.Auto));
    }

    [Fact]
    public void ClosingTheMenuRemovesEveryBoxAtOnce()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 400, _ => Wheel());
        Assert.NotEmpty(detector.Areas);
        detector.Sample(Blurred(), 500, None);
        Assert.False(detector.InMenu);
        Assert.Empty(detector.Areas);
    }

    /// <summary>
    /// Menü kapandıktan sonra sakin (karanlık) sahnede ayrı ayrı belirmiş üç yazı menüyü sürdürmez. GTA 6 "Gone Fishing"
    /// (2026-11-22): menü durumu bitmedi, altyazı bütün oturum okunmadı (Mac ve iPhone ile aynı sınama).
    /// </summary>
    [Fact]
    public void MenuEndsWhenItsOwnLabelsLeaveEvenIfOtherTextStays()
    {
        (int Column, int Row, int Width, long From)[] scene = [(1, 0, 2, 500), (29, 0, 2, 900), (1, 17, 3, 1300)];
        Frame Scene(long time, bool wheel)
        {
            var frame = wheel ? Wheel() : Blurred();
            foreach (var (column, row, width, from) in scene)
                if (time >= from) Paint(frame, column, row, width, 240);
            return frame;
        }
        var detector = new ScreenTextDetector();
        Run(detector, 0, 1900, time => Scene(time, true));
        Assert.True(detector.InMenu);
        Run(detector, 2000, 4000, time => Scene(time, false));
        Assert.False(detector.InMenu);
    }

    /// <summary>Menüde hiçbir şey değişmeden 5 sn geçince menü biter, aynı yazılarla yeniden açılmaz (Mac ile aynı).</summary>
    [Fact]
    public void StillMenuExpiresAndOnlyANewMenuReopens()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 400, _ => Wheel());
        Assert.True(detector.InMenu);
        Run(detector, 500, 5000, _ => Wheel());
        Assert.True(detector.InMenu);
        Run(detector, 5100, 8000, _ => Wheel());
        Assert.False(detector.InMenu);
        Run(detector, 8100, 8200, _ => Blurred());
        Run(detector, 8300, 8800, _ => Wheel());
        Assert.True(detector.InMenu);
    }

    [Fact]
    public void NavigatingKeepsTheOtherBoxes()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 400, _ => Wheel());
        var before = detector.Areas.Select(area => area.Id).ToHashSet();
        // Seçim çerçevesi bir etiketin üstüne geçti: o etiketin karosu değişti, diğerleri yerinde.
        Run(detector, 500, 800, time =>
        {
            var frame = Wheel();
            Paint(frame, 8, 4, 1, (byte)(time % 200 == 0 ? 200 : 250));
            for (var x = 160; x < 180; x++) frame.Pixels[(4 * 20 + 1) * frame.Stride + x * 4 + 2] = (byte)(time / 10);
            return frame;
        });
        Assert.True(detector.InMenu);
        Assert.True(detector.Areas.Count(area => before.Contains(area.Id)) >= 9);
    }

    [Fact]
    public void LabelsOnABusyMovingSceneAreNotAMenu()
    {
        var detector = new ScreenTextDetector();
        Run(detector, 0, 1000, time =>
        {
            var frame = Frame.Blank(640, 360);
            new Random((int)time).NextBytes(frame.Pixels);
            foreach (var (column, row, width) in Labels) Paint(frame, column, row, width, 240);
            return frame;
        });
        Assert.False(detector.InMenu);
    }

    [Theory]
    [InlineData("OFF", false)]
    [InlineData("ON", false)]
    [InlineData("OUTFITS", false)]
    [InlineData("CURRENT OUTFIT", false)]
    [InlineData("40", true)]
    [InlineData("0", true)]
    [InlineData("x3", true)]
    [InlineData("100%", true)]
    public void ShortLabelsAreTranslatedOnlyInAMenu(string text, bool noiseInMenu)
    {
        Assert.Equal(noiseInMenu, ScreenTextNoise.IsNoise(text, menu: true));
        Assert.True(ScreenTextNoise.IsNoise(text, menu: false));
    }

    [Theory]
    [InlineData("OFF", "KAPALI")]
    [InlineData("Off", "Kapalı")]
    [InlineData("off", "kapalı")]
    [InlineData("ON", "AÇIK")]
    [InlineData("SETTINGS", "AYARLAR")]
    [InlineData("Inventory", "Envanter")]
    [InlineData("STATS", "İSTATİSTİKLER")]
    [InlineData("EXIT", "ÇIKIŞ")]
    public void ShortLabelsComeFromTheDictionaryKeepingTheirCase(string label, string turkish) =>
        Assert.Equal(turkish, UiCommands.TranslateLabel(label));

    [Fact]
    public void UnknownLabelsAreLeftToPacksAndTheEngine()
    {
        Assert.Null(UiCommands.TranslateLabel("CURRENT OUTFIT"));
        Assert.Null(UiCommands.TranslateLabel("40"));
    }
}
