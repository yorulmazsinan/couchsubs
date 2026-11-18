// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core.Tests;

/// <summary>GTA 6: görev yazısı konuşma altyazısının altında dakikalarca durur; altyazı onda takılı kalıyordu.</summary>
public class StickyRowsTests
{
    private const string Objective = "Stash the acid in Brian's lockup";

    [Fact]
    public void ObjectiveUnderChangingDialogueIsDropped()
    {
        var rows = new StickyRows();
        Assert.Equal(Objective, rows.Filter(Reading.FromText(Objective), 0).Text);
        Assert.Equal("Yeah!\n" + Objective, rows.Filter(Reading.FromText("Yeah!\n" + Objective), 3000).Text);
        // Görev 6 sn'dir ekranda, konuşma ondan 3 sn sonra geldi: görev sabit sayılır.
        Assert.Equal("Yeah!", rows.Filter(Reading.FromText("Yeah!\n" + Objective), 6000).Text);
        Assert.Equal([Objective], rows.NewlySticky);
        Assert.Equal("Okay.", rows.Filter(Reading.FromText("Okay.\n" + Objective), 7000).Text);
        // Konuşma kalktı, görev tek başına kaldı: TV'de eski konuşma kalmasın diye görev de okunmaz.
        Assert.Equal("", rows.Filter(Reading.FromText(Objective), 9000).Text);
        Assert.Equal("Get in the sea plane", rows.Filter(Reading.FromText("Get in the sea plane"), 9500).Text);
    }

    [Fact]
    public void DialogueBoxWhoseRowsAppearTogetherIsKept()
    {
        var rows = new StickyRows();
        const string page = "You can stay here as long as you like.\nThe inn is always open for travelers.";
        for (var time = 0; time <= 20_000; time += 500)
            Assert.Equal(page, rows.Filter(Reading.FromText(page), time).Text);
        // Yazı yazılır gibi beliren ikinci satır da birlikte gelmiş sayılır.
        var typed = new StickyRows();
        Assert.Equal("Where are you going?", typed.Filter(Reading.FromText("Where are you going?"), 0).Text);
        Assert.Equal("Where are you going?\nIt is late.", typed.Filter(Reading.FromText("Where are you going?\nIt is late."), 1000).Text);
        Assert.Equal("Where are you going?\nIt is late.", typed.Filter(Reading.FromText("Where are you going?\nIt is late."), 12_000).Text);
    }

    [Fact]
    public void RowThatLeftIsForgottenAndShownAgain()
    {
        var rows = new StickyRows();
        rows.Filter(Reading.FromText(Objective), 0);
        rows.Filter(Reading.FromText("Yeah!\n" + Objective), 3000);
        Assert.Equal("Yeah!", rows.Filter(Reading.FromText("Yeah!\n" + Objective), 6000).Text);
        // Kısa okuma kaçağı sabitliği bozmaz.
        rows.Filter(Reading.Empty, 6500);
        Assert.Equal("", rows.Filter(Reading.FromText(Objective), 7000).Text);
        // Görev ekrandan kalktı; yeniden belirince yeni yazıdır.
        rows.Filter(Reading.Empty, 9000);
        Assert.Equal(Objective, rows.Filter(Reading.FromText(Objective), 9500).Text);
    }

    [Fact]
    public async Task DialogueIsNotStuckBehindObjective()
    {
        var frames = Enumerable.Repeat(Objective, 8)
            .Concat(Enumerable.Repeat("Yeah!\n" + Objective, 10))
            .Concat(Enumerable.Repeat(Objective, 6))
            .Concat(Enumerable.Repeat("Okay.\n" + Objective, 4)).ToArray();
        long clock = 0;
        var translator = new FakeTranslator();
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
        { PackWait = 0, CleanWait = 0 };
        var clearsWhileObjectiveAlone = 0;
        for (var i = 0; i < frames.Length; i++)
        {
            await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion());
            await pipeline.WaitForTranslationsAsync();
            if (i == 23) clearsWhileObjectiveAlone = sender.Clears;
            clock += 500;
        }
        // Konuşma kalkıp görev tek başına kalınca eski konuşmanın çevirisi TV'den kalkar; yeni kısa konuşma çevrilir.
        Assert.True(clearsWhileObjectiveAlone > 0);
        Assert.Equal(new[] { Objective, "Yeah!\n" + Objective, "Okay." }, translator.Requested);
    }
}
