// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Harita düzeni (#1365): GTA 6 Harita › STORY ekranı (koyu panelde görev listesi, görev kartı, haritanın üstünde tuş
/// çubuğu) menü sayılır; liste tek alanda okunur, hazır alanlar yer verir; kamera oynayan ya da karanlık oyun sahnesi menü
/// sayılmaz. Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/map-layout.json (Mac MapLayoutTests.swift,
/// Android MapLayoutTest.kt aynı).
/// </summary>
public class MapLayoutTests
{
    private sealed record Text(string Role, int Column, int Row, int Width, string Kind);
    private sealed record Box(int[] Cells, int Fill);
    private sealed record Panel(string Side, int Columns, int Fill);

    private sealed record Scene(string Name, int Map, bool Texture, bool Moving, bool Mirror, Panel? Panel, List<Box> Boxes,
                                List<Text> Texts, int UntilMs, JsonElement Expect);

    private const int Width = 640, Height = 360, Tile = 20;

    private static List<Scene> Load()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("map-layout.json")));
        var scenes = new List<Scene>();
        foreach (var s in document.RootElement.GetProperty("scenes").EnumerateArray())
        {
            Panel? panel = s.GetProperty("panel").ValueKind == JsonValueKind.Null ? null
                : new Panel(s.GetProperty("panel").GetProperty("side").GetString()!, s.GetProperty("panel").GetProperty("columns").GetInt32(),
                            s.GetProperty("panel").GetProperty("fill").GetInt32());
            scenes.Add(new Scene(
                s.GetProperty("name").GetString()!, s.GetProperty("map").GetInt32(), s.GetProperty("texture").GetBoolean(),
                s.GetProperty("moving").GetBoolean(), s.TryGetProperty("mirror", out var mirror) && mirror.GetBoolean(), panel,
                [.. s.GetProperty("boxes").EnumerateArray().Select(b => new Box(
                    [.. b.GetProperty("cells").EnumerateArray().Select(c => c.GetInt32())], b.GetProperty("fill").GetInt32()))],
                [.. s.GetProperty("texts").EnumerateArray().Select(t => new Text(
                    t.GetProperty("role").GetString()!, t.GetProperty("column").GetInt32(), t.GetProperty("row").GetInt32(),
                    t.GetProperty("width").GetInt32(), t.GetProperty("kind").GetString()!))],
                s.GetProperty("untilMs").GetInt32(), s.GetProperty("expect").Clone()));
        }
        return scenes;
    }

    /// <summary>Aynalanmış sahne (sütunlar öbür yana).</summary>
    private static Scene Mirrored(Scene scene)
    {
        if (!scene.Mirror) return scene;
        return scene with
        {
            Texts = [.. scene.Texts.Select(t => t with { Column = 32 - t.Column - t.Width })],
            Boxes = [.. scene.Boxes.Select(b => b with { Cells = [31 - b.Cells[2], b.Cells[1], 31 - b.Cells[0], b.Cells[3]] })],
            Panel = scene.Panel is { } panel ? panel with { Side = panel.Side == "left" ? "right" : "left" } : null,
        };
    }

    /// <summary>Sahnenin <paramref name="phase"/> anındaki karesi (gri tonlu).</summary>
    private static Frame Pixels(Scene scene, int phase)
    {
        var gray = new byte[Width * Height];
        Array.Fill(gray, (byte)scene.Map);
        void Set(int x, int y, int v) => gray[y * Width + x] = (byte)v;
        var panelColumns = scene.Panel is { } p
            ? (p.Side == "left" ? Enumerable.Range(0, p.Columns) : Enumerable.Range(32 - p.Columns, p.Columns)).ToHashSet()
            : [];
        for (var row = 0; row < 18; row++)
            for (var column = 0; column < 32; column++)
            {
                int x0 = column * Tile, y0 = row * Tile;
                if (panelColumns.Contains(column))
                {
                    for (var y = y0; y < y0 + Tile; y++) for (var x = x0; x < x0 + Tile; x++) Set(x, y, scene.Panel!.Fill);
                }
                else if (scene.Texture && (column + row) % 3 != 0)
                {
                    var shift = scene.Moving ? phase % 3 : 0;
                    for (var y = y0; y < y0 + Tile; y++) for (var x = x0; x < x0 + Tile; x++) Set(x, y, (y + shift) % 3 == 0 ? 200 : 120);
                }
            }
        foreach (var box in scene.Boxes)
            for (var y = box.Cells[1] * Tile; y < (box.Cells[3] + 1) * Tile; y++)
                for (var x = box.Cells[0] * Tile; x < (box.Cells[2] + 1) * Tile; x++) Set(x, y, box.Fill);
        foreach (var text in scene.Texts)
        {
            var y0 = text.Row * Tile;
            for (var y = y0 + 3; y < y0 + 17; y++)
            {
                var r = (y - y0) % 6;
                for (var x = text.Column * Tile; x < (text.Column + text.Width) * Tile; x++)
                {
                    var stroke = x % 5 < 2;
                    if (text.Kind == "dark") Set(x, y, r is 2 or 3 && stroke ? 240 : 24);
                    else if (r is 2 or 3 && stroke) Set(x, y, 240);
                    else if (r is 1 or 4 && stroke) Set(x, y, 40);
                }
            }
        }
        var frame = Frame.Blank(Width, Height);
        for (var y = 0; y < Height; y++)
            for (var x = 0; x < Width; x++)
            {
                var at = y * frame.Stride + x * 4;
                var v = gray[y * Width + x];
                frame.Pixels[at] = frame.Pixels[at + 1] = frame.Pixels[at + 2] = v;
                frame.Pixels[at + 3] = 255;
            }
        return frame;
    }

    private static (double X, double Y) Center(Text text) =>
        ((text.Column + text.Width / 2.0) / 32, (text.Row + 0.5) / 18);

    private static WatchedArea? Holder(IReadOnlyList<WatchedArea> areas, Text text)
    {
        var c = Center(text);
        return areas.FirstOrDefault(a => c.X >= a.Region.Left && c.X <= a.Region.Right && c.Y >= a.Region.Top && c.Y <= a.Region.Bottom);
    }

    private static List<string> Strings(JsonElement element) => [.. element.EnumerateArray().Select(item => item.GetString()!)];

    [Fact]
    public void MapLayoutScenes()
    {
        foreach (var original in Load())
        {
            var scene = Mirrored(original);
            var detector = new ScreenTextDetector();
            var notes = new List<string>();
            detector.OnLog = notes.Add;
            for (var time = 0; time <= scene.UntilMs; time += ScreenTextDetector.SampleIntervalMs)
                detector.Sample(Pixels(scene, time / 100), time, [new CropRegion()]);
            var expect = scene.Expect;
            var mapLayout = expect.GetProperty("mapLayout").GetBoolean();
            Assert.True(detector.InMenu == expect.GetProperty("menu").GetBoolean(), $"{scene.Name}: menü");
            Assert.True(detector.InMapLayout == mapLayout, $"{scene.Name}: harita düzeni");
            if (mapLayout)
                Assert.True(notes.Any(note => note.StartsWith("ekran menüsü: harita düzeni bulundu", StringComparison.Ordinal)),
                            $"{scene.Name}: {string.Join(" | ", notes)}");
            var areas = detector.Areas;
            if (expect.TryGetProperty("together", out var together))
                foreach (var role in Strings(together))
                {
                    var held = scene.Texts.Where(t => t.Role == role).Select(t => Holder(areas, t)?.Id).ToList();
                    Assert.False(held.Contains(null), $"{scene.Name}: {role} alansız");
                    Assert.True(held.Distinct().Count() == 1, $"{scene.Name}: {role} bölündü");
                }
            if (expect.TryGetProperty("apart", out var apart))
                foreach (var pair in apart.EnumerateArray().Select(Strings))
                {
                    var a = scene.Texts.Where(t => t.Role == pair[0]).Select(t => Holder(areas, t)?.Id).OfType<string>().ToHashSet();
                    var b = scene.Texts.Where(t => t.Role == pair[1]).Select(t => Holder(areas, t)?.Id).OfType<string>().ToHashSet();
                    Assert.False(a.Overlaps(b), $"{scene.Name}: {pair[0]}/{pair[1]} aynı alanda");
                }
            if (expect.TryGetProperty("presetsYield", out var yields) && yields.GetBoolean())
            {
                var kept = RegionWatcher.YieldingPresets([.. GameAreaPresets.Areas("GTA 6"), .. areas]);
                Assert.False(kept.Any(area => area.Id is GameAreaPresets.HelpId or GameAreaPresets.PhoneId), $"{scene.Name}: hazır alan okunuyor");
            }
        }
    }

    /// <summary>Düzen karolara bakar: sentetik karo tonlarıyla (çizimsiz) sol panel bulunur, panelsiz ya da koyu haritada bulunmaz.</summary>
    [Fact]
    public void MapPanelFromTileTones()
    {
        static (bool Left, int Width)? Find(Func<int, int, double> tone, HashSet<int>? text = null, bool steady = true) =>
            ScreenTextDetector.MapPanel(index => text?.Contains(index) == true, index => (tone(index % 32, index / 32), steady));
        var list = Enumerable.Range(1, 6).SelectMany(row => Enumerable.Range(1, 6).Select(column => row * 32 + column)).ToHashSet();
        var found = Find((column, _) => column < 9 ? 45 : 160, list);
        Assert.Equal(true, found?.Left);
        Assert.Equal(9, found?.Width);
        Assert.Null(Find((column, _) => column < 9 ? 45 : 160)); // panelde liste yok
        Assert.Null(Find((column, _) => column < 9 ? 45 : 160, list, steady: false)); // harita oynuyor
        Assert.Null(Find((column, _) => column < 9 ? 45 : 60, list)); // yanı da karanlık
        Assert.Null(Find((column, row) => column < 9 && row < 12 ? 45 : 160, list)); // panel tam boy değil
        var right = Enumerable.Range(1, 6).SelectMany(row => Enumerable.Range(25, 6).Select(column => row * 32 + column)).ToHashSet();
        Assert.Equal(false, Find((column, _) => column >= 23 ? 45 : 160, right)?.Left);
    }
}
