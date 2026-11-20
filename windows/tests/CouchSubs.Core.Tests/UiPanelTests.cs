// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Hazır ek alanda arayüz kutusu kanıtı (Mac: UiPanelTests.swift, Android: UiPanelTest.kt aynı kareler).</summary>
public class UiPanelTests
{
    /// <summary>Bölge: <paramref name="ground"/> zemin (null: dokulu/dünya), sol üstte yazı çizgileri (<paramref name="text"/> parlaklığında).</summary>
    internal static Frame Region(Func<int, int, byte>? ground, byte text, bool withText = true, int width = 400, int height = 200)
    {
        var frame = Frame.Blank(width, height);
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var value = ground?.Invoke(x, y) ?? Texture(x, y);
                // Yazı: bölgenin sol üst yarısında 2 satır, harf benzeri dikey çizgiler.
                if (withText && x >= 20 && x < 260 && ((y >= 30 && y < 52) || (y >= 70 && y < 92)) && x % 9 < 3) value = text;
                var p = y * frame.Stride + x * 4;
                frame.Pixels[p] = frame.Pixels[p + 1] = frame.Pixels[p + 2] = value;
            }
        return frame;
    }

    /// <summary>Oyun dünyası: geniş ve sert parlaklık dalgalanması (tabela/duvar dokusu).</summary>
    internal static byte Texture(int x, int y) => (byte)(60 + ((x * 7 + y * 13) % 23) * 6 + ((x / 11 + y / 7) % 2) * 40);

    [Fact]
    public void DarkPanelWithWhiteTextIsInterface() =>
        Assert.True(UiPanel.HasText(Region((_, _) => 28, 235)));

    [Fact]
    public void LightPanelWithDarkTextIsInterface() =>
        Assert.True(UiPanel.HasText(Region((_, _) => 225, 30)));

    [Fact]
    public void SemiTransparentPanelOverTheWorldIsInterface() =>
        // Koyu yarı saydam panel: dünya hafifçe sızar (±6).
        Assert.True(UiPanel.HasText(Region((x, y) => (byte)(30 + (Texture(x, y) - 60) / 30), 230)));

    [Fact]
    public void TextOnTheGameWorldIsNotInterface() =>
        Assert.False(UiPanel.HasText(Region(null, 245)));

    [Fact]
    public void FlatAreaWithoutTextIsNotInterface() =>
        Assert.False(UiPanel.HasText(Region((_, _) => 40, 40, withText: false)));

    /// <summary>
    /// Gerçek kareler (yalnız yerel; COUCHSUBS_REAL_FRAMES): her karede GTA 6 hazır alanlarının kanıt sonucu yazdırılır.
    /// K1 (görev kutusu sol üstte) yardım alanında kanıt olmalı.
    /// </summary>
    [Fact]
    public void RealFramesPresetEvidence()
    {
        var root = Environment.GetEnvironmentVariable("COUCHSUBS_REAL_FRAMES");
        if (root is null || !Directory.Exists(Path.Combine(root, "kareler"))) return;
        foreach (var file in Directory.GetFiles(Path.Combine(root, "kareler"), "K*.png").Order())
        {
            var frame = RealFrameTests.Png.Load(file);
            foreach (var area in GameAreaPresets.Areas("GTA 6"))
                Console.WriteLine($"{Path.GetFileName(file)} {area.Id}: {UiPanel.HasText(RegionCropper.Crop(frame, area.Region))}");
        }
        var k1 = RealFrameTests.Png.Load(Path.Combine(root, "kareler", "K1.png"));
        Assert.True(UiPanel.HasText(RegionCropper.Crop(k1, GameAreaPresets.Areas("GTA 6")[0].Region)));
    }

    [Fact]
    public void PanelOnlyInOneCornerOfTheAreaStillCounts()
    {
        // Yardım kutusu bölgenin sol üst köşesinde; bölgenin kalanı oyun dünyası.
        var frame = Region((x, y) => x < 280 && y < 110 ? (byte)26 : Texture(x, y), 235);
        Assert.True(UiPanel.HasText(frame));
    }
}
