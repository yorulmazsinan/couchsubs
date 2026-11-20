// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core.Tests;

/// <summary>
/// GitHub #715: iki satırlı altyazının (üst satır 6-7 sözcük, alttaki devamı 1-2 sözcük, ortalanmış) yalnız ALT satırı
/// çevriliyordu. Alt satır üstten sonra belirince (yazı yazılır gibi ya da satır satır) üst satır "uçta bekleyen görev
/// satırı" sanılıp atılıyor (<see cref="StickyRows.LingerMs"/>), ya da kısa satırın kutusu daha alçak olduğu için (büyük
/// harfsiz/kuyruksuz sözcük) "yazı boyu farklı" denip ayrı blok sayılıyor, en alttaki blok seçiliyordu. İki satır hep
/// tek altyazı olmalı; görev satırı varken de (Mac: TwoLineSubtitleTests.swift, Android: TwoLineSubtitleTest.kt).
/// </summary>
public class TwoLineSubtitleTests
{
    private const string Objective = "Go to the bank.";

    internal static readonly string[][] Subtitles =
    [
        ["Local junkies might find a car missing its", "catalytic converter."],
        ["I already told you we should leave right", "now."],
        ["You never listen to anything I say about", "money."],
        ["I already explained everything about the plan to", "Lucia."],
        ["We are going to need a much bigger", "boat, man."],
    ];

    private const double Line = 0.08;

    private static TextLine Row(string text, double top, double width, double height = Line) =>
        new(text, new TextBox(0.5 - width / 2, top, 0.5 + width / 2, top + height), 0.95);

    /// <summary>
    /// 100 ms'de bir kare. Her altyazı 3 sn: üst satır hemen, alt satır <paramref name="delayMs"/> sonra; alt satır dar ve
    /// kutusu daha alçak (0,7 kat). <paramref name="objective"/>: görev satırı altta (true), üstte (false) ya da yok (null);
    /// görev altyazılardan 2 sn önce belirir (ObjectiveWithDialogueTests ile aynı).
    /// <paramref name="typing"/>: üst satır da yazılır gibi büyür (her karede birkaç harf).
    /// </summary>
    internal static List<Reading> Frames(int delayMs, bool? objective, bool typing)
    {
        var frames = new List<Reading>();
        for (var i = 0; i < 20 && objective is not null; i++) frames.Add(new Reading([Row(Objective, objective.Value ? 0.8 : 0.2, 0.3)]));
        foreach (var lines in Subtitles)
        {
            var top = objective == false ? 0.35 : 0.6;
            for (var t = 0; t < 3000; t += 100)
            {
                var rows = new List<TextLine>();
                if (objective == false) rows.Add(Row(Objective, 0.2, 0.3));
                var upper = lines[0];
                if (typing) upper = upper[..Math.Min(upper.Length, 4 + upper.Length * t / Math.Max(1, delayMs))];
                rows.Add(Row(upper, top, 0.6 * upper.Length / lines[0].Length));
                if (t >= delayMs) rows.Add(Row(lines[1], top + Line, 0.12, Line * 0.7));
                if (objective == true) rows.Add(Row(Objective, 0.8, 0.3));
                frames.Add(new Reading(rows));
            }
            // Altyazılar arasında kısa boşluk.
            for (var i = 0; i < 3; i++)
                frames.Add(objective is null ? Reading.Empty : new Reading([Row(Objective, objective.Value ? 0.8 : 0.2, 0.3)]));
        }
        return frames;
    }

    [Theory]
    [InlineData(0, null, false)]
    [InlineData(300, null, false)]
    [InlineData(800, null, false)]
    [InlineData(1500, null, false)]
    [InlineData(1500, null, true)]
    [InlineData(0, true, false)]
    [InlineData(800, true, false)]
    [InlineData(1500, true, false)]
    [InlineData(1500, true, true)]
    [InlineData(800, false, false)]
    [InlineData(1500, false, false)]
    public async Task BothLinesAreTranslatedTogether(int delayMs, bool? objective, bool typing)
    {
        var frames = Frames(delayMs, objective, typing);
        long clock = 0;
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new SequenceReader(frames), translator, new FakeSender(), clock: () => clock)
        { PackWait = 0, CleanWait = 0 };
        foreach (var _ in frames)
        {
            await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion(0, 1, 0, 1));
            await pipeline.WaitForTranslationsAsync();
            clock += 100;
        }
        var requested = string.Join(" | ", translator.Requested);
        foreach (var lines in Subtitles)
        {
            // Son çeviri iki satırı birlikte taşır; alt satır tek başına hiç çevrilmez.
            Assert.True(translator.Requested.Any(text => text.Contains(lines[0]) && text.Contains(lines[1])),
                $"birlikte çevrilmedi: {lines[0]} / {lines[1]} — istekler: {requested}");
            Assert.DoesNotContain(translator.Requested, text => text.Trim() == lines[1]);
        }
        // Görev satırı hiçbir altyazıya karışmaz.
        Assert.DoesNotContain(translator.Requested, text => text.Contains("Go to the bank") && text.Trim() != Objective);
    }
}
