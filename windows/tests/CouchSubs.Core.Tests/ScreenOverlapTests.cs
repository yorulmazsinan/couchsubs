// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// #827: aynı yazı aynı yerde tek kez çizilir. Kurallar ortak deneme dosyasından
/// (core/Tests/CouchSubsCoreTests/Fixtures/screen-overlap.json; Mac ScreenOverlapTests.swift ve Android
/// ScreenOverlapTest.kt aynı dosyayı okur).
/// </summary>
public class ScreenOverlapTests
{
    private static JsonElement Vectors() =>
        JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("screen-overlap.json"))).RootElement;

    private static TextBox Box(JsonElement element)
    {
        var v = element.EnumerateArray().Select(x => x.GetDouble()).ToArray();
        return new TextBox(v[0], v[1], v[2], v[3]);
    }

    private static string[] Strings(JsonElement element) => [.. element.EnumerateArray().Select(x => x.GetString()!)];

    [Fact]
    public void SharedVectors()
    {
        var root = Vectors();
        foreach (var vector in root.GetProperty("overlap").EnumerateArray())
        {
            var (a, b) = (Box(vector.GetProperty("a")), Box(vector.GetProperty("b")));
            var share = vector.GetProperty("share").GetDouble();
            Assert.Equal(share, ScreenTranslation.Overlap(a, b), 9);
            Assert.Equal(share, ScreenTranslation.Overlap(b, a), 9);
        }
        foreach (var vector in root.GetProperty("lines").EnumerateArray())
        {
            var lines = vector.GetProperty("lines").EnumerateArray()
                .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(line.GetProperty("box")))).ToList();
            Assert.Equal(Strings(vector.GetProperty("kept")), ScreenTranslation.WithoutDuplicateLines(lines).Select(line => line.Text));
        }
        foreach (var vector in root.GetProperty("layers").EnumerateArray())
        {
            var items = vector.GetProperty("items").EnumerateArray().Select(entry =>
            {
                var source = entry.GetProperty("source").GetString()!;
                var translation = entry.TryGetProperty("translation", out var t) ? t.GetString()! : "Türkçe " + source;
                return new ScreenTranslation.Item(source, translation, Box(entry.GetProperty("box")), 0.03);
            }).ToList();
            Assert.Equal(Strings(vector.GetProperty("kept")), ScreenTranslation.Layered(items).Select(item => item.Source));
        }
    }

    /// <summary>Menüdeki simge (dükkân, kamera, ayar) çeviri kutusunun dışında kalır: kutu yalnız yazıyı kapsar.</summary>
    [Fact]
    public void EdgeMarksStayOutsideTheBox()
    {
        foreach (var vector in Vectors().GetProperty("edges").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString()!;
            List<TextWord>? words = vector.TryGetProperty("words", out var w)
                ? [.. w.EnumerateArray().Select(word => new TextWord(word.GetProperty("text").GetString()!, Box(word.GetProperty("box"))))]
                : null;
            var line = new TextLine(vector.GetProperty("text").GetString()!, Box(vector.GetProperty("box")), Words: words);
            var trimmed = ScreenTranslation.WithoutEdgeMarks(line);
            var expect = vector.GetProperty("expect");
            Assert.True(expect.GetProperty("text").GetString() == trimmed.Text, name + ": " + trimmed.Text);
            var (got, want) = (trimmed.Box!.Value, Box(expect.GetProperty("box")));
            Assert.True(Math.Abs(got.Left - want.Left) < 1e-9 && Math.Abs(got.Right - want.Right) < 1e-9
                        && Math.Abs(got.Top - want.Top) < 1e-9 && Math.Abs(got.Bottom - want.Bottom) < 1e-9, name + ": " + got);
        }
        var icon = new TextLine(ButtonIcons.Marker + " Back", new TextBox(0.1, 0.1, 0.2, 0.13),
                                Icons: [new IconSlot(new TextBox(0.1, 0.1, 0.12, 0.13), "O")]);
        Assert.Same(icon, ScreenTranslation.WithoutEdgeMarks(icon));
    }

    /// <summary>"Ekranı çevir": görev listesinin seçili satırı bir de parça olarak okununca ayrı grup (ve altında ikinci kutu) olmaz.</summary>
    [Fact]
    public void WholeScreenDoesNotTranslateTheSameLineTwice()
    {
        var vector = Vectors().GetProperty("lines")[0];
        var reading = new Reading(vector.GetProperty("lines").EnumerateArray()
            .Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(line.GetProperty("box")))));
        var paragraphs = ScreenTranslation.ScreenGroups(reading).SelectMany(group => group.Paragraphs).ToList();
        Assert.DoesNotContain("Find", paragraphs);
        Assert.Contains(paragraphs, paragraph => paragraph.Contains("Find Donnie's Package"));
    }

    /// <summary>Aynı okumanın çevirilerinden aynı yeri çizenlerin yalnız biri gösterilir.</summary>
    [Fact]
    public void PresentDropsDuplicateItems()
    {
        var whole = new ScreenTranslation.Item("Find Donnie's Package", "Donnie'nin Paketini Bul", new TextBox(0.074, 0.245, 0.25, 0.272), 0.027);
        var piece = new ScreenTranslation.Item("Find", "Bulur", new TextBox(0.15, 0.255, 0.19, 0.285), 0.03);
        Assert.Equal(["Find Donnie's Package"], ScreenTranslation.Present([piece, whole], null).Select(item => item.Source));
    }

    /// <summary>"Ekranı çevir" ekrandayken onun yerindeki otomatik ekran yazısı blokları pencerede gösterilmez.</summary>
    [Fact]
    public void ScreenHidesRegionBlocksInItsPlace()
    {
        var screen = new ScreenTranslation.Item("Make Money", "Para Kazan", new TextBox(0.075, 0.185, 0.17, 0.21), 0.025);
        var same = new ScreenTranslation.Item("Make Money", "Para Kazanın", new TextBox(0.07, 0.18, 0.17, 0.212), 0.025);
        var elsewhere = new ScreenTranslation.Item("Shoeless Keys", "Shoeless Keys adası", new TextBox(0.44, 0.14, 0.53, 0.16), 0.02);
        var regions = new Dictionary<string, (string Text, TextBox? Box, IReadOnlyList<ScreenTranslation.Item>? Blocks)>
        {
            [ScreenRegions.Id] = ("Para Kazan", screen.Box, [screen]),
            ["auto-1"] = ("Para Kazanın\nShoeless Keys adası", null, [same, elsewhere]),
            ["auto-2"] = ("Para Kazanın", null, [same]),
            ["manual"] = ("Görev", new TextBox(0, 0, 1, 1), null),
        };
        var visible = ScreenRegions.Visible(regions).ToDictionary(pair => pair.Key, pair => pair.Value);
        Assert.Equal(["Shoeless Keys"], visible["auto-1"].Blocks!.Select(item => item.Source));
        Assert.False(visible.ContainsKey("auto-2"));
        Assert.True(visible.ContainsKey("manual"));
        Assert.True(visible.ContainsKey(ScreenRegions.Id));
    }
}
