// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.Tests;

/// <summary>
/// Görev satırı altyazıdan ayrı, kendi yerinde (spec bölüm 5): alt ortada görev satırı + değişen altyazı. Görev hiçbir
/// altyazıya girmez, bölgesi bir kez bildirilir (yanıp sönmez), görev kalkınca bölge de kalkar.
/// </summary>
public class MissionLineTests
{
    private const string Objective = "Go to the bank.";

    [Theory]
    [InlineData(true, 0.1, 4)]
    [InlineData(true, 1.5, 4)]
    [InlineData(false, 0.1, 4)]
    [InlineData(true, 0.1, 20)]
    public async Task ObjectiveGetsItsOwnAreaOnceWhileDialogueChanges(bool below, double gap, int objectiveFirst)
    {
        var frames = ObjectiveWithDialogueTests.Frames(below, gap, objectiveFirst);
        long clock = 0;
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new SequenceReader(frames), translator, new FakeSender(), clock: () => clock)
        { PackWait = 0, CleanWait = 0 };
        var regions = new List<CropRegion?>();
        pipeline.MissionChanged += regions.Add;
        for (var i = 0; i < frames.Count; i++)
        {
            await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion(0, 1, 0, 1));
            await pipeline.WaitForTranslationsAsync();
            clock += 500;
        }
        // Görevin bölgesi bir kez bildirildi; altyazı beş kez değişse de değişmedi.
        var region = Assert.Single(regions, item => item is not null);
        Assert.True(region!.Top <= (below ? 0.8 : 0.2) && region.Bottom >= (below ? 0.88 : 0.28));
        // Görev bir altyazı isteğine karışmadı.
        Assert.DoesNotContain(translator.Requested, text => text.Contains("Go to the bank") && text.Trim() != Objective);
    }

    [Fact]
    public async Task ObjectiveLeavingRemovesItsArea()
    {
        var frames = ObjectiveWithDialogueTests.Frames(true, 1.5, 4);
        frames.AddRange(Enumerable.Repeat(Reading.Empty, 6));
        long clock = 0;
        var pipeline = new SubtitlePipeline(new SequenceReader(frames), new FakeTranslator(), new FakeSender(), clock: () => clock)
        { PackWait = 0, CleanWait = 0 };
        var regions = new List<CropRegion?>();
        pipeline.MissionChanged += regions.Add;
        foreach (var _ in frames)
        {
            await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion(0, 1, 0, 1));
            await pipeline.WaitForTranslationsAsync();
            clock += 500;
        }
        Assert.NotNull(regions.First());
        Assert.Null(regions.Last());
    }

    [Fact]
    public void SpokenLinesAreNeverAMission()
    {
        var mission = new MissionLine();
        var area = new TextBox(0, 0, 1, 1);
        for (long time = 0; time <= 4000; time += 500)
            mission.Observe([new TextLine("Lucia: Wait here.", new TextBox(0.3, 0.8, 0.7, 0.88))], area, time);
        Assert.Null(mission.Region);
    }

    [Fact]
    public void LineThatAppearsWithTheFirstSubtitleIsASeparateBlock()
    {
        // Görev ilk altyazıyla aynı anda: aradaki boşluk satırın 0,6'sından büyük ya da yazı boyu farklıysa ayrı blok;
        // konuşan adlı blok altyazıdır.
        var reading = new Reading(
        [
            new TextLine("Lucia: Just drive the car.", new TextBox(0.2, 0.60, 0.8, 0.68)),
            new TextLine("Go to the bank.", new TextBox(0.35, 0.74, 0.65, 0.80)),
        ]);
        Assert.Equal("Lucia: Just drive the car.", reading.SubtitleBlock(new TextBox(0, 0, 1, 1)).Text);
    }
}
