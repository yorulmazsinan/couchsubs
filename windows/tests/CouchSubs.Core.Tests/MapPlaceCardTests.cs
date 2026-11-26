// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// #1391: haritanın konum kartı (dükkân, garaj açıklaması) tek paragraf olarak çevrilir, başlığı (yer adı) çevrilmez,
/// mesaj alanına taşan kart iki alana bölünmez, mesaj alanının kenarındaki kesik parça tek başına çevrilmez. Ortak deneme
/// dosyası core/Tests/CouchSubsCoreTests/Fixtures/map-place-card.json (Mac MapPlaceCardTests.swift, Android
/// MapPlaceCardTest.kt aynı dosyayı okur).
/// </summary>
public class MapPlaceCardTests
{
    private static JsonElement Root()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("map-place-card.json")));
        return fixture.RootElement.Clone();
    }

    private static string[] Strings(JsonElement element) => [.. element.EnumerateArray().Select(item => item.GetString()!)];

    private static double[] Box(JsonElement element) => [.. element.GetProperty("box").EnumerateArray().Select(v => v.GetDouble())];

    private static TextLine Line(JsonElement element)
    {
        var b = Box(element);
        return new TextLine(element.GetProperty("text").GetString()!, new TextBox(b[0], b[1], b[2], b[3]));
    }

    [Fact]
    public void CardGroups()
    {
        foreach (var vector in Root().GetProperty("cards").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString()!;
            List<TextLine> lines = [.. vector.GetProperty("lines").EnumerateArray().Select(Line)];
            var place = vector.GetProperty("place").GetBoolean();
            var subtitles = Strings(vector.GetProperty("subtitles"));
            var body = Strings(vector.GetProperty("body"));
            var details = Strings(vector.GetProperty("details"));
            var cards = MissionCard.Find(lines);
            Assert.True(cards.Count == 1, name);
            var card = cards[0];
            Assert.True(card.Place == place, name);
            var groups = MissionCard.Groups(card, lines);
            var head = place ? 0 : 1;
            if (!place) Assert.Equal([lines[card.Title[0]].Text], groups[0].Paragraphs);
            Assert.Equal(subtitles, groups.Skip(head).Take(subtitles.Length).SelectMany(g => g.Paragraphs));
            Assert.Equal(body, groups[head + subtitles.Length].Paragraphs);
            Assert.Equal(head + 1 + subtitles.Length + details.Length, groups.Count);
            // Açıklamanın bloğu sarılmış satırların hepsini kapsar (örtü İngilizcenin tamamına).
            var whole = card.Body.Select(i => lines[i].Box!.Value).Aggregate((a, b) => a.Union(b));
            Assert.Equal(whole, groups[head + subtitles.Length].Box);
        }
    }

    [Fact]
    public void PlaceTitles()
    {
        foreach (var title in Root().GetProperty("titles").EnumerateArray())
        {
            var text = title.GetProperty("text").GetString()!;
            Assert.True(MissionCard.IsPlaceTitle(text) == title.GetProperty("place").GetBoolean(), text);
        }
    }

    [Fact]
    public void PresetsYieldToACrossingCard()
    {
        foreach (var vector in Root().GetProperty("areas").EnumerateArray())
        {
            var r = vector.GetProperty("region").EnumerateArray().Select(v => v.GetDouble()).ToArray();
            var auto = new WatchedArea("auto-1", ScreenTextDetector.AreaName, new CropRegion(r[1], r[3], r[0], r[2]))
            {
                Auto = true,
                Menu = vector.GetProperty("menu").GetBoolean(),
            };
            Assert.Equal(Strings(vector.GetProperty("kept")),
                RegionWatcher.YieldingPresets([.. GameAreaPresets.Areas("GTA 6"), auto]).Select(a => a.Id));
        }
    }

    [Fact]
    public void FragmentsAtTheMessagesEdge()
    {
        var region = GameAreaPresets.Areas("GTA 6").First(a => a.Id == GameAreaPresets.PhoneId).Region;
        var fragments = Root().GetProperty("fragments").EnumerateArray().ToList();
        foreach (var fragment in fragments)
            Assert.True(RegionWatcher.CutAtAreaLeftEdge(Line(fragment), region) == fragment.GetProperty("cut").GetBoolean(),
                fragment.GetProperty("text").GetString());
        // Hazır mesaj alanının okumasında kesik parçalar çeviriye girmez.
        var candidate = RegionWatcher.MakeCandidate(new Reading([.. fragments.Select(Line)]), region, styled: true,
                                                    kind: ScreenTextKind.Phone);
        var joined = string.Join(' ', candidate.Paragraphs);
        Assert.Contains("Just saw Moses", joined);
        foreach (var fragment in fragments.Where(f => f.GetProperty("cut").GetBoolean()))
            Assert.DoesNotContain(fragment.GetProperty("text").GetString()!, joined);
    }

    /// <summary>Otomatik alanda konum kartı: başlık çevrilmez, açıklama tek parça ve tek blok.</summary>
    [Fact]
    public void AutoAreaTranslatesTheCardAsOneParagraph()
    {
        var vector = Root().GetProperty("cards")[0];
        var region = new CropRegion(0.36, 0.66, 0.37, 0.78);
        var w = region.Right - region.Left;
        var h = region.Bottom - region.Top;
        List<TextLine> lines = [.. vector.GetProperty("lines").EnumerateArray().Select(Line)
            .Where(line => line.Box!.Value.Left >= region.Left)
            .Select(line =>
            {
                var b = line.Box!.Value;
                return new TextLine(line.Text, new TextBox((b.Left - region.Left) / w, (b.Top - region.Top) / h,
                                                           (b.Right - region.Left) / w, (b.Bottom - region.Top) / h));
            })];
        var candidate = RegionWatcher.MakeCandidate(new Reading(lines), region, auto: true);
        Assert.True(candidate.MissionCard);
        Assert.Equal([.. Strings(vector.GetProperty("subtitles")), .. Strings(vector.GetProperty("body"))], candidate.Paragraphs);
        Assert.Equal(2, candidate.Blocks?.Count);
    }
}
