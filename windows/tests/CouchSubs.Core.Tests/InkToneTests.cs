// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Açık zemindeki koyu yazı (kâğıt ilan) altyazı sayılmaz (GitHub #1124). Örnekler ortak deneme dosyasından
/// (core/Tests/CouchSubsCoreTests/Fixtures/dark-ink.json; Mac InkToneTests.swift ve Android InkToneTest.kt aynı dosyayı okur).
/// </summary>
public class InkToneTests
{
    private static TextBox Box(JsonElement element)
    {
        var b = element.EnumerateArray().Select(v => v.GetDouble()).ToArray();
        return new TextBox(b[0], b[1], b[2], b[3]);
    }

    private static JsonDocument Vectors() => JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("dark-ink.json")));

    private static int[] Render(JsonElement image, out int width, out int height)
    {
        width = image.GetProperty("width").GetInt32();
        height = image.GetProperty("height").GetInt32();
        var pixels = Enumerable.Repeat(image.GetProperty("fill").GetInt32(), width * height).ToArray();
        foreach (var rect in image.GetProperty("rects").EnumerateArray())
        {
            var r = rect.EnumerateArray().Select(v => v.GetInt32()).ToArray();
            for (var y = Math.Max(0, r[1]); y < Math.Min(height, r[3]); y++)
                for (var x = Math.Max(0, r[0]); x < Math.Min(width, r[2]); x++)
                    pixels[(y * width) + x] = r[4];
        }
        return pixels;
    }

    [Fact]
    public void Pixels()
    {
        using var vectors = Vectors();
        foreach (var image in vectors.RootElement.GetProperty("images").EnumerateArray())
        {
            var name = image.GetProperty("name").GetString();
            var pixels = Render(image, out var width, out var height);
            var dark = InkTone.IsDarkOnLight(Box(image.GetProperty("box")), width, height, (x, y) => pixels[(y * width) + x]);
            Assert.True(image.GetProperty("dark").GetBoolean() == dark, name);
        }
    }

    /// <summary>Aynı denetim BGRA kareden (altyazı hattının kullandığı yol).</summary>
    [Fact]
    public void SamplerReadsFrame()
    {
        using var vectors = Vectors();
        foreach (var image in vectors.RootElement.GetProperty("images").EnumerateArray())
        {
            var name = image.GetProperty("name").GetString();
            var pixels = Render(image, out var width, out var height);
            var bytes = new byte[width * height * 4];
            for (var i = 0; i < pixels.Length; i++)
            {
                bytes[i * 4] = bytes[(i * 4) + 1] = bytes[(i * 4) + 2] = (byte)pixels[i];
                bytes[(i * 4) + 3] = 255;
            }
            var frame = new Frame(bytes, width, height, width * 4);
            Assert.True(image.GetProperty("dark").GetBoolean() == InkTone.Sampler(frame)(Box(image.GetProperty("box"))), name);
        }
    }

    [Fact]
    public void Blocks()
    {
        using var vectors = Vectors();
        var area = Box(vectors.RootElement.GetProperty("area"));
        foreach (var vector in vectors.RootElement.GetProperty("blocks").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var lines = vector.GetProperty("lines").EnumerateArray().ToList();
            var reading = new Reading(lines.Select(line => new TextLine(line.GetProperty("text").GetString()!, Box(line.GetProperty("box")))).ToList());
            var dark = lines.Where(line => line.TryGetProperty("dark", out var d) && d.GetBoolean()).Select(line => Box(line.GetProperty("box"))).ToList();
            var reasons = new List<string>();
            var block = reading.SubtitleBlock(area, dropped: (_, reason) => reasons.Add(reason), darkInk: box => dark.Contains(box));
            var subtitle = vector.GetProperty("subtitle").GetString()!;
            Assert.True(subtitle == block.Text, $"{name}: {block.Text}");
            if (subtitle.Length == 0) Assert.Equal(new[] { InkTone.Reason }, reasons);
            // Renk verilmezse koyu yazı kuralı çalışmaz.
            Assert.NotEqual("", reading.SubtitleBlock(area).Text);
        }
    }

    [Fact]
    public void GameStyle()
    {
        using var vectors = Vectors();
        var area = Box(vectors.RootElement.GetProperty("area"));
        foreach (var vector in vectors.RootElement.GetProperty("style").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString();
            var lightInk = vector.TryGetProperty("lightInk", out var lightValue) && lightValue.GetBoolean();
            DarkInkStyle Run(bool knownLight)
            {
                var seenStyle = new DarkInkStyle { LightInk = knownLight };
                foreach (var seen in vector.GetProperty("blocks").EnumerateArray())
                {
                    var box = Box(seen.GetProperty("box"));
                    seenStyle.Observe(new Reading(seen.GetProperty("text").GetString()!.Split('\n').Select(text => new TextLine(text, box)).ToList()), area);
                }
                return seenStyle;
            }
            var style = Run(lightInk);
            Assert.True(vector.GetProperty("gameStyle").GetBoolean() == style.IsGameStyle, name);
            style.Reset();
            Assert.False(style.IsGameStyle, name);
            // Açık yazılı oyunda kuralı kapatmayan bloklar başka oyunda kapatır (vektör anlamlı).
            if (lightInk) Assert.True(Run(false).IsGameStyle, name);
        }
    }
}
