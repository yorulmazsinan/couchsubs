// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// GTA 6 menü/görev ekranı (#856, #859, #860): menü şeridinin sekmeleri ayrı, yalnız özel addan oluşan sekme çevrilmez,
/// satır ucundaki tuş simgesi kutunun dışında, saat çevrilmez. Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/screen-menu.json (Mac ScreenMenuBarTests.swift ve Android ScreenMenuBarTest.kt ile aynı vakalar).
/// </summary>
public class ScreenMenuBarTests
{
    private static JsonElement Vectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-menu.json")));
        return fixture.RootElement.Clone();
    }

    private static TextBox Box(JsonElement element)
    {
        var v = element.EnumerateArray().Select(item => item.GetDouble()).ToArray();
        return new TextBox(v[0], v[1], v[2], v[3]);
    }

    private static List<TextWord>? Words(JsonElement vector) =>
        vector.TryGetProperty("words", out var words)
            ? [.. words.EnumerateArray().Select(word => new TextWord(word.GetProperty("text").GetString()!, Box(word.GetProperty("box"))))]
            : null;

    [Fact]
    public void NamesOnlyAreKept()
    {
        foreach (var name in Vectors().GetProperty("names").EnumerateArray())
        {
            var text = name.GetProperty("text").GetString()!;
            var keep = name.GetProperty("keep").GetBoolean();
            Assert.True(ScreenTranslation.KeepsNames(text) == keep, text);
            if (keep) Assert.Equal(text, ScreenTranslation.Known(text));
        }
    }

    [Fact]
    public void ClocksAreNotTranslated()
    {
        foreach (var clock in Vectors().GetProperty("clocks").EnumerateArray())
        {
            var text = clock.GetProperty("text").GetString()!;
            Assert.True(ScreenTranslation.IsClock(text) == clock.GetProperty("clock").GetBoolean(), text);
        }
    }

    [Fact]
    public void MenuBarSplitsIntoTabs()
    {
        foreach (var menu in Vectors().GetProperty("menuLines").EnumerateArray())
        {
            var box = Box(menu.GetProperty("box"));
            var line = new TextLine(menu.GetProperty("text").GetString()!, box, null, Words(menu));
            var pieces = ScreenTranslation.MenuPieces(line);
            var expected = menu.GetProperty("pieces").EnumerateArray().Select(item => item.GetString()!).ToArray();
            Assert.Equal(expected, pieces.Select(piece => piece.Text));
            Assert.All(pieces, piece => Assert.Equal(box.Top, piece.Box!.Value.Top));
        }
    }

    [Fact]
    public void EdgeButtonsStayOutsideTheBox()
    {
        foreach (var edge in Vectors().GetProperty("edgeIcons").EnumerateArray())
        {
            var name = edge.GetProperty("name").GetString()!;
            var text = edge.GetProperty("text").GetString()!;
            IReadOnlyList<IconSlot>? icons = edge.TryGetProperty("icons", out var list)
                ? [.. list.EnumerateArray().Select(icon => new IconSlot(Box(icon), ""))] : null;
            var line = new TextLine(text, Box(edge.GetProperty("box")), null, Words(edge), icons);
            var trimmed = ScreenTranslation.WithoutEdgeIcons(line);
            Assert.True(trimmed.Text == edge.GetProperty("expected").GetString(), name);
            Assert.True(Math.Abs(trimmed.Box!.Value.Left - edge.GetProperty("left").GetDouble()) < 1e-9, name);
            Assert.True(Math.Abs(trimmed.Box!.Value.Right - edge.GetProperty("right").GetDouble()) < 1e-9, name);
            if (trimmed.Text != text) Assert.Null(trimmed.Icons);
        }
    }

    /// <summary>Menü şeridi sözcük yerleri olmadan da görüntüdeki boşluklardan bölünür (sözcük kutuları boşluğu kapsıyor).</summary>
    [Fact]
    public void MenuBarSplitsFromThePixels()
    {
        const int width = 960, height = 60;
        var frame = Frame.Blank(width, height);
        for (var p = 0; p < frame.Pixels.Length; p += 4)
            (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) = (30, 30, 30, 255);
        // Üç sekme: harf benzeri dikey çizgiler (harf başına ~14 nokta), sekmeler arasında geniş boşluk.
        foreach (var (start, end) in new[] { (40, 222), (300, 342), (420, 532) })
            for (var x = start; x < end; x++)
            {
                if ((x - start) % 12 >= 6) continue;
                for (var y = 15; y < 45; y++)
                {
                    var p = y * frame.Stride + x * 4;
                    (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2]) = (230, 230, 230);
                }
            }
        var line = new TextLine("JASON & LUCIA MAP PROGRESS", new TextBox(40.0 / 960, 0.25, 532.0 / 960, 0.75));
        var pieces = ScreenTranslation.MenuPieces(line, 16, frame);
        Assert.Equal(["JASON & LUCIA", "MAP", "PROGRESS"], pieces.Select(piece => piece.Text));
        Assert.InRange(pieces[1].Box!.Value.Left, 300.0 / 960 - 0.003, 300.0 / 960 + 0.003);
        Assert.InRange(pieces[1].Box!.Value.Right, 342.0 / 960 - 0.01, 342.0 / 960 + 0.01);
    }

    /// <summary>Görev kartı: başlığın solunda portre var, açıklama portrenin altından başlar.</summary>
    [Fact]
    public void CardWithPortrait()
    {
        List<TextLine> lines =
        [
            new("ISLAND DREAMS", new TextBox(0.187, 0.193, 0.350, 0.244)),
            new("Keep an eye on the bachelor party", new TextBox(0.147, 0.276, 0.429, 0.310)),
            new("while searching Kenton's dive spot for", new TextBox(0.146, 0.326, 0.462, 0.363)),
            new("treasure.", new TextBox(0.145, 0.382, 0.222, 0.409)),
        ];
        var card = Assert.Single(MissionCard.Find(lines));
        var groups = MissionCard.Groups(card, lines);
        Assert.Equal(["ISLAND DREAMS"], groups[0].Paragraphs);
        Assert.Equal(["Keep an eye on the bachelor party while searching Kenton's dive spot for treasure."], groups[1].Paragraphs);
        Assert.Equal(2, groups.Count);
    }

    /// <summary>Oyunun hazır alanı (GTA 6 yardım kutusu) otomatik alan gibi bloklu ve özgün stilde çizilir (#856).</summary>
    [Fact]
    public void PresetAreaIsStyled()
    {
        var frame = Frame.Blank(200, 60);
        for (var y = 0; y < 60; y++)
            for (var x = 0; x < 200; x++)
            {
                var p = y * frame.Stride + x * 4;
                var ink = y is >= 15 and < 45 && x is >= 10 and < 110 && x % 6 < 2;
                (frame.Pixels[p], frame.Pixels[p + 1], frame.Pixels[p + 2], frame.Pixels[p + 3]) =
                    ink ? ((byte)240, (byte)240, (byte)240, (byte)255) : ((byte)85, (byte)31, (byte)14, (byte)255);
            }
        var reading = new Reading([new TextLine("ROB VICKI'S BOSS", new TextBox(0.05, 0.25, 0.55, 0.75))]);
        var whole = new CropRegion(0, 1, 0, 1);
        Assert.Null(RegionWatcher.MakeCandidate(reading, whole, frame).Blocks);
        var preset = RegionWatcher.MakeCandidate(reading, whole, frame, styled: true);
        var block = Assert.Single(preset.Blocks!);
        Assert.Equal("#0E1F55", block.Style!.Background);
    }
}
