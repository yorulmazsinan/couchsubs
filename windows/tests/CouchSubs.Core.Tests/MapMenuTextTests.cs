// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Harita ekranının görev listesi ve kartı (#1365): arayüz etiketleri ("GOAL" → "Hedef"), görev başlığında özel ad
/// ("Kingpin Bowling'i Soy"), satır başındaki görev simgesi ("KM") ve güveni düşük okuma. Ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/map-menu-text.json (Mac MapMenuTextTests.swift, Android MapMenuTextTest.kt aynı).
/// </summary>
public class MapMenuTextTests
{
    private static JsonElement Vectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("map-menu-text.json")));
        return fixture.RootElement.Clone();
    }

    private static string? Expected(JsonElement item) =>
        item.GetProperty("expected").ValueKind == JsonValueKind.Null ? null : item.GetProperty("expected").GetString();

    [Fact]
    public void LabelsAndMissionTitles()
    {
        var v = Vectors();
        foreach (var item in v.GetProperty("labels").EnumerateArray())
        {
            var text = item.GetProperty("text").GetString()!;
            Assert.True(Expected(item) == UiCommands.TranslateLabel(text), $"{text}: {UiCommands.TranslateLabel(text)}");
        }
        foreach (var item in v.GetProperty("missionTitles").EnumerateArray())
        {
            var text = item.GetProperty("text").GetString()!;
            Assert.True(Expected(item) == UiCommands.MissionTitle(text), $"{text}: {UiCommands.MissionTitle(text)}");
        }
    }

    [Fact]
    public void BadgesAreNotText()
    {
        foreach (var item in Vectors().GetProperty("badges").EnumerateArray())
        {
            var text = item.GetProperty("text").GetString()!;
            var b = item.GetProperty("box").EnumerateArray().Select(value => value.GetDouble()).ToArray();
            var line = ScreenTranslation.WithoutBadge(new TextLine(text, new TextBox(b[0], b[1], b[2], b[3]), 1));
            Assert.True(item.GetProperty("expected").GetString() == line.Text, text);
            Assert.True(Math.Abs((line.Box?.Left ?? -1) - item.GetProperty("left").GetDouble()) <= 1e-3, $"{text}: {line.Box?.Left}");
            Assert.True(Math.Abs((line.Box?.Right ?? -1) - b[2]) <= 1e-9, text);
        }
    }

    [Fact]
    public void UnsureReadsAreHeld()
    {
        foreach (var item in Vectors().GetProperty("unsure").EnumerateArray())
        {
            var text = item.GetProperty("text").GetString()!;
            double? confidence = item.GetProperty("confidence").ValueKind == JsonValueKind.Null ? null : item.GetProperty("confidence").GetDouble();
            Assert.True(item.GetProperty("expected").GetBoolean() == ScreenTextNoise.IsUnsure(new TextLine(text, Confidence: confidence)), text);
        }
    }

    /// <summary>Menüdeki alanda güvensiz satır adaydan çıkar (çeviriye gitmez), simge satırın başından atılır; menü dışında dokunulmaz.</summary>
    [Fact]
    public void MenuCandidateDropsUnsureRowsAndBadges()
    {
        var region = new CropRegion(Top: 0, Bottom: 0.6, Left: 0, Right: 0.4);
        var reading = new Reading([
            new TextLine("KM Collect Chemicals for Kyle", new TextBox(0.1, 0.30, 0.8, 0.36), 1),
            new TextLine("scarch rol the onuin Ape", new TextBox(0.1, 0.40, 0.8, 0.46), 0.5),
            new TextLine("Check out the Mud Club", new TextBox(0.1, 0.50, 0.8, 0.56), 1),
        ]);
        var menu = RegionWatcher.MakeCandidate(reading, region, auto: true, menu: true);
        Assert.Equal(["scarch rol the onuin Ape"], menu.Unsure);
        var joined = string.Join(' ', menu.Paragraphs);
        Assert.DoesNotContain("scarch", joined);
        Assert.DoesNotContain("KM", joined);
        Assert.Contains("Collect Chemicals for Kyle", joined);
        var outside = RegionWatcher.MakeCandidate(reading, region, auto: true, menu: false);
        Assert.Empty(outside.Unsure);
    }
}
