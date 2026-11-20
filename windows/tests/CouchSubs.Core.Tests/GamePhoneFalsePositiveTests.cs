// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using Xunit.Abstractions;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Oyun telefonu yanlış pozitifi (LG'de "siyah ekran"): telefon olmayan ekranlarda telefon açılmamalı; açılan telefonun
/// kutusu akıl sınırları içinde kalmalı. Gerçek kareler yalnız yerelde (COUCHSUBS_REAL_FRAMES).
/// </summary>
public class GamePhoneFalsePositiveTests(ITestOutputHelper output)
{
    private static readonly string? Root = Environment.GetEnvironmentVariable("COUCHSUBS_REAL_FRAMES");

    /// <summary>Kareyi 16:9 1920x1080'e (en yakın komşu) gerer: algılayıcı yalnız 16:9 kareye bakar.</summary>
    internal static Frame To169(Frame source, int width = 1920, int height = 1080)
    {
        var frame = Frame.Blank(width, height);
        for (int y = 0; y < height; y++)
        {
            int sy = y * source.Height / height;
            for (int x = 0; x < width; x++)
            {
                int sx = x * source.Width / width;
                Array.Copy(source.Pixels, sy * source.Stride + sx * 4, frame.Pixels, y * frame.Stride + x * 4, 4);
            }
        }
        return frame;
    }

    private static CropRegion? Track(Frame frame)
    {
        var tracker = new GamePhoneTracker();
        tracker.TrySample(frame, 0, out _);
        tracker.TrySample(frame, 400, out var shown);
        return shown;
    }

    [Fact]
    public void RealFramesWithoutPhoneDoNotOpenIt()
    {
        if (Root is null) return;
        foreach (var path in Directory.GetFiles(Path.Combine(Root, "kareler"), "K*.png"))
        {
            var frame = To169(RealFrameTests.Png.Load(path));
            var located = GamePhoneGeometry.Locate(frame);
            output.WriteLine($"{Path.GetFileName(path)}: {(located is { } r ? $"{r.Left:0.00}-{r.Right:0.00} x {r.Top:0.00}-{r.Bottom:0.00}" : "yok")}");
            Assert.Null(Track(frame));
        }
    }

    [Fact]
    public void ImplausiblePhoneBoxIsRejected()
    {
        var frame = Frame.Blank(1920, 1080);
        // Gerçek telefona benzer kutu (sağ yarıda, dikey, ekranın ~%13'ü).
        Assert.True(GamePhoneTracker.Plausible(new CropRegion(0.15, 0.85, 0.45, 0.64), frame));
        // Ekranın tamamı / büyük kısmı.
        Assert.False(GamePhoneTracker.Plausible(new CropRegion(0, 1, 0, 1), frame));
        Assert.False(GamePhoneTracker.Plausible(new CropRegion(0.05, 0.95, 0.2, 0.8), frame));
        // Karenin boyu kadar dar şerit.
        Assert.False(GamePhoneTracker.Plausible(new CropRegion(0.01, 0.98, 0.36, 0.64), frame));
        // Yatay şerit (menü satırı).
        Assert.False(GamePhoneTracker.Plausible(new CropRegion(0.6, 0.75, 0.4, 0.95), frame));
        // Sol kenarda ya da üstte.
        Assert.False(GamePhoneTracker.Plausible(new CropRegion(0.15, 0.85, 0.02, 0.2), frame));
        Assert.False(GamePhoneTracker.Plausible(new CropRegion(0.0, 0.5, 0.5, 0.64), frame));
        // Çok küçük.
        Assert.False(GamePhoneTracker.Plausible(new CropRegion(0.5, 0.6, 0.6, 0.63), frame));
    }

    [Fact]
    public void TrackerNeverOpensAFullScreenPhone()
    {
        var frame = Frame.Blank(1920, 1080);
        var tracker = new GamePhoneTracker(_ => new CropRegion(0, 1, 0, 1));
        tracker.TrySample(frame, 0, out _);
        tracker.TrySample(frame, 400, out var shown);
        Assert.Null(shown);
    }

    [Fact]
    public void ServerDropsBoxesCoveringMostOfTheScreen()
    {
        var small = new ScreenTranslation.Item("Hi", "Selam", new TextBox(0.5, 0.5, 0.6, 0.55), 0.03);
        var huge = new ScreenTranslation.Item("Hi", "Selam", new TextBox(0, 0, 1, 0.9), 0.03);
        // Büyük blok atılır, küçük kalır.
        var (text, blocks) = SubtitleServer.Guard("Selam", new TextBox(0, 0, 1, 0.9), [small, huge]);
        Assert.Equal("Selam", text);
        Assert.Equal([small], blocks);
        // Bloksuz büyük kutu: alan boş gider (TV kaldırır).
        Assert.Equal("", SubtitleServer.Guard("Selam", new TextBox(0, 0, 1, 1), null).Text);
        // Toplamı ekranın %40'ını aşan çok sayıda opak blok da gönderilmez.
        var many = Enumerable.Range(0, 10).Select(i => new ScreenTranslation.Item("x", "y", new TextBox(0, i * 0.1, 0.5, i * 0.1 + 0.1), 0.03)).ToList();
        Assert.Equal("", SubtitleServer.Guard("y", new TextBox(0, 0, 0.5, 1), many).Text);
        // Normal ek alan değişmez.
        Assert.Equal(("Görev", (IReadOnlyList<ScreenTranslation.Item>?)null), SubtitleServer.Guard("Görev", new TextBox(0.7, 0.05, 0.95, 0.1), null));
    }

    [Theory]
    [InlineData(0x24, 0x27, 0x2a)]
    [InlineData(0, 0, 0)]
    [InlineData(0x1a, 0x1c, 0x22)]
    public void FlatDarkScreenDoesNotOpenPhone(byte r, byte g, byte b)
    {
        var frame = Frame.Blank(1920, 1080);
        for (int i = 0; i < frame.Pixels.Length; i += 4)
        {
            frame.Pixels[i] = b; frame.Pixels[i + 1] = g; frame.Pixels[i + 2] = r; frame.Pixels[i + 3] = 255;
        }
        Assert.Null(Track(frame));
    }
}
