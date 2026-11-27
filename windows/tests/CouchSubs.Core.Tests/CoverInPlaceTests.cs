// SPDX-License-Identifier: AGPL-3.0-only
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Sinan Bey: #1300/#1320'den beri menü, görev kartı ve istem Türkçesi yanına ya da ikiz kutuya yazılıyordu; yer her okumada
/// boş alana göre yeniden seçildiği için ekranda kararlı durmuyordu. Varsayılan yine yerinde örtme: Türkçe özgün yazının
/// kendi dikdörtgenine, o kutunun ölçülen zemin renginde çizilir; simge ve kişi resmi örtülmez. Yanına yazma yalnız
/// "Menülerde Türkçeyi yanına yaz" açıkken (RegionWatcher.WritesBeside). Gerçek GTA 6 menü/görev kartı kareleri
/// (testdata/frames, kayıtlı okumalar ocr/screen). Mac/iPhone (CoverInPlaceTests.swift) ve Android (CoverInPlaceTest.kt) aynı.
/// </summary>
public class CoverInPlaceTests
{
    private static string Directory([CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "frames"));

    private static TextBox Box(JsonElement element)
    {
        var b = element.EnumerateArray().Select(v => v.GetDouble()).ToArray();
        return new TextBox(b[0], b[1], b[2], b[3]);
    }

    private sealed record Shot(string Id, Frame Image, List<TextBox> Clear, List<(CropRegion Region, Reading Reading, bool Menu)> Areas);

    private static List<Shot> Shots()
    {
        var directory = Directory();
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "frames.json")));
        var shots = new List<Shot>();
        foreach (var frame in manifest.RootElement.GetProperty("frames").EnumerateArray())
        {
            if (!frame.TryGetProperty("screen", out var screen)) continue;
            var id = frame.GetProperty("id").GetString()!;
            using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "ocr", "screen", id + ".json")));
            var clear = screen.TryGetProperty("clear", out var zones) ? zones.EnumerateArray().Select(Box).ToList() : [];
            var areas = new List<(CropRegion, Reading, bool)>();
            foreach (var area in fixture.RootElement.GetProperty("areas").EnumerateArray())
            {
                var lines = area.GetProperty("lines").EnumerateArray().Select(line => new TextLine(line.GetProperty("text").GetString()!,
                    line.TryGetProperty("box", out var box) ? Box(box) : null,
                    line.TryGetProperty("confidence", out var confidence) ? confidence.GetDouble() : null,
                    line.TryGetProperty("words", out var words)
                        ? [.. words.EnumerateArray().Select(word => new TextWord(word.GetProperty("text").GetString()!, Box(word.GetProperty("box"))))]
                        : null)).ToList();
                if (lines.Count == 0) continue;
                var r = area.GetProperty("region").EnumerateArray().Select(v => v.GetDouble()).ToArray();
                areas.Add((new CropRegion(r[1], r[3], r[0], r[2]), new Reading(lines),
                           area.TryGetProperty("menu", out var menu) && menu.GetBoolean()));
            }
            shots.Add(new Shot(id, Jpeg.Load(Path.Combine(directory, frame.GetProperty("file").GetString()!)), clear, areas));
        }
        return shots;
    }

    private static List<RegionWatcher.Block> Blocks(Shot shot, bool beside) =>
        [.. shot.Areas.SelectMany(area => RegionWatcher.MakeCandidate(area.Reading, area.Region, RegionCropper.Crop(shot.Image, area.Region),
            auto: true, menu: area.Menu, styled: true, kind: area.Menu ? ScreenTextKind.Menu : null, screen: shot.Image,
            beside: beside).Blocks ?? [])];

    private static bool Intersects(TextBox a, TextBox b) =>
        Math.Min(a.Right, b.Right) > Math.Max(a.Left, b.Left) + 1.0 / 1920 && Math.Min(a.Bottom, b.Bottom) > Math.Max(a.Top, b.Top) + 1.0 / 1080;

    [Fact]
    public void MenusCardsAndPromptsAreCoveredInPlaceByDefault()
    {
        var shots = Shots();
        Assert.Equal(3, shots.Count);
        foreach (var shot in shots)
        {
            var first = Blocks(shot, false);
            var second = Blocks(shot, false);
            Assert.Equal(first.Select(block => block.Paint), second.Select(block => block.Paint));
            var painted = 0;
            foreach (var block in first)
            {
                if (block.Paint is not { } paint) continue;
                painted++;
                Assert.Equal(PaintMode.Cover, paint.Mode);
                Assert.Null(paint.Twin);
                Assert.Null(paint.Spot);
                Assert.StartsWith("#", paint.Background);
                var line = Math.Max(1e-6, block.LineHeight);
                Assert.True(Math.Abs(paint.Cover.Top - block.Box.Top) / line <= 0.5, shot.Id);
                Assert.True(Math.Abs(paint.Cover.Bottom - block.Box.Bottom) / line <= 0.5, shot.Id);
                foreach (var zone in shot.Clear) Assert.False(Intersects(paint.Cover, zone), $"{shot.Id}: {zone}");
            }
            Assert.True(painted > 3, shot.Id);
        }
    }

    [Fact]
    public void BesideStaysAvailableAsAnOption() =>
        Assert.Contains(Shots().SelectMany(shot => Blocks(shot, true)), block => block.Paint is { } paint && paint.Mode != PaintMode.Cover);

    [Fact]
    public void OnlyUiKindsAreCoveredScenesKeepTheirKind()
    {
        Assert.Null(RegionWatcher.InPlaceKind(ScreenTextKind.Menu, false));
        Assert.Null(RegionWatcher.InPlaceKind(ScreenTextKind.Mission, false));
        Assert.Null(RegionWatcher.InPlaceKind(ScreenTextKind.Help, false));
        Assert.Equal(ScreenTextKind.Other, RegionWatcher.InPlaceKind(ScreenTextKind.Other, false));
        Assert.Equal(ScreenTextKind.Menu, RegionWatcher.InPlaceKind(ScreenTextKind.Menu, true));
        var twin = new TextPaint("#203040", 0.03, new TextBox(0.1, 0.1, 0.3, 0.13))
        {
            Mode = PaintMode.Twin, Twin = new TextBox(0.4, 0.1, 0.6, 0.2), Spot = new TextBox(0.41, 0.11, 0.59, 0.14),
        };
        var covered = RegionWatcher.CoveredInPlace(twin);
        Assert.Equal(PaintMode.Cover, covered.Mode);
        Assert.Equal(twin.Cover, covered.Cover);
        Assert.Equal("#203040", covered.Background);
        Assert.Null(covered.Twin);
        Assert.Null(covered.Spot);
    }
}
