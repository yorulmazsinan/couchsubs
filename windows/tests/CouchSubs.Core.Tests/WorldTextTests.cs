// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Oyun dünyasındaki yazı (poster, plaka, tabela) çevrilmez; yalnız arayüz kanıtı olan yazı (düz panel zemini, yerinde
/// sabitlik, perspektifsiz satırlar). Sentetik: dokulu sahne kamerayla kayar, üstünde dünya yazısı; sabit HUD kutusu.
/// </summary>
public class WorldTextTests
{
    private static readonly IReadOnlyList<CropRegion> None = [];
    private static readonly byte[] Texture = MakeTexture();

    private static byte[] MakeTexture()
    {
        var random = new Random(3);
        var bytes = new byte[1280 * 360];
        for (var i = 0; i < bytes.Length; i++) bytes[i] = (byte)random.Next(0, 110);
        return bytes;
    }

    /// <summary>
    /// 640x360 kare: <paramref name="pan"/> piksel kaymış dokulu sahne, sahnenin üstünde dünya yazısı (dokulu zeminde açık
    /// çizgiler, kamerayla kayar), isteğe bağlı sabit HUD kutusu (düz koyu zeminde beyaz yazı, sol üstte).
    /// </summary>
    private static Frame Scene(int pan, bool hud, bool worldText = true)
    {
        var frame = Frame.Blank(640, 360);
        for (var y = 0; y < 360; y++)
            for (var x = 0; x < 640; x++)
            {
                var sx = x + pan;
                var value = Texture[y * 1280 + sx % 1280];
                // Dünya yazısı: sahnede 300..460 x 200..260 (kamerayla birlikte kayar), dokunun üstünde açık çizgiler.
                if (worldText && sx is >= 300 and < 460 && y is >= 200 and < 260 && (y - 200) % 9 is 3 or 4 && (sx - 300) % 7 < 4)
                    value = 235;
                var p = y * frame.Stride + x * 4;
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
        if (hud)
            for (var y = 20; y < 80; y++)
                for (var x = 20; x < 180; x++)
                {
                    var value = (byte)((y - 20) % 9 is 3 or 4 && (x - 20) % 7 < 4 ? 240 : 28);
                    var p = y * frame.Stride + x * 4;
                    frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
                }
        return frame;
    }

    [Fact]
    public void PanningCameraFindsTheHudButNotTheWorldText()
    {
        var detector = new ScreenTextDetector();
        var worldAreas = 0;
        for (var step = 0; step < 30; step++)
        {
            detector.Sample(Scene(step * 8, hud: true), step * 100L, None);
            worldAreas += detector.Areas.Count(area => area.Region.Top > 0.4);
        }
        Assert.Equal(0, worldAreas);
        var hud = Assert.Single(detector.Areas);
        Assert.True(hud.Region.Left < 0.1 && hud.Region.Top < 0.1);
    }

    [Fact]
    public void StillCameraDoesNotTurnTexturedWorldTextIntoAnArea()
    {
        var detector = new ScreenTextDetector();
        for (var step = 0; step < 20; step++) detector.Sample(Scene(0, hud: false), step * 100L, None);
        Assert.Empty(detector.Areas);
    }

    private sealed class Reader : ITextReader
    {
        public TextBox Box { get; set; } = new(0.1, 0.3, 0.9, 0.5);
        public string Read(Frame image) => "";
        public Reading ReadLines(Frame image, bool deep) => ReadScreen(image);
        public Reading ReadScreen(Frame image) => new([new TextLine("Bean Machine Coffee and Donuts", Box)]);
    }

    private sealed class Translator : ITextTranslator
    {
        public int Calls;
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref Calls);
            return Task.FromResult("Kahve dükkânı");
        }
    }

    private sealed class Server : IRegionSender
    {
        public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null) { }
        public void ClearRegions() { }
    }

    private static Frame Shade(byte value)
    {
        var frame = Frame.Blank(320, 180);
        Array.Fill(frame.Pixels, value);
        return frame;
    }

    [Fact]
    public async Task SameTextSeenElsewhereIsWorldTextFromThenOn()
    {
        var reader = new Reader();
        var translator = new Translator();
        var rejected = new List<string>();
        var watcher = new RegionWatcher(reader, translator, new Server()) { Rejected = rejected.Add };
        var first = new WatchedArea("auto-1", ScreenTextDetector.AreaName, new CropRegion(0.1, 0.3, 0.1, 0.5)) { Auto = true };
        await watcher.PassAsync(Shade(10), [first]);
        await watcher.PassAsync(Shade(10), [first]);
        Assert.Equal(1, translator.Calls);
        // Kamera kaydı: aynı tabela başka yerde okundu → dünya yazısı; artık hiçbir yerde çevrilmez.
        var moved = new WatchedArea("auto-2", ScreenTextDetector.AreaName, new CropRegion(0.4, 0.6, 0.3, 0.7)) { Auto = true };
        await watcher.PassAsync(Shade(20), [moved]);
        await watcher.PassAsync(Shade(20), [moved]);
        Assert.Contains("auto-2", rejected);
        Assert.Equal(1, translator.Calls);
    }
}
