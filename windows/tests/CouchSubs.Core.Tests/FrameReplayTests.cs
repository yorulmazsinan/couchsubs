// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Gerçek kare gerileme seti (testdata/frames, scripts/regression-frames.sh): karelerin Mac'te Apple Vision ile
/// kaydedilmiş okumaları (testdata/frames/ocr) Windows'un altyazı seçiminden geçer: oturum oturum, sırayla; düğme
/// ipuçları ve okuma çöpü atılır, satırlar birleşir, altyazı bloğu seçilir, altyazının yeri öğrenilir (SubtitleBand).
/// Seçilen blok Mac'in seçtiğiyle (ocr/selection.json) aynı olmalı (Mac FrameReplayTests.swift, Android
/// FrameReplayTest.kt aynı dosyaları okur).
/// </summary>
public class FrameReplayTests
{
    private static string Directory([CallerFilePath] string source = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..", "testdata", "frames"));

    private static TextBox Box(JsonElement element)
    {
        var b = element.EnumerateArray().Select(v => v.GetDouble()).ToArray();
        return new TextBox(b[0], b[1], b[2], b[3]);
    }

    private static Reading Lines(JsonElement lines) => new(lines.EnumerateArray().Select(line => new TextLine(
        line.GetProperty("text").GetString()!,
        line.TryGetProperty("box", out var box) ? Box(box) : null,
        line.TryGetProperty("confidence", out var confidence) ? confidence.GetDouble() : null,
        line.TryGetProperty("words", out var words)
            ? [.. words.EnumerateArray().Select(word => new TextWord(word.GetProperty("text").GetString()!, Box(word.GetProperty("box"))))]
            : null)).ToList());

    [Fact]
    public void SelectionMatchesMacOnRealFrames()
    {
        var directory = Directory();
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "frames.json")));
        using var golden = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "ocr", "selection.json")));
        var frames = manifest.RootElement.GetProperty("frames").EnumerateArray().ToList();
        Assert.True(frames.Count >= 40);
        Assert.Equal(frames.Count, golden.RootElement.EnumerateObject().Count());
        var bands = new Dictionary<string, SubtitleBand>();
        foreach (var frame in frames)
        {
            var id = frame.GetProperty("id").GetString()!;
            using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "ocr", id + ".json")));
            var area = Box(fixture.RootElement.GetProperty("region"));
            var key = frame.TryGetProperty("session", out var session) ? session.GetString()! : id;
            if (!bands.TryGetValue(key, out var band)) bands[key] = band = new SubtitleBand();
            var reading = Lines(fixture.RootElement.GetProperty("lines"));
            if (fixture.RootElement.TryGetProperty("phone", out var phone))
            {
                // Altyazı hattı gibi: telefonun ekranındaki satırlar okunmaz (SubtitlePipeline.FindsPhone).
                var p = phone.EnumerateArray().Select(v => v.GetDouble()).ToArray();
                var handset = new ScreenPhoneCard.Handset(new GamePhoneGeometry.Pose(p[0], p[1], p[2], p[3]), p[4]);
                reading = new Reading(reading.Lines.Where(line => line.Box is not { } b || !ScreenPhoneCard.Holds(b.PlacedIn(area), handset)));
            }
            var block = reading.WithoutButtonPrompts().WithoutOcrNoise().JoiningRows().SubtitleBlock(area, band);
            band.Record(block, area);
            var expected = golden.RootElement.GetProperty(id).GetString();
            Assert.True(expected == block.Text, $"{id}: Mac \"{expected}\", Windows \"{block.Text}\"");
        }
    }
}
