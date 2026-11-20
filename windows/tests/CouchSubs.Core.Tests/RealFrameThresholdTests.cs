// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Gerçek kare doğrulamasının ikinci turundaki ortak eşik kararları (Mac ve Android ile aynı).</summary>
public class RealFrameThresholdTests
{
    [Theory]
    [InlineData("SELEGT SBACK Q,", false)] // tek noktalamalı harf az: kural bunu yakalamıyor (raporlandı)
    [InlineData("MeLFaMINE", true)]
    [InlineData("Q, X;", true)]
    [InlineData("Go to the Saloon.", false)]
    [InlineData("cash. Meet her at Delights.", false)]
    [InlineData("SBCK#AX", true)]
    [InlineData("HOLSTER", false)]
    public void GarbledReadings(string text, bool garbled) => Assert.Equal(garbled, ScreenTextNoise.IsGarbled(text));

    /// <summary>Koyu zeminde beyaz çizgili kutu (640x360, karo 20x20).</summary>
    private static Frame Box(int x, int y, int w, int h)
    {
        var frame = Frame.Blank(640, 360);
        Array.Fill(frame.Pixels, (byte)70);
        for (var yy = y; yy < y + h; yy++)
            for (var xx = x; xx < x + w; xx++)
            {
                var p = yy * frame.Stride + xx * 4;
                var value = (byte)((yy - y) % 9 is 3 or 4 && (xx - x) % 7 < 4 ? 240 : 24);
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
        return frame;
    }

    [Fact]
    public void AreaGrowsOneTileSideways()
    {
        var detector = new ScreenTextDetector();
        for (var time = 0; time <= 400; time += 100) detector.Sample(Box(200, 100, 160, 60), time, []);
        var region = Assert.Single(detector.Areas).Region;
        // Kutu 10..17. sütun (200-360 px): bölge bir karo önce (9.) başlar, bir karo sonra (18.) biter.
        Assert.Equal(9.0 / 32, region.Left, 3);
        Assert.Equal(19.0 / 32, region.Right, 3);
    }

    [Fact]
    public void SubtitleAreaIsSkippedOutsideAMenu()
    {
        var detector = new ScreenTextDetector();
        for (var time = 0; time <= 400; time += 100) detector.Sample(Box(200, 260, 240, 60), time, [], new CropRegion());
        Assert.Empty(detector.Areas);
    }
}
