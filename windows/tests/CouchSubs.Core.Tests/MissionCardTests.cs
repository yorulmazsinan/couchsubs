// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Harita görev/konum kartı: kartın tanınması, parçalarının ayrı çevrilmesi ve otomatik ekran yazısında türü. Kurallar
/// ortak deneme dosyasından (core/Tests/CouchSubsCoreTests/Fixtures/mission-card.json; Mac MissionCardTests.swift ve
/// Android MissionCardTest.kt aynı dosyayı okur).
/// </summary>
public class MissionCardTests
{
    /// <param name="Place">Konum kartı (#1391): başlık yer adı, çevrilmez (grubu yok).</param>
    private sealed record Expected(string Title, string[] Subtitles, string[] Body, string[] Details, bool HelpCorner, bool Place);
    private sealed record Case(string Name, List<TextLine> Lines, List<Expected> Cards);

    private static List<Case> Vectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("mission-card.json")));
        static string[] Strings(JsonElement element) => [.. element.EnumerateArray().Select(item => item.GetString()!)];
        return [.. fixture.RootElement.GetProperty("cases").EnumerateArray().Select(vector => new Case(
            vector.GetProperty("name").GetString()!,
            [.. vector.GetProperty("lines").EnumerateArray().Select(line =>
            {
                var b = line.GetProperty("box").EnumerateArray().Select(v => v.GetDouble()).ToArray();
                return new TextLine(line.GetProperty("text").GetString()!, new TextBox(b[0], b[1], b[2], b[3]));
            })],
            [.. vector.GetProperty("cards").EnumerateArray().Select(card => new Expected(
                card.GetProperty("title").GetString()!, Strings(card.GetProperty("subtitles")), Strings(card.GetProperty("body")),
                Strings(card.GetProperty("details")), card.GetProperty("helpCorner").GetBoolean(),
                card.TryGetProperty("place", out var place) && place.GetBoolean()))]))];
    }

    [Fact]
    public void SharedVectors()
    {
        foreach (var vector in Vectors())
        {
            var lines = vector.Lines;
            var cards = MissionCard.Find(lines);
            Assert.True(cards.Count == vector.Cards.Count, vector.Name);
            foreach (var (card, expected) in cards.Zip(vector.Cards))
            {
                var groups = MissionCard.Groups(card, lines);
                Assert.True(card.Place == expected.Place, vector.Name);
                Assert.Equal(expected.Title, string.Join(' ', card.Title.Select(i => lines[i].Text)));
                var head = expected.Place ? 0 : 1;
                if (!expected.Place) Assert.Equal([expected.Title], groups[0].Paragraphs);
                Assert.Equal(expected.Subtitles, groups.Skip(head).Take(expected.Subtitles.Length).SelectMany(g => g.Paragraphs));
                Assert.Equal(expected.Body, groups[head + expected.Subtitles.Length].Paragraphs);
                Assert.Equal(expected.Details, groups.TakeLast(expected.Details.Length).SelectMany(g => g.Paragraphs));
                Assert.Equal(head + 1 + expected.Subtitles.Length + expected.Details.Length, groups.Count);
                var box = card.All.Select(i => lines[i].Box!.Value).Aggregate((a, b) => a.Union(b));
                Assert.True(MissionCard.InHelpCorner(box) == expected.HelpCorner, vector.Name);
            }
        }
    }

    /// <summary>"Ekranı çevir": başlık açıklamanın ilk cümlesine katılmaz; haritanın başka yazıları ayrı kalır.</summary>
    [Fact]
    public void WholeScreenSplitsTheCardIntoItsParts()
    {
        var vectors = Vectors();
        var groups = ScreenTranslation.ScreenGroups(new Reading(vectors[0].Lines));
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(["THE MARINA JOB"]));
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(["Brian wants the boat moved before the harbor patrol makes its rounds.",
                                                                 "Bring Lucia along for backup."]));
        Assert.Contains(groups, g => g.Paragraphs.SequenceEqual(["VICE CITY"]));
        // Kartın uzun başlığı eskiden ilk cümleye katılıyordu.
        Assert.Equal(["ESCAPE FROM THE PORT OF LEONIDA"], ScreenTranslation.ScreenGroups(new Reading(vectors[1].Lines))[0].Paragraphs);
    }

    /// <summary>Otomatik ekran yazısında kartın bulunduğu alan "Görev ve hedef yazısı"dır; yardım köşesindeki başlıklı kutu değil.</summary>
    [Fact]
    public void AutoAreaWithACardIsAMission()
    {
        var vectors = Vectors();
        var region = new CropRegion(0.35, 0.65, 0.55, 0.95);
        var place = new TextBox(region.Left, region.Top, region.Right, region.Bottom);
        static Reading Local(IEnumerable<TextLine> lines, TextBox place) => new(lines.Select(line =>
        {
            var b = line.Box!.Value;
            double w = place.Right - place.Left, h = place.Bottom - place.Top;
            return line with { Box = new TextBox((b.Left - place.Left) / w, (b.Top - place.Top) / h, (b.Right - place.Left) / w, (b.Bottom - place.Top) / h) };
        }));
        var area = new WatchedArea("auto-1", ScreenTextDetector.AreaName, region) { Auto = true };
        var card = RegionWatcher.MakeCandidate(Local(vectors[0].Lines, place), region, auto: true);
        Assert.True(card.MissionCard);
        Assert.Equal(ScreenTextKind.Mission, RegionWatcher.Kind(area, card));
        Assert.Contains(card.Blocks!, block => card.Paragraphs.Skip(block.Start).Take(block.Count).SequenceEqual(["THE MARINA JOB"]));
        var corner = new CropRegion(0.0, 0.3, 0.0, 0.4);
        var help = RegionWatcher.MakeCandidate(Local(vectors[3].Lines, new TextBox(0, 0, 0.4, 0.3)), corner, auto: true);
        Assert.False(help.MissionCard);
        Assert.Equal(ScreenTextKind.Help, RegionWatcher.Kind(new WatchedArea("auto-2", ScreenTextDetector.AreaName, corner) { Auto = true }, help));
    }

    /// <summary>Menüler kapalıyken kart boyundaki menü alanı "Görev ve hedef yazısı" açıksa okunur; ekranı kaplayan menü okunmaz.</summary>
    [Fact]
    public void MenuAreaIsReadForMapCardsOnlyWhenMissionsAreOn()
    {
        var small = new WatchedArea("auto-1", ScreenTextDetector.AreaName, new CropRegion(0.3, 0.6, 0.55, 0.9)) { Auto = true, Menu = true };
        var wide = small with { Region = new CropRegion(0.1, 0.9, 0.05, 0.95) };
        bool MissionsOn(ScreenTextKind kind) => kind != ScreenTextKind.Menu;
        bool MissionsOff(ScreenTextKind kind) => kind is not (ScreenTextKind.Menu or ScreenTextKind.Mission);
        Assert.True(ScreenTextKinds.Reads(small, MissionsOn));
        Assert.False(ScreenTextKinds.Reads(wide, MissionsOn));
        Assert.False(ScreenTextKinds.Reads(small, MissionsOff));
        Assert.True(ScreenTextKinds.Reads(wide, _ => true));
    }

    /// <summary>Haritadaki uzaklık ("124 ft") göstergedir, çevrilmez (X: chiaki); içinde sözcük olan ayrıntı satırı yazıdır.</summary>
    [Theory]
    [InlineData("124 ft", false)]
    [InlineData("4 ft", false)]
    [InlineData("2.4 mi", false)]
    [InlineData("1,2 km", false)]
    [InlineData("50 yd", false)]
    [InlineData("Distance 2.4 mi", true)]
    [InlineData("Go home", true)]
    public void DistanceIsNotWords(string text, bool words) => Assert.Equal(words, ScreenTranslation.IsWords(text));
}
