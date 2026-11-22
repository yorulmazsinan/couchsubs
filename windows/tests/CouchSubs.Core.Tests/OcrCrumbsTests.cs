// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Okuma kırıntısı ve tek sözcük bozulması (GitHub #854, #882; GTA 6): HUD kırıntısı görev sayılmaz, konuşmanın üstünde
/// beliren kırıntı konuşmayı attırmaz, ilk karede bozuk okunan sözcük doğru okununca yeniden çevrilir. Kurallar ortak
/// deneme dosyasından (core/Tests/CouchSubsCoreTests/Fixtures/ocr-crumbs.json; Mac OcrCrumbsTests.swift ve Android
/// OcrCrumbsTest.kt aynı dosyayı okur).
/// </summary>
public class OcrCrumbsTests
{
    private static JsonElement Vectors(string name)
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("ocr-crumbs.json")));
        return fixture.RootElement.GetProperty(name).Clone();
    }

    private static string[] Strings(JsonElement element) => [.. element.EnumerateArray().Select(item => item.GetString()!)];

    [Fact]
    public void Crumbs()
    {
        foreach (var vector in Vectors("crumb").EnumerateArray())
        {
            var text = vector.GetProperty("text").GetString()!;
            Assert.True(OcrNoise.IsCrumb(text) == vector.GetProperty("crumb").GetBoolean(), text);
        }
    }

    [Fact]
    public void SymbolOnlyTokensAreDropped()
    {
        foreach (var vector in Vectors("clean").EnumerateArray())
            Assert.Equal(vector.GetProperty("out").GetString(), OcrNoise.Clean(vector.GetProperty("in").GetString()!));
    }

    [Fact]
    public void NonWords()
    {
        foreach (var vector in Vectors("nonWord").EnumerateArray())
        {
            var word = vector.GetProperty("word").GetString()!;
            Assert.True(OcrNoise.IsNonWord(word) == vector.GetProperty("nonWord").GetBoolean(), word);
        }
    }

    [Fact]
    public void MissionCandidates()
    {
        foreach (var vector in Vectors("mission").EnumerateArray())
        {
            var text = vector.GetProperty("text").GetString()!;
            var b = vector.GetProperty("box").EnumerateArray().Select(v => v.GetDouble()).ToArray();
            Assert.True(MissionLine.IsCandidate(text, new TextBox(b[0], b[1], b[2], b[3])) == vector.GetProperty("candidate").GetBoolean(), text);
        }
    }

    [Fact]
    public void StickyRowsKeepDialogueUnderCrumb()
    {
        foreach (var vector in Vectors("stickyRows").EnumerateArray())
        {
            var rows = new StickyRows();
            var kept = new Reading([]);
            foreach (var step in vector.GetProperty("steps").EnumerateArray())
            {
                var reading = new Reading([.. Strings(step.GetProperty("lines")).Select(text => new TextLine(text))]);
                kept = rows.Filter(reading, step.GetProperty("time").GetInt64());
            }
            Assert.Equal(Strings(vector.GetProperty("kept")), kept.Lines.Select(line => line.Text).ToArray());
        }
    }

    [Fact]
    public void StabilizerCorrections()
    {
        foreach (var vector in Vectors("stabilizer").EnumerateArray())
        {
            var name = vector.GetProperty("name").GetString()!;
            var source = vector.GetProperty("sent").GetString()!;
            long time = 0;
            var stabilizer = new SubtitleStabilizer(clock: () => time);
            var sent = false;
            for (var i = 0; i < vector.GetProperty("sentReads").GetInt32(); i++)
            {
                var action = stabilizer.Feed(source);
                if (action.Kind == StabilizerKind.Translate)
                {
                    Assert.Equal(source, action.Text);
                    sent = true;
                }
                time += 100;
            }
            Assert.True(sent, name);
            var translated = new List<string>();
            foreach (var read in Strings(vector.GetProperty("reads")))
            {
                var action = stabilizer.Feed(read);
                if (action.Kind == StabilizerKind.Translate) translated.Add(action.Text!);
                time += 100;
            }
            Assert.Equal(Strings(vector.GetProperty("translated")), translated.ToArray());
        }
    }
}
