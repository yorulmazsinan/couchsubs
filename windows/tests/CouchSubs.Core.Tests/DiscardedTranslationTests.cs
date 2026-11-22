// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.Tests;

/// <summary>Yalnız zaten gösterilemeyecek üretim bırakılır; okunabilir satırların sırası korunur.</summary>
public class DiscardedTranslationTests
{
    private const string Old = "Hold the gate.";
    private const string Next = "Run!";
    /// <summary>Eski satır yenisi geldikten (100 ms) sonra beklenebilecek en uzun süreyi aştı (GitHub #893).</summary>
    private const int Expired = 100 + SubtitlePipeline.QueuedLateResultMs + 1;
    private static readonly Frame Image = Frame.Blank(64, 64);
    // Süreler yalnız takılmayı yakalar; yüklü CI'da yavaş kalmak testi düşürmesin.
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(30);

    // Test bir havuz iş parçacığını bilerek tutar; havuz yavaş büyüyüp paralel testleri aç bırakmasın.
    static DiscardedTranslationTests()
    {
        ThreadPool.GetMinThreads(out var worker, out var io);
        ThreadPool.SetMinThreads(Math.Max(worker, 32), io);
    }

    private sealed class Reader : ITextReader
    {
        public string Text = Old;
        public string Read(Frame frame) => Text;
    }

    private sealed class Call(string text, CancellationToken token)
    {
        public string Text { get; } = text;
        public CancellationToken Token { get; } = token;
        public TaskCompletionSource<string> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class Translator(bool honorsCancellation) : ITextTranslator
    {
        private readonly object gate = new();
        private readonly List<Call> calls = [];
        private bool open;
        public Action? OnCancel { get; set; }
        public Call[] Calls { get { lock (gate) return calls.ToArray(); } }
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            lock (gate)
            {
                var call = new Call(text, cancellationToken);
                calls.Add(call);
                if (OnCancel is { } cancelled) cancellationToken.Register(cancelled);
                if (open) call.Result.TrySetResult("TR: " + text);
                return honorsCancellation ? call.Result.Task.WaitAsync(cancellationToken) : call.Result.Task;
            }
        }
        public void Open()
        {
            lock (gate)
            {
                open = true;
                foreach (var call in calls) call.Result.TrySetResult("TR: " + call.Text);
            }
        }
    }

    private sealed class Scene(bool honorsCancellation = true) : IAsyncDisposable
    {
        public readonly Reader Reader = new();
        public readonly Translator Translator = new(honorsCancellation);
        public readonly FakeSender Sender = new();
        public readonly TestClock Clock = new();
        private SubtitlePipeline? pipeline;
        public SubtitlePipeline Pipeline => pipeline ??= new(Reader, Translator, Sender, clock: Clock.Read);
        public async Task Frame(string text, long time)
        {
            Reader.Text = text;
            Clock.Now = time;
            await Pipeline.ProcessAsync(Image, new CropRegion());
        }
        public async Task WaitForCalls(int count)
        {
            var deadline = DateTime.UtcNow + Patience;
            while (Translator.Calls.Length < count)
            {
                Assert.True(DateTime.UtcNow < deadline, "Yeni replik eski üretimin bitmesini bekliyor.");
                await Task.Delay(5);
            }
        }
        public async ValueTask DisposeAsync()
        {
            Translator.Open();
            await Pipeline.WaitForTranslationsAsync().WaitAsync(Patience);
        }
    }

    [Fact]
    public async Task ExpiredTranslationReleasesWaitingLineWithoutWaitingForItsResult()
    {
        await using var scene = new Scene();
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Next, 100 + SubtitlePipeline.QueuedLateResultMs + 1);
        await scene.WaitForCalls(2);
        Assert.True(scene.Translator.Calls[0].Token.IsCancellationRequested);
        Assert.False(scene.Translator.Calls[0].Result.Task.IsCompleted);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: " + Next], scene.Sender.Sent);
        Assert.Null(scene.Pipeline.LastError);
    }

    [Theory]
    [InlineData(2000)]
    [InlineData(SubtitlePipeline.LateResultMs)]
    public async Task GracePeriodPreservesBothLines(int elapsed)
    {
        await using var scene = new Scene();
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Next, 100 + elapsed);
        Assert.False(scene.Translator.Calls[0].Token.IsCancellationRequested);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: " + Old, "TR: " + Next], scene.Sender.Sent);
    }

    [Fact]
    public async Task StillVisibleLineIsNotCancelledHoweverLongItsProductionTakes()
    {
        await using var scene = new Scene();
        await scene.Frame(Old, 0);
        await scene.Frame(Old, 10000);
        Assert.False(scene.Translator.Calls[0].Token.IsCancellationRequested);
    }

    [Fact]
    public async Task LineRestoredWithinRestoreWindowKeepsItsProduction()
    {
        await using var scene = new Scene();
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Old, 1000);
        Assert.False(scene.Translator.Calls[0].Token.IsCancellationRequested);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Contains("TR: " + Old, scene.Sender.Sent);
    }

    [Fact]
    public async Task NoNewWaitingLineDoesNotCancelExpiredWork()
    {
        await using var scene = new Scene();
        await scene.Frame(Old, 0);
        for (var time = 100; time <= 2000; time += 100) await scene.Frame("", time);
        await scene.Frame("", 10000);
        Assert.False(scene.Translator.Calls[0].Token.IsCancellationRequested);
    }

    [Fact]
    public async Task ExpiredWaitingLineDoesNotJustifyCancellation()
    {
        await using var scene = new Scene();
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        // Tek uzun ara: boş okuma doğrulanınca hem eski hem sıradaki satır süreyi aşmış olacak.
        for (var time = 200; time <= 2000; time += 100) await scene.Frame("", time);
        await scene.Frame("", 10000);
        Assert.False(scene.Translator.Calls[0].Token.IsCancellationRequested);
    }

    [Fact]
    public async Task IgnoredCancellationDoesNotStartConcurrentWorkOrPublishOldResult()
    {
        await using var scene = new Scene(honorsCancellation: false);
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Next, Expired);
        Assert.True(scene.Translator.Calls[0].Token.IsCancellationRequested);
        Assert.Single(scene.Translator.Calls);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal([Old, Next], scene.Translator.Calls.Select(c => c.Text));
        Assert.Equal(["TR: " + Next], scene.Sender.Sent);
    }

    [Fact]
    public async Task NewerDisplayedPackLineCancelsUndisplayableProduction()
    {
        await using var scene = new Scene();
        scene.Pipeline.CleanWait = 0;
        scene.Pipeline.PackLookup = text => text == Next ? new PackMatch("Koş!", []) : null;
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        Assert.True(scene.Translator.Calls[0].Token.IsCancellationRequested);
        await scene.Pipeline.WaitForTranslationsAsync().WaitAsync(Patience);
        Assert.Equal(["Koş!"], scene.Sender.Sent);
        Assert.Null(scene.Pipeline.LastError);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task AbandonedSourceCanReturnAndBeTranslatedAgain(bool honorsCancellation)
    {
        await using var scene = new Scene(honorsCancellation);
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Next, Expired);
        await scene.Frame(Old, Expired + 100);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal([Old, Next, Old], scene.Translator.Calls.Select(c => c.Text));
        Assert.Equal(["TR: " + Next, "TR: " + Old], scene.Sender.Sent);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task PackCancellationDoesNotTrapRestoredSource(bool honorsCancellation)
    {
        await using var scene = new Scene(honorsCancellation);
        scene.Pipeline.PackLookup = text => text == Next ? new PackMatch("Koş!", []) : null;
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Old, 200); // Kararlayıcının Restore yolu (1500 ms içinde).
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal([Old, Old], scene.Translator.Calls.Select(c => c.Text));
        Assert.Equal(["Koş!", "TR: " + Old], scene.Sender.Sent);
    }

    [Fact]
    public async Task PackResultThatWasNotDisplayedDoesNotCancelOldLine()
    {
        await using var scene = new Scene();
        scene.Pipeline.PackLookup = text => text == Next ? new PackMatch(Next, []) : null;
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        Assert.Empty(scene.Sender.Sent);
        Assert.False(scene.Translator.Calls[0].Token.IsCancellationRequested);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: " + Old], scene.Sender.Sent);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task HeldReadingResolvedByPackDoesNotSuppressReturningAbandonedSource(bool honorsCancellation)
    {
        await using var scene = new Scene(honorsCancellation);
        var packReady = false;
        scene.Pipeline.PackLookup = text => packReady && text == "Get down" ? new PackMatch("Yere yat!", []) : null;
        await scene.Frame(Old, 0);
        await scene.Frame("Get down", 100);
        await scene.Frame("Get down", 150); // Noktalamasız okuma bekletiliyor, lastSent hâlâ Old.
        packReady = true;
        await scene.Frame("Get down", 200); // held + StabilizerKind.None dalından ShowPacked.
        Assert.Equal(["Yere yat!"], scene.Sender.Sent);
        Assert.True(scene.Translator.Calls[0].Token.IsCancellationRequested);
        await scene.Frame(Old, 250);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal([Old, Old], scene.Translator.Calls.Select(c => c.Text));
        Assert.Equal(["Yere yat!", "TR: " + Old], scene.Sender.Sent);
    }

    [Fact]
    public async Task CancellationCallbacksRunOutsidePipelineGate()
    {
        await using var scene = new Scene();
        var gateAvailable = false;
        scene.Translator.OnCancel = () =>
        {
            // WaitForTranslationsAsync, ilk await öncesinde gate'i alır; callback sırasında erişebilmeli.
            gateAvailable = Task.Run(() => { _ = scene.Pipeline.WaitForTranslationsAsync(); })
                .Wait(TimeSpan.FromSeconds(1));
        };
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Next, Expired);
        Assert.True(gateAvailable);
        await scene.WaitForCalls(2);
    }

    [Fact]
    public async Task AbandonedFailureDoesNotReportErrorOrRetryIt()
    {
        await using var scene = new Scene(honorsCancellation: false);
        var reported = new List<TranslatorStatus?>();
        scene.Pipeline.TranslationResult += reported.Add;
        await scene.Frame(Old, 0);
        await scene.Frame(Next, 100);
        await scene.Frame(Next, Expired);
        scene.Translator.Calls[0].Result.SetException(new TranslatorException(TranslatorStatus.EngineFailed));
        await scene.WaitForCalls(2);
        Assert.Empty(reported);
        Assert.Null(scene.Pipeline.LastError);
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: " + Next], scene.Sender.Sent);
        Assert.Null(Assert.Single(reported));
    }

    [Fact]
    public async Task AlreadyPublishedResultIsNotAbandonedBeforePumpAdvances()
    {
        await using var scene = new Scene();
        using var releaseEvent = new ManualResetEventSlim();
        var published = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        scene.Pipeline.PairShown += (source, _) =>
        {
            if (source != Old) return;
            published.TrySetResult();
            Assert.True(releaseEvent.Wait(Patience));
        };
        try
        {
            await scene.Frame(Old, 0);
            await scene.Frame(Next, 100);
            scene.Translator.Calls[0].Result.SetResult("TR: " + Old);
            await published.Task.WaitAsync(Patience);
            await scene.Frame(Next, Expired);
            Assert.False(scene.Translator.Calls[0].Token.IsCancellationRequested);
        }
        finally { releaseEvent.Set(); }
        scene.Translator.Open();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: " + Old, "TR: " + Next], scene.Sender.Sent);
    }
}
