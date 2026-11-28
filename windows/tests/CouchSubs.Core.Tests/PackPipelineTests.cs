// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core.Dubbing;

namespace CouchSubs.Core.Tests;

/// <summary>Oyun paketindeki satır çeviri motoruna gitmeden gösterilir (Mac: SubtitlePipelineTests, paket testleri).</summary>
public class PackPipelineTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    private static PackMatch? Lookup(string text) => PackKey.Canon(text) == "get down"
        ? new PackMatch("Yere yat!", [new SpokenLine("Get down!", "Yere yat!")])
        : null;

    private static async Task Run(SubtitlePipeline pipeline, int frames)
    {
        for (var i = 0; i < frames; i++)
        {
            await pipeline.ProcessAsync(Image, new CropRegion());
            await pipeline.WaitForTranslationsAsync();
        }
    }

    [Fact]
    public async Task PackHitSkipsTheEngine()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Get down!", "Get down!", "Get down!"), translator, sender) { PackLookup = Lookup };
        var shown = new List<(string, string)>();
        var spoken = new List<IReadOnlyList<SpokenLine>>();
        var missed = new List<string>();
        pipeline.PairShown += (source, translation) => shown.Add((source, translation));
        pipeline.SpeechReady += spoken.Add;
        pipeline.PackMissed += missed.Add;
        await Run(pipeline, 3);
        Assert.Equal(["Yere yat!"], sender.Sent);
        Assert.Empty(translator.Requested);
        Assert.Equal([("Get down!", "Yere yat!")], shown);
        Assert.Equal("Yere yat!", Assert.Single(spoken).Single().Turkish);
        Assert.Empty(missed);
        Assert.Equal("paket", pipeline.LastOrigin);
        Assert.Equal(1, pipeline.PackHits);
    }

    /// <summary>Saati her karede <paramref name="stepMs"/> ilerleterek çalıştırır (bekleme süreleri için).</summary>
    private static async Task RunTimed(SubtitlePipeline pipeline, int frames, Action advance)
    {
        for (var i = 0; i < frames; i++)
        {
            await pipeline.ProcessAsync(Image, new CropRegion());
            await pipeline.WaitForTranslationsAsync();
            advance();
        }
    }

    /// <summary>Pakette olmayan temiz satır kısa bir beklemeden (yarım okuma olabilir) sonra motora gider ve bildirilir.</summary>
    [Fact]
    public async Task PackMissUsesTheEngineAndIsReported()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate", "Hold the gate", "Hold the gate"), translator, sender, clock: () => clock)
            { PackLookup = Lookup };
        var missed = new List<string>();
        pipeline.PackMissed += missed.Add;
        // İkinci karede kararlı olur ve bekletilir; 300 ms sonraki karede motora gider.
        await RunTimed(pipeline, 2, () => clock += 100);
        Assert.Empty(sender.Sent);
        await RunTimed(pipeline, 2, () => clock += 200);
        Assert.Equal(["TR: Hold the gate"], sender.Sent);
        Assert.Equal(["Hold the gate"], translator.Requested);
        Assert.Equal(["Hold the gate"], missed);
        Assert.Equal("motor", pipeline.LastOrigin);
    }

    /// <summary>
    /// Bozuk okuma ("Get dovvn!") hemen çevrilmez; aynı satır düzgün okununca paketteki Türkçesi gösterilir ve
    /// bozuk okuma çeviri motoruna hiç gitmez (GTA V'te parlak zeminde bozuk okunan altyazılar).
    /// </summary>
    [Fact]
    public async Task MisreadLineWaitsForThePackMatch()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var pipeline = new SubtitlePipeline(new FakeReader("Gét dovvn!", "Get dovvn!", "Get down!", "Get down!"), translator, sender, clock: () => clock)
            { PackLookup = Lookup, LooksMisread = text => text.Contains("vv") || text.Contains('é') };
        await RunTimed(pipeline, 4, () => clock += 100);
        Assert.Equal(["Yere yat!"], sender.Sent);
        Assert.Empty(translator.Requested);
    }

    /// <summary>Düzgün okuması hiç gelmeyen bozuk satır en çok <see cref="SubtitlePipeline.PackWaitMs"/> sonra çevrilir.</summary>
    [Fact]
    public async Task MisreadLineIsTranslatedAfterTheWait()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat("Hold the gatte", 12).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { PackLookup = Lookup, LooksMisread = text => text.Contains("tt") };
        await RunTimed(pipeline, 7, () => clock += 100);
        Assert.Empty(sender.Sent);
        await RunTimed(pipeline, 3, () => clock += 100);
        Assert.Equal(["TR: Hold the gatte"], sender.Sent);
    }

    /// <summary>
    /// Paketsiz (GTA 6 gibi) bekleme: aynı satırın yarım ve bozuk okumaları ayrı ayrı çevrilmez; bekleme süresinde gelen
    /// okumalardan en yüksek puanlısı (tam satır) bir kez çevrilir.
    /// </summary>
    [Fact]
    public async Task WithoutPacksTheBestReadingOfALineIsTranslatedOnce()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        // Sahte çevirmen yalnız "TR: " ekler; kısa satır seçilir ki çeviri kaynağa çok benzeyip elenmesin (ShouldSend).
        var frames = new[] { "the gate", "the gate", "Hold the gate!", "Hold the gate!", "Hold the gate!", "Hold the gate!" };
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = text => text.Length, LooksMisread = _ => false };
        await RunTimed(pipeline, 6, () => clock += 100);
        Assert.Equal(["TR: Hold the gate!"], sender.Sent);
        Assert.Equal(["Hold the gate!"], translator.Requested);
    }

    /// <summary>Çevrilen satırın daha kötü yeniden okuması (renkli sözcüğü kaçan görev yazısı) yeniden çevrilmez.</summary>
    [Fact]
    public async Task WorseRereadOfATranslatedLineIsNotTranslatedAgain()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat("Chase the yacht.", 6).Concat(Enumerable.Repeat("Chase the", 6)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = text => text.Length, LooksMisread = _ => false };
        await RunTimed(pipeline, 12, () => clock += 100);
        Assert.Equal(["Chase the yacht."], translator.Requested);
    }

    /// <summary>
    /// Öncekinin sözcüklerini taşıyan ama ayrı olan kısa satır ("I swear to God, you kill me!" ardından "You kill me!")
    /// yeniden okuma sayılıp atılmaz.
    /// </summary>
    [Fact]
    public async Task ShortSeparateLineAfterALongerOneIsTranslated()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat("I swear to God, you kill me!", 4).Concat(Enumerable.Repeat("You kill me!", 4)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = text => text.Length, LooksMisread = _ => false };
        await RunTimed(pipeline, 8, () => clock += 100);
        Assert.Equal(["I swear to God, you kill me!", "You kill me!"], translator.Requested);
    }

    /// <summary>Çevrilen satırın yalnız bozuk sözcükte ayrışan okuması ("Yeah? Dihnnr." / "Yeah? Damn.") yeniden çevrilmez.</summary>
    [Fact]
    public async Task NoisyVariantOfATranslatedLineIsNotTranslatedAgain()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat("Yeah? Damn.", 4).Concat(Enumerable.Repeat("Yeah? Dihnnr.", 4)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
        {
            HoldWithoutPacks = true,
            ReadingScore = text => text.Contains("dihnnr", StringComparison.OrdinalIgnoreCase) ? 4 : 8,
            LooksMisread = text => text.Contains("dihnnr", StringComparison.OrdinalIgnoreCase),
        };
        await RunTimed(pipeline, 8, () => clock += 100);
        Assert.Equal(["Yeah? Damn."], translator.Requested);
    }

    /// <summary>
    /// OCR'ın sözcüğü böldüğü bozuk okuma ("That smo e..." / "That smoke...") sözcük sayısı değişse de yeniden okumadır,
    /// yeniden çevrilmez (#296).
    /// </summary>
    [Theory]
    [InlineData("That smoke...", "That smo e...")]
    [InlineData("You have to ask?", "Y u ave to ask?")]
    [InlineData("Good thing we moved the car.", "Good thing we m ved the car.")]
    public async Task SplitWordMisreadOfATranslatedLineIsNotTranslatedAgain(string clean, string misread)
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        // Bozuk okuma bekleme süresinden (PackWait) uzun ekranda kalır; yeniden okuma sayılmasaydı bekleme bitince çevrilirdi.
        var frames = Enumerable.Repeat(clean, 4).Concat(Enumerable.Repeat(misread, 14)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
        {
            HoldWithoutPacks = true,
            ReadingScore = text => text == misread ? 4 : 8,
            LooksMisread = text => text == misread,
        };
        await RunTimed(pipeline, frames.Length, () => clock += 100);
        Assert.Equal([clean], translator.Requested);
    }

    /// <summary>Harf benzerliği bozuk okumayla başlayan başka bir satırı yutmaz; o satır yine çevrilir.</summary>
    [Fact]
    public async Task DifferentMisreadLineIsStillTranslated()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        const string next = "That's my b at, kid.";
        var frames = Enumerable.Repeat("That smoke...", 4).Concat(Enumerable.Repeat(next, 4)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
        {
            HoldWithoutPacks = true,
            PackWait = 0,
            ReadingScore = text => text.Length,
            LooksMisread = text => text == next,
        };
        await RunTimed(pipeline, 8, () => clock += 100);
        Assert.Equal(["That smoke...", next], translator.Requested);
    }

    [Theory]
    [InlineData("that smo e", "that smoke", true)]
    [InlineData("y u ave to ask", "you have to ask", true)]
    [InlineData("get 0n", "get on", false)] // kısa: harf benzerliği aranmaz
    [InlineData("that s my b at kid", "that smoke", false)]
    public void SameLettersIgnoresWordBreaks(string a, string b, bool same) =>
        Assert.Equal(same, TextMatch.SameLetters(a, b));

    /// <summary>Gelişmiş ayarlarda bekleme süreleri 0 olsa da bozuk tekrar okuma yeniden çevrilmez (denetim gecikme eklemez).</summary>
    [Fact]
    public async Task RereadCheckWorksWithZeroWaits()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat("Yeah? Damn.", 4).Concat(Enumerable.Repeat("Yeah? Dihnnr.", 4)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
        {
            HoldWithoutPacks = true,
            PackWait = 0,
            CleanWait = 0,
            ReadingScore = text => text.Contains("dihnnr", StringComparison.OrdinalIgnoreCase) ? 4 : 8,
            LooksMisread = text => text.Contains("dihnnr", StringComparison.OrdinalIgnoreCase),
        };
        await RunTimed(pipeline, 8, () => clock += 100);
        Assert.Equal(["Yeah? Damn."], translator.Requested);
    }

    /// <summary>Çevrilen satırın soldan kesik okuması ("can always buy another boat.") yeniden çevrilmez.</summary>
    [Fact]
    public async Task LeftCutRereadIsNotTranslatedAgain()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat("But you can always buy another boat.", 4).Concat(Enumerable.Repeat("can always buy another boat.", 4)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = text => text.Length, LooksMisread = _ => false };
        await RunTimed(pipeline, 8, () => clock += 100);
        Assert.Equal(["But you can always buy another boat."], translator.Requested);
    }

    /// <summary>
    /// İlk kare olumsuzluğu ya da sayıyı kaçırıp çevrildiyse, puanı daha yüksek olmasa da düzelen okuma yeniden
    /// okuma sayılmaz, çevrilir; TV'de anlamı ters çeviri kalmaz.
    /// </summary>
    [Theory]
    [InlineData("Meet me at the docks at 5.", "Meet me at the docks at 6.")]
    [InlineData("I can do that for you right now.", "I can't do that for you right now.")]
    [InlineData("I said that I would help you with this.", "I said that I would never help you with this.")]
    public async Task CorrectionThatChangesMeaningIsTranslated(string misread, string correct)
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = new[] { misread }.Concat(Enumerable.Repeat(correct, 6)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = _ => 10, LooksMisread = _ => false };
        await RunTimed(pipeline, 7, () => clock += 100);
        Assert.Equal([misread, correct], translator.Requested);
    }

    /// <summary>Olumsuzluğu kaçıran yeniden okuma ise gösterilen doğru satırı bozmaz (yalnız eklenen işaret sayılır).</summary>
    [Fact]
    public async Task RereadThatDropsANegationIsNotTranslated()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat("I can't do that for you right now.", 3).Concat(Enumerable.Repeat("I can do that for you right now.", 3)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = _ => 10, LooksMisread = _ => false };
        await RunTimed(pipeline, 6, () => clock += 100);
        Assert.Equal(["I can't do that for you right now."], translator.Requested);
    }

    /// <summary>Bekleme sırasında gelen anlam düzeltmesi, okuma puanı eşit olsa da kaybolmaz.</summary>
    [Theory]
    [InlineData("I can do that for you right now", "I can't do that for you right now", 2)]
    [InlineData("Meet me at the docks at 5", "Meet me at the docks at 6", 2)]
    [InlineData("I can do that for you right now", "I can't do that for you right now", 4)]
    [InlineData("Meet me at the docks at 5", "Meet me at the docks at 6", 4)]
    public async Task HeldMeaningCorrectionReplacesEarlierReading(string misread, string correct, int initialFrames)
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var frames = Enumerable.Repeat(misread, initialFrames).Concat(Enumerable.Repeat(correct, 8)).ToArray();
        var pipeline = new SubtitlePipeline(new FakeReader(frames), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = _ => 10, LooksMisread = _ => false };
        await RunTimed(pipeline, 4, () => clock += 100);
        Assert.Empty(translator.Requested);
        // İlk aday 100 ms'de beklemeye girdi: düzeltme, 400 ms olan son tarihi ileri atmamalı.
        await RunTimed(pipeline, 1, () => clock += 100);
        Assert.Equal([correct], translator.Requested);
        await RunTimed(pipeline, frames.Length - 5, () => clock += 100);
        Assert.Equal([correct], translator.Requested);
    }

    /// <summary>Temiz ve tam cümle (büyük harfle başlıyor, noktalamayla bitiyor) beklemeden çevrilir; gecikme olmaz.</summary>
    [Fact]
    public async Task CompleteCleanLineIsNotDelayed()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate!", "Hold the gate!"), translator, sender, clock: () => clock)
            { HoldWithoutPacks = true, ReadingScore = text => text.Length, LooksMisread = _ => false };
        await RunTimed(pipeline, 1, () => clock += 10);
        Assert.Equal(["TR: Hold the gate!"], sender.Sent);
    }

    /// <summary>Paket kapalıyken (PackLookup yok) her satır motora gider ve havuz için bildirilir.</summary>
    [Fact]
    public async Task WithoutPacksEveryLineGoesToTheEngine()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Get down!", "Get down!"), translator, sender);
        var missed = new List<string>();
        pipeline.PackMissed += missed.Add;
        await Run(pipeline, 2);
        Assert.Equal(["TR: Get down!"], sender.Sent);
        Assert.Equal(["Get down!"], missed);
    }

    /// <summary>Önceki satırın çevirisi sürerken gelen paket satırı beklemeden gösterilir; geç gelen eski çeviri üstüne yazmaz.</summary>
    [Fact]
    public async Task PackLineDoesNotWaitForASlowTranslation()
    {
        var sender = new FakeSender();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate", "Hold the gate", "Get down!", "Get down!"), translator, sender)
            { PackLookup = Lookup };
        for (var i = 0; i < 4; i++) await pipeline.ProcessAsync(Image, new CropRegion());
        Assert.Equal(["Yere yat!"], sender.Sent);
        translator.Open();
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["Yere yat!"], sender.Sent);
    }
}
