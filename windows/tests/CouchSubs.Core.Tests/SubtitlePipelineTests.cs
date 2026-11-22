// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

internal sealed class FakeReader(params string[] texts) : ITextReader
{
    private readonly Queue<string> texts = new(texts);
    public List<int> ReadThreads { get; } = [];
    public string Read(Frame image)
    {
        lock (ReadThreads) ReadThreads.Add(Environment.CurrentManagedThreadId);
        lock (texts) return texts.Count == 0 ? "" : texts.Dequeue();
    }
}

/// <summary>Satırları yerleriyle döndüren okuyucu.</summary>
internal sealed class LinesReader(Reading reading) : ITextReader
{
    public string Read(Frame image) => reading.Text;
    public Reading ReadLines(Frame image, bool deep) => reading;
}

internal sealed class FakeTranslator : ITextTranslator
{
    public Exception? Error { get; set; }
    public int FailuresLeft { get; set; }
    public List<string> Requested { get; } = [];
    public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        lock (Requested) Requested.Add(text);
        if (Error is not null) throw Error;
        if (FailuresLeft > 0) { FailuresLeft--; throw new TimeoutException(); }
        return Task.FromResult("TR: " + text);
    }
}

/// Çevirileri test bırakana kadar bekletir; açıldıktan sonra gelenler beklemez.
internal sealed class GatedTranslator : ITextTranslator
{
    private readonly object gate = new();
    private readonly List<(string Text, TaskCompletionSource Done)> waiting = [];
    private bool isOpen;
    public List<string> Requested { get; } = [];

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        TaskCompletionSource? done = null;
        lock (gate)
        {
            Requested.Add(text);
            if (!isOpen) { done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); waiting.Add((text, done)); }
        }
        // Gerçek motor gibi iptale uyar (bırakılan çeviri beklemede kalmaz).
        if (done is not null) await done.Task.WaitAsync(cancellationToken);
        return "TR: " + text;
    }

    public void Open()
    {
        lock (gate) { isOpen = true; foreach (var w in waiting) w.Done.SetResult(); waiting.Clear(); }
    }

    /// Yalnız bu satırın çevirisini bitirir (sırayı test belirler).
    public async Task Release(string text)
    {
        while (true)
        {
            lock (gate)
            {
                var index = waiting.FindIndex(w => w.Text == text);
                if (index >= 0) { var entry = waiting[index]; waiting.RemoveAt(index); entry.Done.SetResult(); return; }
            }
            await Task.Delay(5);
        }
    }
}

internal sealed class FakeSender : ISubtitleSender
{
    public List<string> Sent { get; } = [];
    public List<int> Durations { get; } = [];
    public List<TextBox?> Boxes { get; } = [];
    public List<bool> Replaces { get; } = [];
    public int Clears { get; private set; }
    public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false)
    {
        lock (Sent) { Sent.Add(text); Durations.Add(durationMs); Boxes.Add(box); Replaces.Add(replaces); }
    }
    public void Clear() => Clears++;
}

public class SubtitlePipelineTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    /// <summary>Saniyede 20 okuma: saat verilirse her kareden sonra 50 ms ilerler.</summary>
    private static async Task Run(SubtitlePipeline pipeline, int frames, bool waitEach = true, TestClock? clock = null)
    {
        for (var i = 0; i < frames; i++)
        {
            await pipeline.ProcessAsync(Image, new CropRegion());
            if (waitEach) await pipeline.WaitForTranslationsAsync();
            if (clock is not null) clock.Now += 50;
        }
    }

    private static string[] Lines(params (string Text, int Count)[] runs) =>
        [.. runs.SelectMany(run => Enumerable.Repeat(run.Text, run.Count))];

    /// <summary>Okumayı test bırakana kadar bekletir (takılan yazı tanıma).</summary>
    private sealed class BlockingReader(string text) : ITextReader
    {
        public readonly ManualResetEventSlim Entered = new();
        public readonly ManualResetEventSlim Release = new();
        public string Read(Frame image)
        {
            Entered.Set();
            Release.Wait(TimeSpan.FromSeconds(10));
            return text;
        }
    }

    // Takılan okuma hat sıfırlandıktan sonra bitince eski satır TV'ye gitmez (FrameGate ile birlikte, 2026-11-13).
    [Fact]
    public async Task ReadFinishingAfterResetIsDropped()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        var reader = new BlockingReader("Hold the gate.");
        var pipeline = new SubtitlePipeline(reader, translator, sender);
        var running = pipeline.ProcessAsync(Image, new CropRegion());
        Assert.True(reader.Entered.Wait(TimeSpan.FromSeconds(5)));
        pipeline.Reset();
        reader.Release.Set();
        await running;
        Assert.Empty(translator.Requested);
        Assert.Empty(sender.Sent);
    }

    [Fact]
    public async Task BlockedReadIsTranslatedWhenNotReset()
    {
        var translator = new FakeTranslator();
        var reader = new BlockingReader("Hold the gate.");
        var pipeline = new SubtitlePipeline(reader, translator, new FakeSender());
        var running = pipeline.ProcessAsync(Image, new CropRegion());
        Assert.True(reader.Entered.Wait(TimeSpan.FromSeconds(5)));
        reader.Release.Set();
        await running;
        for (var i = 0; i < 50 && translator.Requested.Count == 0; i++) await Task.Delay(20);
        Assert.Equal(["Hold the gate."], translator.Requested);
    }

    [Fact]
    public async Task ButtonPromptsAreNotTranslated()
    {
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(
            new FakeReader("R2 Swing", "R2 Swing", "Hold the gate\nR2 Swing", "Hold the gate\nR2 Swing"), new FakeTranslator(), sender);
        await Run(pipeline, 4);
        Assert.Equal(["TR: Hold the gate"], sender.Sent);
    }

    [Fact]
    public async Task SubtitleBoxIsSentInFrameCoordinates()
    {
        var sender = new FakeSender();
        var reading = new Reading([new TextLine("Hold the gate.", new TextBox(0.25, 0.5, 0.75, 1))]);
        var pipeline = new SubtitlePipeline(new LinesReader(reading), new FakeTranslator(), sender);
        await pipeline.ProcessAsync(Image, new CropRegion(Top: 0.6, Bottom: 1.0, Left: 0.1, Right: 0.9));
        await pipeline.WaitForTranslationsAsync();
        var box = Assert.Single(sender.Boxes)!.Value;
        Assert.Equal(0.3, box.Left, 9);
        Assert.Equal(0.8, box.Top, 9);
        Assert.Equal(0.7, box.Right, 9);
        Assert.Equal(1.0, box.Bottom, 9);
    }

    [Fact]
    public void CenterStripLinesAreReportedInRegionCoordinates()
    {
        var reading = ReadingFallback.FirstLines(Image, candidate => candidate.Width == 64
            ? Reading.Empty
            : new Reading([new TextLine("Go!", new TextBox(0, 0.5, 1, 1))]));
        var box = reading.Box!.Value;
        Assert.Equal(19.0 / 64, box.Left, 9);
        Assert.Equal(45.0 / 64, box.Right, 9);
        Assert.Equal(0.5, box.Top, 9);
    }

    /// <summary>Altyazı günlüğü: ilk kare, ilk yazı, her kararlı satır ve akıbeti (motor ya da paket) yazılır.</summary>
    [Fact]
    public async Task LogsEachLineAndItsOutcome()
    {
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate.", "Hold the gate.", "Run!", "Run!"), new FakeTranslator(), sender);
        var log = new List<string>();
        pipeline.Log = log.Add;
        pipeline.PackLookup = text => text == "Run!" ? new PackMatch("Koş!", []) : null;
        pipeline.PackName = () => "mafia";
        await Run(pipeline, 4);
        pipeline.Reset();
        Assert.Equal(["TR: Hold the gate.", "Koş!"], sender.Sent);
        Assert.Equal(6, log.Count);
        Assert.StartsWith("ilk kare: oturum başından ", log[0]);
        Assert.StartsWith("ilk yazı: ", log[1]);
        Assert.EndsWith("\"Hold the gate.\"", log[1]);
        Assert.Equal("#1 \"Hold the gate.\" → çeviriye", log[2]);
        Assert.StartsWith("#1 çeviri:motor ", log[3]);
        Assert.EndsWith(" ms, gösterildi", log[3]);
        Assert.Equal("#2 \"Run!\" → paket:mafia", log[4]);
        Assert.Equal("hat sıfırlandı (paketten 1 satır)", log[5]);
    }

    /// <summary>Önbellekten dönen satır günlükte "önbellek" diye görünür.</summary>
    [Fact]
    public async Task LogTellsCachedTranslations()
    {
        var cache = new TranslationCache(engine: "opus-mt");
        cache.Store("Hold the gate.", "Kapıyı tut.");
        var translator = new CachedTranslator(cache);
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate.", "Run now."), translator, new FakeSender());
        var log = new List<string>();
        pipeline.Log = log.Add;
        await Run(pipeline, 2);
        Assert.Contains(log, line => line.StartsWith("#1 önbellek ", StringComparison.Ordinal));
        Assert.Contains(log, line => line.StartsWith("#2 çeviri:opus-mt ", StringComparison.Ordinal));
    }

    private sealed class CachedTranslator(TranslationCache cache) : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            if (cache.TryGet(text, out var known)) return Task.FromResult(known);
            cache.Store(text, "TR: " + text);
            return Task.FromResult("TR: " + text);
        }
    }

    [Fact]
    public async Task StableTextIsTranslatedAndSentOnce()
    {
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate", "Hold the gate", "Hold the gate"), new FakeTranslator(), sender);
        await Run(pipeline, 3);
        Assert.Equal(["TR: Hold the gate"], sender.Sent);
        Assert.Equal("Hold the gate", pipeline.LastPair?.Source);
    }

    [Fact]
    public async Task TextRecognitionRunsOffTheCallingThread()
    {
        var reader = new FakeReader("Hold the gate");
        var pipeline = new SubtitlePipeline(reader, new FakeTranslator(), new FakeSender());
        var caller = Environment.CurrentManagedThreadId;
        await pipeline.ProcessAsync(Image, new CropRegion());
        Assert.DoesNotContain(caller, reader.ReadThreads);
    }

    [Fact]
    public async Task MissingModelSendsNothing()
    {
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate", "Hold the gate"),
            new FakeTranslator { Error = new TranslatorException(TranslatorStatus.NeedsDownload) }, sender);
        await Run(pipeline, 2);
        Assert.Empty(sender.Sent);
        Assert.Equal(TranslatorStatus.NeedsDownload, pipeline.LastError);
    }

    [Fact]
    public async Task FailedTranslationIsRetriedWhileLineStaysOnScreen()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate", 25))),
            new FakeTranslator { FailuresLeft = 1 }, sender, clock: clock.Read);
        await Run(pipeline, 25, clock: clock);
        Assert.Equal(["TR: Hold the gate"], sender.Sent);
    }

    /// Kalıcı hatada (model eksik) satır ekranda durdukça çevirmene saniyede en çok bir kez gidilir.
    [Fact]
    public async Task FailedTranslationRetriesAreRateLimited()
    {
        var clock = new TestClock();
        var translator = new FakeTranslator { Error = new TranslatorException(TranslatorStatus.NeedsDownload) };
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate", 40))), translator, new FakeSender(), clock: clock.Read);
        await Run(pipeline, 40, clock: clock);
        Assert.InRange(translator.Requested.Count, 2, 3);
    }

    /// Okuma saniyede ~20 kez yapılır; kısa okunamayan an altyazıyı TV'den silmemeli.
    [Fact]
    public async Task ShortReadingGapDoesNotClearTheTv()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate", 2), ("", 2), ("Hold the gate", 1))), new FakeTranslator(), sender, clock: clock.Read);
        await Run(pipeline, 5, clock: clock);
        Assert.Equal(0, sender.Clears);
        Assert.Equal(["TR: Hold the gate"], sender.Sent);
    }

    /// Parlak arka planda okuma yarım saniye kaçsa da TV'deki altyazı silinmez, aynı satır yeniden gönderilmez.
    [Fact]
    public async Task FlickerShorterThanClearTimeNeitherClearsNorResends()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate", 3), ("", 15), ("Hold the gate", 3), ("", 10), ("Hold the gate", 3))),
            translator, sender, clock: clock.Read);
        await Run(pipeline, 34, clock: clock);
        Assert.Equal(0, sender.Clears);
        Assert.Equal(["TR: Hold the gate"], sender.Sent);
        Assert.Single(translator.Requested);
    }

    [Fact]
    public async Task SubtitleGoneForClearTimeClearsTheTv()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate", 2), ("", 17))), new FakeTranslator(), sender, clock: clock.Read);
        await Run(pipeline, 18, clock: clock);
        Assert.Equal(0, sender.Clears);
        await Run(pipeline, 1, clock: clock);
        Assert.Equal(1, sender.Clears);
    }

    /// Kalkıp 1,5 sn içinde geri gelen satır çevirmene gitmeden eski çevirisiyle yeniden gösterilir.
    [Fact]
    public async Task LineReturningSoonAfterClearIsRestoredWithoutTranslating()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate.", 2), ("", 20), ("Hold the gate.", 2))),
            translator, sender, clock: clock.Read);
        var shown = 0;
        pipeline.PairShown += (_, _) => shown++;
        await Run(pipeline, 24, clock: clock);
        Assert.Equal(1, sender.Clears);
        Assert.Equal(["TR: Hold the gate.", "TR: Hold the gate."], sender.Sent);
        Assert.Equal([15000, 15000], sender.Durations);
        Assert.Single(translator.Requested);
        Assert.Equal(1, shown);
    }

    /// Daha geç gelen aynı satır gerçek bir tekrardır; yeniden çevrilir.
    [Fact]
    public async Task LineReturningLaterIsTranslatedAgain()
    {
        var clock = new TestClock();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate.", 2), ("", 50), ("Hold the gate.", 2))),
            translator, new FakeSender(), clock: clock.Read);
        await Run(pipeline, 54, clock: clock);
        Assert.Equal(2, translator.Requested.Count);
    }

    /// İki konuşmacı aynı sözlerle konuşuyor; ikisi de çevrilir.
    [Fact]
    public async Task TwoSpeakersWithOverlappingWordsAreBothTranslated()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Where are you going, boy?", 3), ("Where are you going?", 3))),
            new FakeTranslator(), sender, clock: clock.Read);
        await Run(pipeline, 6, clock: clock);
        Assert.Equal(["TR: Where are you going, boy?", "TR: Where are you going?"], sender.Sent);
    }

    /// Çeviri sürerken okuma durmamalı; yoksa kısa satırlar kaçar.
    [Fact]
    public async Task ReadingContinuesWhileTranslating()
    {
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate", "Hold the gate", "Run", "Run"), translator, new FakeSender());
        await Run(pipeline, 4, waitEach: false);
        translator.Open();
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["Hold the gate", "Run"], translator.Requested);
    }

    /// Hızlı konuşmada yeni satır gelse de önceki satırın çevirisi gösterilir; satır kaybolmaz.
    [Fact]
    public async Task EarlierLineIsShownWhenItsTranslationArrivesFirst()
    {
        var sender = new FakeSender();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate.", "Run!"), translator, sender);
        await Run(pipeline, 2, waitEach: false);
        await translator.Release("Hold the gate.");
        await WaitUntil(() => sender.Sent.Count == 1);
        await translator.Release("Run!");
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: Hold the gate.", "TR: Run!"], sender.Sent);
    }

    /// Hızlı konuşmada çeviri sürerken gelen satırlar sırayla çevrilir ve gösterilir; araya giren satır kaybolmaz
    /// (eskiden yalnız en yenisi bekliyordu: üç satırlık konuşmanın ortası hiç çevrilmiyordu).
    [Fact]
    public async Task FastLinesAreAllTranslatedInOrder()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate.", "Run!", "Get down!"), translator, sender, clock: clock.Read);
        await Run(pipeline, 3, waitEach: false, clock: clock);
        await translator.Release("Hold the gate.");
        await translator.Release("Run!");
        await translator.Release("Get down!");
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["Hold the gate.", "Run!", "Get down!"], translator.Requested);
        Assert.Equal(["TR: Hold the gate.", "TR: Run!", "TR: Get down!"], sender.Sent);
    }

    /// Sıra dolunca en eski bekleyen satır atlanır; kuyruk konuşma hızıyla büyümez.
    [Fact]
    public async Task OldestWaitingLineIsSkippedWhenTheQueueIsFull()
    {
        var clock = new TestClock();
        var translator = new GatedTranslator();
        string[] lines = ["Hold the gate.", "Run!", "Get down!", "Now!", "Over here!", "Go left!"];
        Assert.Equal(SubtitlePipeline.MaxWaiting + 2, lines.Length);
        var pipeline = new SubtitlePipeline(new FakeReader(lines), translator, new FakeSender(), clock: clock.Read);
        await Run(pipeline, lines.Length, waitEach: false, clock: clock);
        translator.Open();
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["Hold the gate.", "Get down!", "Now!", "Over here!", "Go left!"], translator.Requested);
    }

    /// Yavaş çeviride (ücretsiz motor) art arda üç satırın çevirisi satırlar kalktıktan iki saniye sonra gelse de
    /// üçü de gösterilir; eskiden yalnız ilki görünüyordu.
    [Fact]
    public async Task SlowTranslationsOfQuickLinesAreStillShown()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate.", "Run!", "Get down!"), translator, sender, clock: clock.Read);
        await Run(pipeline, 3, waitEach: false, clock: clock);
        clock.Now += 2000;
        await translator.Release("Hold the gate.");
        await translator.Release("Run!");
        await translator.Release("Get down!");
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: Hold the gate.", "TR: Run!", "TR: Get down!"], sender.Sent);
        Assert.Equal([SubtitlePipeline.ReadingTime("TR: Hold the gate."), SubtitlePipeline.ReadingTime("TR: Run!"), 15000], sender.Durations);
    }

    /// Daktilo efekti: yarım okunan cümlenin çevirisi sürerken tamamı gelirse yarımın çevirisi bırakılır, gösterilmez.
    [Fact]
    public async Task GrowingLineSupersedesItsPartialTranslation()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Run to", 2), ("Run to the boat!", 2))),
            translator, sender, clock: clock.Read);
        await Run(pipeline, 4, waitEach: false, clock: clock);
        await translator.Release("Run to the boat!");
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["Run to", "Run to the boat!"], translator.Requested);
        Assert.Equal(["TR: Run to the boat!"], sender.Sent);
    }

    /// Yarım satırın çevirisi gösterildikten sonra tamamı gelirse TV'ye "yerine koy" denir: aynı cümlenin iki çevirisi
    /// üst üste yığılmaz. Başka bir cümle yığılabilir.
    [Fact]
    public async Task RevisedLineReplacesTheShownTranslation()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(
            new FakeReader(Lines(("Run to", 2), ("Run to the boat!", 2), ("Get down now!", 2))),
            new FakeTranslator(), sender, clock: clock.Read);
        await Run(pipeline, 6, clock: clock);
        Assert.Equal(["TR: Run to", "TR: Run to the boat!", "TR: Get down now!"], sender.Sent);
        Assert.Equal([false, true, false], sender.Replaces);
    }

    /// Yeni satır gelmiş, eskisinin çevirisi geç gelse de yeni satırınkinden önce gösterilir (GitHub #893: yapay zekâ
    /// çevirisinde satırlar kayboluyordu).
    [Fact]
    public async Task LateTranslationOfReplacedLineIsShownBeforeTheNewOne()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate.", "Run!"), translator, sender, clock: clock.Read);
        await Run(pipeline, 2, waitEach: false, clock: clock);
        clock.Now += SubtitlePipeline.LateResultMs + 100;
        await translator.Release("Hold the gate.");
        await translator.Release("Run!");
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: Hold the gate.", "TR: Run!"], sender.Sent);
    }

    /// Yeni satır gelmiş, eskisinin çevirisi beklenebilecek en uzun süreden de geç gelmişse gösterilmez.
    [Fact]
    public async Task VeryLateTranslationOfReplacedLineIsDropped()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate.", "Run!"), translator, sender, clock: clock.Read);
        await Run(pipeline, 2, waitEach: false, clock: clock);
        clock.Now += SubtitlePipeline.QueuedLateResultMs + 100;
        await translator.Release("Hold the gate.");
        await translator.Release("Run!");
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: Run!"], sender.Sent);
    }

    /// Satır ekrandan kalktıktan sonra çevirisi gelirse yine de okunacak kadar kısa süre gösterilir.
    [Fact]
    public async Task TranslationArrivingAfterLineLeftIsShownBriefly()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate.", 1), ("", 17))), translator, sender, clock: clock.Read);
        await Run(pipeline, 18, waitEach: false, clock: clock);
        Assert.Equal(1, sender.Clears);
        translator.Open();
        await pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: Hold the gate."], sender.Sent);
        Assert.Equal(2000 + "TR: Hold the gate.".Length * 60, sender.Durations[0]);
    }

    /// Satır bir saniyeden uzun süre önce kalktıysa geç gelen çevirisi sonraki sahnenin üstüne düşmez.
    [Fact]
    public async Task TranslationArrivingLongAfterLineLeftIsDropped()
    {
        var sender = new FakeSender();
        var clock = new TestClock();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader(Lines(("Hold the gate.", 1), ("", 17))), translator, sender, clock: clock.Read);
        await Run(pipeline, 18, waitEach: false, clock: clock);
        Assert.Equal(1, sender.Clears);
        clock.Now += SubtitlePipeline.LateResultMs + 100;
        translator.Open();
        await pipeline.WaitForTranslationsAsync();
        Assert.Empty(sender.Sent);
    }

    /// Çeviri durdurulduysa geç gelen çeviri TV'ye gönderilmez.
    [Fact]
    public async Task TranslationArrivingAfterStopIsDropped()
    {
        var sender = new FakeSender();
        var translator = new GatedTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Hold the gate", "Hold the gate"), translator, sender);
        await Run(pipeline, 2, waitEach: false);
        pipeline.Reset();
        translator.Open();
        await pipeline.WaitForTranslationsAsync();
        Assert.Empty(sender.Sent);
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (!condition()) { Assert.True(DateTime.UtcNow < deadline); await Task.Delay(5); }
    }
}

/// <summary>
/// Parlak zeminde beyaz altyazı (It Takes Two, Duhan Ay, 2026-11-13): yazı tanıma ekranda duran altyazıyı saniyelerce
/// okuyamıyor, TV'deki Türkçe siliniyordu. Gerçek okuma planıyla (<see cref="ReadScheduler"/>) ve gerçek bölge iziyle.
/// </summary>
public class BrightBackgroundPipelineTests
{
    /// <summary>Altyazının bölgedeki yeri (bölgenin kenarlarına oranla).</summary>
    private static readonly TextBox SubtitleBox = new(0.3, 0.6, 0.7, 0.85);

    /// <summary>Parlak sahne; <paramref name="subtitle"/> ise altyazının yerinde siyah-beyaz harf deseni, <paramref name="upper"/> bölgenin üst yarısının parlaklığı (sahnede kıpırdayan şey).</summary>
    private static Frame Scene(bool subtitle, byte upper = 230)
    {
        var frame = Frame.Blank(640, 360);
        Array.Fill(frame.Pixels, (byte)230);
        var region = new CropRegion();
        int left = (int)Math.Floor(640 * region.Left), top = (int)Math.Floor(360 * region.Top);
        int width = (int)Math.Ceiling(640 * region.Right) - left, height = (int)Math.Ceiling(360 * region.Bottom) - top;
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                double rx = (double)x / width, ry = (double)y / height;
                byte? value = null;
                if (ry < 0.4) value = upper;
                else if (subtitle && rx >= SubtitleBox.Left && rx < SubtitleBox.Right && ry >= SubtitleBox.Top && ry < SubtitleBox.Bottom)
                    value = (byte)(x % 4 < 2 ? 255 : 0);
                if (value is not { } v) continue;
                var i = ((top + y) * frame.Stride) + ((left + x) * 4);
                frame.Pixels[i] = frame.Pixels[i + 1] = frame.Pixels[i + 2] = v;
            }
        return frame;
    }

    /// <summary>Altyazı karedeyse okur; <see cref="Miss"/> açıkken yazı tanıma kaçırır (boş döner).</summary>
    private sealed class BrightReader : ITextReader
    {
        public bool Miss { get; set; }
        public string Read(Frame image) => ReadLines(image, false).Text;
        public Reading ReadLines(Frame image, bool deep)
        {
            var hasSubtitle = image.Pixels.Any(b => b == 0);
            return hasSubtitle && !Miss ? new Reading([new TextLine("Hold the gate.", SubtitleBox)]) : Reading.Empty;
        }
    }

    private static async Task Feed(SubtitlePipeline pipeline, TestClock clock, Frame frame, int frames)
    {
        for (var i = 0; i < frames; i++)
        {
            await pipeline.ProcessAsync(frame, new CropRegion());
            await pipeline.WaitForTranslationsAsync();
            clock.Now += 50;
        }
    }

    /// <summary>
    /// Altyazı ekranda dururken yazı tanıma 2 sn kaçırıyor (sahnenin üstü kıpırdadı, kare yeniden okundu, okuma boş):
    /// altyazının yeri değişmediği için Türkçe silinmez, yeniden de çevrilmez.
    /// </summary>
    [Fact]
    public async Task MissedReadsOnAnUnchangedSubtitleKeepTheTranslation()
    {
        var clock = new TestClock();
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        var reader = new BrightReader();
        var pipeline = new SubtitlePipeline(reader, translator, sender, new ReadScheduler(), clock.Read);
        await Feed(pipeline, clock, Scene(subtitle: true), 3);
        Assert.Equal(["TR: Hold the gate."], sender.Sent);
        reader.Miss = true;
        await Feed(pipeline, clock, Scene(subtitle: true, upper: 120), 40);
        Assert.Equal(0, sender.Clears);
        reader.Miss = false;
        await Feed(pipeline, clock, Scene(subtitle: true, upper: 200), 3);
        Assert.Equal(0, sender.Clears);
        Assert.Equal(["TR: Hold the gate."], sender.Sent);
        Assert.Single(translator.Requested);
    }

    /// <summary>Altyazı gerçekten kalkınca (yeri değişti) Türkçe her zamanki sürede silinir.</summary>
    [Fact]
    public async Task SubtitleLeavingAnUnchangedSceneStillClearsPromptly()
    {
        var clock = new TestClock();
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new BrightReader(), new FakeTranslator(), sender, new ReadScheduler(), clock.Read);
        await Feed(pipeline, clock, Scene(subtitle: true), 3);
        await Feed(pipeline, clock, Scene(subtitle: false), SubtitleStabilizer.ClearAfterMs / 50);
        Assert.Equal(0, sender.Clears);
        await Feed(pipeline, clock, Scene(subtitle: false), 1);
        Assert.Equal(1, sender.Clears);
    }
}

public class ReadingFallbackTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    [Fact]
    public void ShortLinesGetAZoomedSecondReading()
    {
        var stripWidth = (int)Math.Round(64 * 0.4) * 2;
        var text = ReadingFallback.FirstReading(Image, candidate => candidate.Width == stripWidth ? "Go!" : "");
        Assert.Equal("Go!", text);
    }

    /// İki yedek okuma da yazı bulursa ortadaki şeridinki seçilir.
    [Fact]
    public void CenterStripReadingWinsOverZoomedRegion()
    {
        var text = ReadingFallback.FirstReading(Image, candidate => candidate.Width switch { 64 => "", 128 => "G0!", _ => "Go!" });
        Assert.Equal("Go!", text);
    }

    [Fact]
    public void FullReadingIsUsedWhenItFindsText()
    {
        var calls = 0;
        var text = ReadingFallback.FirstReading(Image, _ => { Interlocked.Increment(ref calls); return "Hold the gate"; });
        Assert.Equal("Hold the gate", text);
        Assert.Equal(1, calls);
    }

    /// Mac'teki gibi: yedek okumalar sırayla, aynı iş parçacığında yapılır (GitHub #587); şerit yazı bulursa bölgenin
    /// tamamı hiç büyütülmez.
    [Fact]
    public void FallbackReadingsRunOneAfterAnother()
    {
        var thread = Environment.CurrentManagedThreadId;
        var widths = new List<int>();
        var busy = 0;
        ReadingFallback.FirstReading(Image, candidate =>
        {
            Assert.Equal(1, Interlocked.Increment(ref busy));
            Assert.Equal(thread, Environment.CurrentManagedThreadId);
            widths.Add(candidate.Width);
            Interlocked.Decrement(ref busy);
            return "";
        });
        var stripWidth = (int)Math.Round(64 * 0.4) * 2;
        Assert.Equal([64, stripWidth, 128], widths);

        widths.Clear();
        ReadingFallback.FirstReading(Image, candidate => { widths.Add(candidate.Width); return candidate.Width == stripWidth ? "Go!" : ""; });
        Assert.Equal([64, stripWidth], widths);
    }

    /// Bölgenin tamamının büyütmesi Mac'teki gibi uzun kenarda 1920 pikselle sınırlanır (1440p pencerede 3686 genişlik
    /// yerine 1920).
    [Fact]
    public void WholeRegionZoomIsCappedLikeTheMac()
    {
        var small = ReadingFallback.ScaledForFallback(Frame.Blank(400, 100));
        Assert.Equal((800, 200), (small.Width, small.Height));
        var large = ReadingFallback.ScaledForFallback(Frame.Blank(1843, 504));
        Assert.Equal(1920, large.Width);
        Assert.Equal((int)(504 * (1920.0 / 1843)), large.Height);
        var huge = ReadingFallback.ScaledForFallback(Frame.Blank(3000, 600));
        Assert.Equal((3000, 600), (huge.Width, huge.Height));
    }
}

/// <summary>Boyutları dizisine uymayan kare (GitHub #587): piksel döngüleri dizinin dışına taşmaz, istisna atmaz.</summary>
public class InconsistentFrameTests
{
    public static TheoryData<int, int, int, int> Broken => new()
    {
        { 100, 40, 400, 100 * 40 * 4 - 1 },   // dizi bir bayt kısa
        { 100, 40, 512, 100 * 40 * 4 },       // satır aralığı büyük, dizi dolgusuz ayrılmış
        { 100, 40, 300, 100 * 40 * 4 },       // satır aralığı genişlikten kısa
        { -1, 40, 400, 16000 },
        { 100, -1, 400, 16000 },
    };

    [Theory]
    [MemberData(nameof(Broken))]
    public void BrokenFramesAreDetectedAndSkipped(int width, int height, int stride, int length)
    {
        var frame = new Frame(new byte[length], width, height, stride);
        Assert.False(frame.IsConsistent);
        Assert.Contains($"stride {stride}", frame.Layout);
        Assert.Same(frame, TextImage.WhiteTextOnly(frame));
        Assert.DoesNotContain(RegionCropper.Signature(frame), b => b != 0);
        if (width > 0 && height > 0)
        {
            Assert.Equal((width * 2, height * 2), (frame.Scaled(2).Width, frame.Scaled(2).Height));
            Assert.Equal(10, frame.Resized(10, 10).Width);
            Assert.Equal(width / 2, frame.Crop(0, 0, width / 2, height).Width);
            Assert.Equal(Reading.Empty, ReadingFallback.FirstLines(frame, _ => Reading.Empty));
        }
    }

    [Fact]
    public void PaddedAndEmptyFramesAreConsistent()
    {
        Assert.True(new Frame(new byte[(39 * 512) + 400], 100, 40, 512).IsConsistent);
        Assert.True(Frame.Blank(0, 0).IsConsistent);
        Assert.True(Frame.Blank(2560, 1440).IsConsistent);
        Assert.True(Frame.Blank(10, 10).Crop(20, 20, 5, 5).IsConsistent);
    }
}

public class RegionCropperTests
{
    [Fact]
    public void DefaultRegionCropsBottomCenterBand()
    {
        var cropped = RegionCropper.Crop(Frame.Blank(1920, 1080), new CropRegion());
        Assert.InRange(cropped.Width, 1382, 1384);
        Assert.InRange(cropped.Height, 378, 379);
    }

    [Fact]
    public void CropKeepsThePixelsOfTheRegion()
    {
        var image = Frame.Blank(10, 10);
        image.Pixels[(9 * image.Stride) + (9 * 4)] = 200; // sağ alt köşe, mavi kanal
        var cropped = RegionCropper.Crop(image, new CropRegion(0.5, 1, 0.5, 1));
        Assert.Equal(200, cropped.Pixels[((cropped.Height - 1) * cropped.Stride) + ((cropped.Width - 1) * 4)]);
    }
}
