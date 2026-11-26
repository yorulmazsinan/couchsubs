// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Menüde seçim/liste kaydında satır farkı (#1359, #1362) ve tuş çubuğunun dar yazısı (#1360). Ortak vakalar
/// core/Tests/CouchSubsCoreTests/Fixtures/menu-rows.json (Mac MenuRowsTests.swift ve Android MenuRowsTest.kt aynı dosyayı okur).
/// </summary>
public class MenuRowsTests
{
    private static JsonDocument Fixture() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("menu-rows.json")));

    private static TextBox Box(JsonElement b) =>
        new(b[0].GetDouble(), b[1].GetDouble(), b[2].GetDouble(), b[3].GetDouble());

    [Fact]
    public void SharedCarriedRows()
    {
        using var fixture = Fixture();
        var cases = fixture.RootElement.GetProperty("carriedRows").EnumerateArray().ToList();
        Assert.True(cases.Count >= 4);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var rendered = item.GetProperty("rendered").EnumerateArray()
                .Select(row => new ScreenTranslation.Item(row.GetProperty("text").GetString()!, "çeviri", Box(row.GetProperty("box")), 0.03))
                .ToList();
            var current = item.GetProperty("current").EnumerateArray()
                .Select(row => (Box(row.GetProperty("box")), row.GetProperty("text").GetString()!))
                .ToList();
            var diff = RegionWatcher.CarriedRows(rendered, current, item.GetProperty("listMoved").GetBoolean());
            var kept = item.GetProperty("kept").EnumerateArray()
                .Select(pair => (pair[0].GetInt32(), pair[1].ValueKind == JsonValueKind.Null ? (int?)null : pair[1].GetInt32()))
                .ToList();
            var fresh = item.GetProperty("fresh").EnumerateArray().Select(value => value.GetInt32()).ToList();
            Assert.True(kept.SequenceEqual(diff.Kept), $"{id}: kept [{string.Join(", ", diff.Kept)}]");
            Assert.True(fresh.SequenceEqual(diff.Fresh), $"{id}: fresh [{string.Join(", ", diff.Fresh)}]");
        }
    }

    [Fact]
    public void SharedCondensedMeasure()
    {
        using var fixture = Fixture();
        foreach (var item in fixture.RootElement.GetProperty("characters").EnumerateArray())
        {
            var text = item.GetProperty("text").GetString()!;
            Assert.True(item.GetProperty("characters").GetInt32() == TextStyleSampler.Characters(text), text);
        }
        foreach (var item in fixture.RootElement.GetProperty("condensed").EnumerateArray())
        {
            var got = TextStyleSampler.IsCondensed(item.GetProperty("width").GetDouble(), item.GetProperty("height").GetDouble(),
                                                   item.GetProperty("characters").GetInt32());
            Assert.True(item.GetProperty("condensed").GetBoolean() == got, item.ToString());
        }
    }

    /// <summary>Aynı gruptaki etiketlerden biri dar yazıysa hepsi dar (#1360); grupsuz etiket değişmez.</summary>
    [Fact]
    public void GroupSharesCondensedLook()
    {
        static RegionWatcher.Block Block(int? group, bool condensed)
        {
            var paint = new TextPaint("#000000", 0.03, new TextBox(0, 0, 0.1, 0.03)) { Group = group };
            return new RegionWatcher.Block(0, 1, paint.Cover, 0.03, null, new TextLook(true, condensed, "left", true, true)) { Paint = paint };
        }
        var blocks = RegionWatcher.CondensedTogether([Block(0, true), Block(0, false), Block(0, false), Block(null, false)]);
        Assert.Equal([true, true, true, false], blocks.Select(block => block.Look!.Condensed));
    }
}
