// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Uzun altyazı satırları: aşama aşama beliren satır tek altyazıdır ve yerinde güncellenir, yazı tanıma farkıyla okunan
/// uzun satır motora bir kez gider, art arda iki farklı uzun satırın ikisi de gösterilir (beta-104, Mafia: The Old Country).
/// Ortak deneme dosyası core/Tests/CouchSubsCoreTests/Fixtures/growing-lines.json (Mac GrowingLinesTests.swift ve
/// Android GrowingLinesTest.kt aynı dosyayı okur).
/// </summary>
public class GrowingLinesTests
{
    /// <summary>Harfleri ROT13 ile kaydırır (çeviri kaynağa benzemesin); iki kez uygulanınca kaynak geri gelir.</summary>
    internal static string Rot13(string text) => string.Concat(text.Select(c => c switch
    {
        >= 'a' and <= 'z' => (char)('a' + (c - 'a' + 13) % 26),
        >= 'A' and <= 'Z' => (char)('A' + (c - 'A' + 13) % 26),
        _ => c,
    }));

    private sealed class Translator(bool blocked) : ITextTranslator
    {
        public GatedTranslator Gate { get; } = new();
        public List<string> Requested { get; } = [];
        public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            lock (Requested) Requested.Add(text);
            if (blocked) await Gate.TranslateAsync(text, cancellationToken);
            return "TR: " + Rot13(text);
        }
    }

    public static IEnumerable<object[]> Cases()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("growing-lines.json")));
        foreach (var item in fixture.RootElement.GetProperty("cases").EnumerateArray())
            yield return [item.GetProperty("name").GetString()!];
    }

    private static JsonElement Case(string name)
    {
        var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("growing-lines.json")));
        return fixture.RootElement.GetProperty("cases").EnumerateArray().First(c => c.GetProperty("name").GetString() == name);
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public async Task Fixture(string name)
    {
        var item = Case(name);
        var reads = new List<string>();
        foreach (var read in item.GetProperty("reads").EnumerateArray())
            for (var i = 0; i < read.GetProperty("times").GetInt32(); i++) reads.Add(read.GetProperty("text").GetString()!);
        var frameMs = item.GetProperty("frameMs").GetInt32();
        var blocked = item.GetProperty("translator").GetString() == "blocked";
        long clock = 0;
        var translator = new Translator(blocked);
        var sender = new FakeSender();
        var log = new List<string>();
        var pipeline = new SubtitlePipeline(new FakeReader([.. reads]), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, Log = log.Add };
        try
        {
            foreach (var _ in reads)
            {
                await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion());
                if (!blocked) await pipeline.WaitForTranslationsAsync();
                clock += frameMs;
            }
        }
        finally
        {
            translator.Gate.Open();
            await pipeline.WaitForTranslationsAsync();
        }
        var requested = translator.Requested;
        var shown = sender.Sent.Select(text => text.StartsWith("TR: ", StringComparison.Ordinal) ? Rot13(text[4..]) : text).ToList();
        var trace = $"{name}\nmotor: {string.Join(" | ", requested)}\ngösterilen: {string.Join(" | ", shown)}\n"
                    + $"yerine: {string.Join(",", sender.Replaces)}\n{string.Join("\n", log)}";
        var expect = item.GetProperty("expect");
        if (expect.TryGetProperty("engineCalls", out var calls))
            Assert.True(calls.EnumerateArray().Select(c => c.GetString()!).SequenceEqual(requested), trace);
        if (expect.TryGetProperty("maxEngineCalls", out var max))
            Assert.True(requested.Count <= max.GetInt32(), trace);
        if (expect.TryGetProperty("shown", out var expectedShown))
            Assert.True(expectedShown.EnumerateArray().Select(c => c.GetString()!).SequenceEqual(shown), trace);
        Assert.True(sender.Replaces.Count(replaces => !replaces) == expect.GetProperty("fresh").GetInt32(), trace);
        Assert.True(shown.Count > 0 && shown[^1] == expect.GetProperty("last").GetString(), trace);
    }

    [Theory]
    [InlineData("Listen to me, Enz0. The Don wants you down at the docks", "Listen to me, Enzo. The Don wants you down", true)]
    [InlineData("You think the farnily forgets what you did for us\nback in Sicily?", "You think the family forgets what you did for us", true)]
    [InlineData("the docks before the sun comes up, Enzo.", "Listen to me, Enz0. The docks before the sun", false)]
    [InlineData("Listen to me, Enzo. The Don wants you down", "Listen to me, Enzo. The Don wants you down", false)]
    [InlineData("I don't know what you're talking about.", "I don't know what you want", false)]
    public void LooseGrowth(string newer, string older, bool expected) =>
        Assert.Equal(expected, TextMatch.IsLooseGrowth(newer, older));

    private const string Long = "Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done quietly.";

    [Theory]
    [InlineData(Long + " Il", true)]
    [InlineData("Listen to me, Enz0. The Don wants y0u down at the docks before\nthe sun comes up, and he wants it done quietly.", true)]
    [InlineData("Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done", true)]
    [InlineData(Long + " Go.", false)]
    [InlineData(Long + " Then come home.", false)]
    [InlineData("Listen to me, Enzo. The Don doesn't want you down at the docks before\nthe sun comes up, and he wants it done quietly.", false)]
    [InlineData("Listen to me, Enzo. The Don wants you down at the docks before\nthe sun comes up, and he wants it done in 5.", false)]
    [InlineData("Listen to me, Enzo.", false)]
    public void Jitter(string reread, bool expected) => Assert.Equal(expected, TextMatch.IsJitterOf(reread, Long));

    /// <summary>Gecikme dökümü 30 sn'de bir tek satır: her aşama adıyla (#1349 biçimi).</summary>
    [Fact]
    public async Task TimingLineNamesEveryStage()
    {
        long clock = 0;
        var reads = Enumerable.Repeat("Get in the car, Jason", 6).Concat(Enumerable.Repeat("", 2)).ToArray();
        var lines = new List<string>();
        var pipeline = new SubtitlePipeline(new FakeReader(reads), new Translator(false), new FakeSender(), clock: () => clock)
            { HoldWithoutPacks = true, TimingLog = lines.Add };
        for (var i = 0; i < reads.Length; i++)
        {
            await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion());
            await pipeline.WaitForTranslationsAsync();
            clock += i == reads.Length - 2 ? StageTiming.PeriodMs : 200;
        }
        var line = Assert.Single(lines);
        Assert.StartsWith("altyazı aşama süreleri", line);
        foreach (var stage in new[] { SubtitlePipeline.StageFrameGap, SubtitlePipeline.StageOcr, SubtitlePipeline.StageSettle,
                     SubtitlePipeline.StageHold, SubtitlePipeline.StageQueue, SubtitlePipeline.StageEngine, SubtitlePipeline.StageTotal })
            Assert.Contains(stage + " ", line);
        // Satır 2. karede doğrulandı (200 ms), 300 ms bekletildi: ilk okumadan TV'ye en az 500 ms.
        Assert.Contains($"{SubtitlePipeline.StageSettle} 1× ort 200,0", line);
    }
}
