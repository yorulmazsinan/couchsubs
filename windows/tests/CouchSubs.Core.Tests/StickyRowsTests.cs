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
        // Görev konuşmadan 3 sn önce geldi: henüz sabit değil ama konuşmaya karışmaz (LingerMs).
        Assert.Equal("Yeah!", rows.Filter(Reading.FromText("Yeah!\n" + Objective), 3000).Text);
        // Görev 6 sn'dir ekranda, konuşma ondan 3 sn sonra geldi: görev sabit sayılır.
        Assert.Equal("Yeah!", rows.Filter(Reading.FromText("Yeah!\n" + Objective), 6000).Text);
        Assert.Equal([Objective], rows.NewlySticky);
        Assert.Equal("Okay.", rows.Filter(Reading.FromText("Okay.\n" + Objective), 7000).Text);
        // Konuşma kalktı, görev tek başına kaldı: TV'de eski konuşma kalmasın diye görev de okunmaz.
        Assert.Equal("", rows.Filter(Reading.FromText(Objective), 9000).Text);
        Assert.Equal("Get in the sea plane", rows.Filter(Reading.FromText("Get in the sea plane"), 9500).Text);
    }

    /// <summary>Konuşan adıyla başlayan satır uzun süre ekranda kalsa da görev/HUD sayılmaz (Mac, Android ile aynı).</summary>
    [Fact]
    public void SpeakerLineIsNeverSticky()
    {
        var rows = new StickyRows();
        const string named = "JASON: I don't like this place.";
        Assert.Equal(named, rows.Filter(Reading.FromText(named), 0).Text);
        Assert.Equal("Yeah!\n" + named, rows.Filter(Reading.FromText("Yeah!\n" + named), 6000).Text);
        Assert.Empty(rows.NewlySticky);
        Assert.Equal(named, rows.Filter(Reading.FromText(named), 9000).Text);
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
    public void OlderRowAtEdgeIsKeptOutOfNewDialogue()
    {
        var rows = new StickyRows();
        Assert.Equal(Objective + "\nI told you already.", rows.Filter(Reading.FromText(Objective + "\nI told you already."), 0).Text);
        // Görev üstte de olsa (altyazının üstünde duran görev) yeni konuşmaya karışmaz.
        Assert.Equal("We have to go.", rows.Filter(Reading.FromText(Objective + "\nWe have to go."), 1500).Text);
        // Konuşan adlı satır eski olsa da çıkarılmaz.
        var named = new StickyRows();
        named.Filter(Reading.FromText("Lucia: Wait for me."), 0);
        Assert.Equal("Lucia: Wait for me.\nOkay.", named.Filter(Reading.FromText("Lucia: Wait for me.\nOkay."), 2000).Text);
        // Görev tek başına kalınca (henüz sabit değilken) okunur.
        var alone = new StickyRows();
        alone.Filter(Reading.FromText(Objective), 0);
        Assert.Equal(Objective, alone.Filter(Reading.FromText(Objective), 3000).Text);
    }

    /// <summary>
    /// Kullanıcı bildirimi (X, beta.69, GTA 6): konuşma ekrandayken altına "Follow John" görevi geldi; eski kural konuşmayı
    /// (eski satır) görev sanıp atıyor, görevi altyazı olarak gönderiyordu.
    /// </summary>
    [Fact]
    public void ObjectiveAddedUnderTheDialogueIsDroppedNotTheDialogue()
    {
        const string dialogue = "I can't believe he's still alive after all that.";
        var rows = new StickyRows();
        Assert.Equal(dialogue, rows.Filter(Reading.FromText(dialogue), 0).Text);
        Assert.Equal(dialogue, rows.Filter(Reading.FromText(dialogue + "\nFollow John"), 1500).Text);
        Assert.Equal(["Follow John"], rows.Removed.Select(line => line.Text));
        Assert.Equal(dialogue, rows.Filter(Reading.FromText(dialogue + "\nFollow John"), 3000).Text);
        // Konuşma değişti, görev kaldı: yeni konuşma çevrilir, görev yine dışarıda.
        Assert.Equal("We need to keep moving.", rows.Filter(Reading.FromText("We need to keep moving.\nFollow John"), 4000).Text);
        // Konuşma kalkınca görev tek başına okunur (eskisi gibi).
        Assert.Equal("Follow John", rows.Filter(Reading.FromText("Follow John"), 4500).Text);
    }

    /// <summary>Eklenen satır görev sayılmaz: yazı yazılır gibi beliren ikinci satır, cümlenin devamı, konuşan adlı, boyu yakın.</summary>
    [Fact]
    public void DialogueAddedUnderTheDialogueStaysDialogue()
    {
        // Yazı yazılır gibi: üst satır az önce büyüyordu.
        var typed = new StickyRows();
        typed.Filter(Reading.FromText("I told you this was a"), 0);
        typed.Filter(Reading.FromText("I told you this was a bad idea."), 1000);
        Assert.Equal("I told you this was a bad idea.\nGo.", typed.Filter(Reading.FromText("I told you this was a bad idea.\nGo."), 1500).Text);
        // Alt satır üstteki cümlenin devamı.
        var wrapped = new StickyRows();
        wrapped.Filter(Reading.FromText("I told you this was a bad idea,"), 0);
        Assert.Equal("I told you this was a bad idea,\nbut you never listen.",
                     wrapped.Filter(Reading.FromText("I told you this was a bad idea,\nbut you never listen."), 2000).Text);
        // Konuşan adlı satır.
        var named = new StickyRows();
        named.Filter(Reading.FromText("We need to keep moving before they find us."), 0);
        Assert.Equal("Lucia: Go.", named.Filter(Reading.FromText("We need to keep moving before they find us.\nLucia: Go."), 2000).Text);
        // Boyu yakın: hangisinin görev olduğu bilinmez, eski kural (eski satır çıkar).
        var close = new StickyRows();
        close.Filter(Reading.FromText("We need to keep moving."), 0);
        Assert.Equal("We have to go there now.", close.Filter(Reading.FromText("We need to keep moving.\nWe have to go there now."), 2000).Text);
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
        Assert.Equal(new[] { Objective, "Yeah!", "Okay." }, translator.Requested);
    }

    [Fact]
    public void ReportsHowLongALineIsUnchanged()
    {
        var rows = new StickyRows();
        rows.Filter(Reading.FromText("STORM HITS VICE CITY COAST"), 0);
        rows.Filter(Reading.FromText("STORM HITS VICE CITY COAST"), 1000);
        Assert.Equal(1000L, rows.UnchangedMs("STORM HITS VICE CITY COAST", 1000));
        Assert.Null(rows.UnchangedMs("Something else entirely here", 1000));
    }
}
