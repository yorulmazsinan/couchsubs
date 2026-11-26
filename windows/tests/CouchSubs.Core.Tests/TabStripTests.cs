// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Menü sekme şeridi (#1372): aynı şerit her karede başka biçimde ve sırada okunsa da sekmeler ayrı etiket, soldan sağa
/// aynı sırada, aday anahtarı aynı; seçim kayınca bütün sekmelerin çevirisi yerinde kalır. Ortak vakalar
/// core/Tests/CouchSubsCoreTests/Fixtures/tab-strip.json (Mac TabStripTests.swift ve Android TabStripTest.kt aynı dosyayı okur).
/// </summary>
public class TabStripTests
{
    private static JsonDocument Fixture() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("tab-strip.json")));

    private static TextBox Box(JsonElement b) =>
        new(b[0].GetDouble(), b[1].GetDouble(), b[2].GetDouble(), b[3].GetDouble());

    private static TextLine Line(JsonElement l)
    {
        var words = l.TryGetProperty("words", out var w)
            ? w.EnumerateArray().Select(word => new TextWord(word.GetProperty("text").GetString()!, Box(word.GetProperty("box")))).ToList()
            : null;
        var icons = l.TryGetProperty("icons", out var i)
            ? i.EnumerateArray().Select(icon => new IconSlot(Box(icon), "")).ToList()
            : null;
        return new TextLine(l.GetProperty("text").GetString()!, Box(l.GetProperty("box")), null, words, icons);
    }

    [Fact]
    public void TabsKeepTheirOrderEveryFrame()
    {
        using var fixture = Fixture();
        var expected = fixture.RootElement.GetProperty("expected").EnumerateArray().Select(e => e.GetString()!).ToList();
        var frames = fixture.RootElement.GetProperty("frames").EnumerateArray().ToList();
        Assert.True(frames.Count >= 3);
        var keys = new HashSet<string>();
        foreach (var frame in frames)
        {
            var name = frame.GetProperty("name").GetString()!;
            var reading = new Reading(frame.GetProperty("lines").EnumerateArray().Select(Line));
            var candidate = RegionWatcher.MakeCandidate(reading, new CropRegion(0, 1, 0, 1), auto: true, menu: true);
            Assert.True(expected.SequenceEqual(candidate.Paragraphs), $"{name}: [{string.Join(" | ", candidate.Paragraphs)}]");
            var blocks = candidate.Blocks ?? [];
            Assert.True(blocks.Count == expected.Count, $"{name}: {blocks.Count} blok");
            // Her sekme kendi yerinde, soldan sağa.
            var tabs = blocks.Take(4).Select(block => block.Box.Left).ToList();
            Assert.True(tabs.SequenceEqual(tabs.OrderBy(left => left)), name);
            keys.Add(candidate.Key);
        }
        Assert.True(keys.Count == 1, "aday anahtarı her karede aynı olmalı");
    }

    [Fact]
    public void SelectionKeepsEveryTab()
    {
        using var fixture = Fixture();
        var item = fixture.RootElement.GetProperty("carried");
        var id = item.GetProperty("id").GetString()!;
        var rendered = item.GetProperty("rendered").EnumerateArray()
            .Select(row => new ScreenTranslation.Item(row.GetProperty("text").GetString()!, "çeviri", Box(row.GetProperty("box")), 0.042))
            .ToList();
        var current = item.GetProperty("current").EnumerateArray()
            .Select(row => (Box(row.GetProperty("box")), row.GetProperty("text").GetString()!))
            .ToList();
        var diff = RegionWatcher.CarriedRows(rendered, current, item.GetProperty("listMoved").GetBoolean());
        var kept = item.GetProperty("kept").EnumerateArray().Select(pair => (pair[0].GetInt32(), (int?)pair[1].GetInt32())).ToList();
        var fresh = item.GetProperty("fresh").EnumerateArray().Select(value => value.GetInt32()).ToList();
        Assert.True(kept.SequenceEqual(diff.Kept), $"{id}: kept [{string.Join(", ", diff.Kept)}]");
        Assert.True(fresh.SequenceEqual(diff.Fresh), $"{id}: fresh [{string.Join(", ", diff.Fresh)}]");
    }

    /// <summary>Sekme etiketleri arayüz sözlüğünden; karakter adları olduğu gibi.</summary>
    [Fact]
    public void TabLabels()
    {
        Assert.Equal("HARİTA", UiCommands.TranslateLabelLoosely("MAP"));
        Assert.Equal("GALERİ", UiCommands.TranslateLabelLoosely("GALLERY"));
        Assert.Equal("JASON LUCIA HARİTA ÖZET", UiCommands.TranslateLabelLoosely("JASON LUCIA MAP BRIEF"));
        Assert.True(ScreenTranslation.KeepsNames("JASON LUCIA"));
        Assert.False(ScreenTranslation.KeepsNames("MAP BRIEF"));
    }
}
