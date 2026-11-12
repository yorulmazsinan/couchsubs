// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Translation.Tests;

public class MarianTranslatorTests
{
    /// <summary>Cümleyi büyük harfe çeviren, çağrıları sayan ve eşzamanlı girişi yakalayan sahte çekirdek.</summary>
    private sealed class FakeEngine : ISentenceEngine
    {
        private int _active;
        public List<string> Calls { get; } = [];
        public bool SawConcurrentCall { get; private set; }
        public bool Disposed { get; private set; }
        public int Delay { get; init; }
        /// <summary>Verilirse çeviri, test bunu açana kadar bekler (zamanlamaya bağlı olmayan testler için).</summary>
        public ManualResetEventSlim? Hold { get; init; }
        /// <summary>Verilirse çeviri budur; yoksa cümle büyük harfe çevrilir.</summary>
        public Func<string, string>? Map { get; init; }

        public string Translate(string sentence, CancellationToken cancellationToken)
        {
            if (Interlocked.Increment(ref _active) > 1) SawConcurrentCall = true;
            try
            {
                Hold?.Wait();
                if (Delay > 0) Thread.Sleep(Delay);
                lock (Calls) Calls.Add(sentence);
                return Map?.Invoke(sentence) ?? sentence.ToUpperInvariant();
            }
            finally
            {
                Interlocked.Decrement(ref _active);
            }
        }

        public void Dispose() => Disposed = true;
    }

    private static (MarianTranslator, FakeEngine) Create(int delay = 0)
    {
        var engine = new FakeEngine { Delay = delay };
        return (new MarianTranslator(() => engine, () => true), engine);
    }

    [Fact]
    public async Task SpokenLinesKeepTheirSpeakers()
    {
        var (translator, _) = Create();
        await translator.TranslateAsync("KRATOS: We go now. Stay close.\nATREUS: Okay.\n- Where?\n- Home.");
        var lines = translator.SpokenLines("KRATOS: We go now. Stay close.\nATREUS: Okay.\n- Where?\n- Home.");
        Assert.Equal(["KRATOS", "KRATOS", "ATREUS", null, null], lines.Select(line => line.Speaker));
        Assert.Equal([false, false, false, true, true], lines.Select(line => line.NewTurn));
        Assert.Equal("We go now.", lines[0].English);
        Assert.Equal("WE GO NOW.", lines[0].Turkish);
    }

    [Fact]
    public async Task CachesExactInput()
    {
        var (translator, engine) = Create();

        Assert.Equal("WAIT!", await translator.TranslateAsync("Wait!"));
        Assert.Equal("WAIT!", await translator.TranslateAsync("Wait!"));
        Assert.Single(engine.Calls);

        // Önbellek tam metne bakar; harf farkı yeni çeviridir.
        await translator.TranslateAsync("wait!");
        Assert.Equal(2, engine.Calls.Count);
    }

    [Fact]
    public async Task ReusesCachedSentencesAcrossLines()
    {
        var (translator, engine) = Create();

        await translator.TranslateAsync("We go to the mountain now. Stay behind me, boy.");
        Assert.Equal("WE GO TO THE MOUNTAIN NOW. STAY BEHIND ME, BOY. KEEP YOUR EYES OPEN.",
            await translator.TranslateAsync("We go to the mountain now. Stay behind me, boy. Keep your eyes open."));
        Assert.Equal(["We go to the mountain now.", "Stay behind me, boy.", "Keep your eyes open."], engine.Calls);
    }

    [Fact]
    public async Task KeepsLabelsAndSkipsPunctuationOnly()
    {
        var (translator, engine) = Create();

        Assert.Equal("ATREUS: FATHER, LOOK!\nKRATOS: STAY.", await translator.TranslateAsync("ATREUS: Father, look!\nKRATOS: Stay."));
        Assert.Equal("...", await translator.TranslateAsync("..."));
        // "Stay." kısa: aynı satırdaki önceki cümleyle birlikte çevrilir.
        Assert.Equal(["Father, look!", "Father, look! *** Stay."], engine.Calls);
    }

    [Fact]
    public async Task NamesFromLabelsStayCapitalizedInLaterSentences()
    {
        var (translator, engine) = Create();

        await translator.TranslateAsync("ATREUS: Father, look!");
        await translator.TranslateAsync("THE GATE WILL NOT HOLD, ATREUS.");
        Assert.Equal("The gate will not hold, Atreus.", engine.Calls[^1]);
    }

    /// <summary>Önceki oturumda çevrilen satır model çalışmadan döner; seslendirme cümleleri de konuşmacısıyla kurulur.</summary>
    [Fact]
    public async Task PersistentCacheSkipsTheModelInTheNextSession()
    {
        var file = Path.Combine(Path.GetTempPath(), "couchsubs-marian-" + Guid.NewGuid().ToString("N"), "cache.jsonl");
        try
        {
            var firstEngine = new FakeEngine();
            await new MarianTranslator(() => firstEngine, () => true, new TranslationCache(file))
                .TranslateAsync("KRATOS: We go now. Stay close.");

            var engine = new FakeEngine();
            var translator = new MarianTranslator(() => engine, () => true, new TranslationCache(file));
            // Kısa cümle bağlamıyla önbellekte: "Stay close." aynı önceki cümleyle yine modelsiz döner.
            Assert.Equal("KRATOS: WE GO NOW. STAY CLOSE.", await translator.TranslateAsync("KRATOS: We go now. Stay close."));
            Assert.Equal("WE GO NOW. RUN TO THE BOAT, BOY!", await translator.TranslateAsync("We go now. Run to the boat, boy!"));
            Assert.Equal(["Stay close. *** We go now.", "Run to the boat, boy!"], engine.Calls);
            var lines = translator.SpokenLines("KRATOS: We go now. Stay close.");
            Assert.Equal(["KRATOS", "KRATOS"], lines.Select(line => line.Speaker));
            Assert.Equal("STAY CLOSE.", lines[1].Turkish);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(file)!, recursive: true);
        }
    }

    /// <summary>Konuşmacı adı çevrilmez, cümle içinde de ad olarak kalır (Mac: SubtitleTextTests ve Translator ile aynı).</summary>
    [Theory]
    [InlineData("ATREUS: Father!", "ATREUS: FATHER!", "Father!")]
    [InlineData("OLD MAN: Who goes there?", "OLD MAN: WHO GOES THERE?", "Who goes there?")]
    [InlineData("Mimir Head: Brother, wait.", "Mimir Head: BROTHER, WAIT.", "Brother, wait.")]
    [InlineData("Note: Press X.", "NOTE: PRESS X.", "Note: Press X.")]
    public async Task SpeakerNamesAreNotTranslated(string source, string expected, string sent)
    {
        var (translator, engine) = Create();
        Assert.Equal(expected, await translator.TranslateAsync(source));
        Assert.Equal([sent], engine.Calls);
    }

    [Fact]
    public async Task MultiWordNamesStayCapitalizedInLaterSentences()
    {
        var (translator, engine) = Create();
        await translator.TranslateAsync("OLD MAN: Hello.");
        await translator.TranslateAsync("RUN, OLD MAN!");
        Assert.Equal("Hello. *** Run, Old Man!", engine.Calls[^1]);
    }

    [Fact]
    public async Task ThrowsNeedsDownloadWhenModelMissing()
    {
        var created = false;
        var translator = new MarianTranslator(() => { created = true; return new FakeEngine(); }, () => false);

        Assert.Equal(TranslatorStatus.NeedsDownload, translator.Status);
        var error = await Assert.ThrowsAsync<TranslatorException>(() => translator.TranslateAsync("Wait!"));
        Assert.Equal(TranslatorStatus.NeedsDownload, error.Status);
        Assert.False(created);
    }

    [Fact]
    public async Task RealConstructorReportsMissingFiles()
    {
        var dir = Path.Combine(Path.GetTempPath(), "couchsubs-empty-" + Guid.NewGuid().ToString("N"));
        using var translator = new MarianTranslator(dir);

        Assert.Equal(TranslatorStatus.NeedsDownload, translator.Status);
        var error = await Assert.ThrowsAsync<TranslatorException>(() => translator.TranslateAsync("Wait!"));
        Assert.Equal(TranslatorStatus.NeedsDownload, error.Status);
    }

    /// <summary>Windows'ta onnxruntime.dll yüklenemeyince SessionOptions'ın tür başlatıcısı böyle düşer (hata.log, beta.27).</summary>
    private static Exception OnnxLoadFailure() =>
        new TypeInitializationException("Microsoft.ML.OnnxRuntime.NativeMethods",
            new DllNotFoundException("Unable to load DLL 'onnxruntime' or one of its dependencies (0x8007007E)"));

    [Fact]
    public async Task EngineThatCannotLoadReportsEngineFailedOnce()
    {
        var attempts = 0;
        var translator = new MarianTranslator(() => { attempts++; throw OnnxLoadFailure(); }, () => true);
        var reported = new List<Exception>();
        translator.EngineFailed += reported.Add;

        var error = await Assert.ThrowsAsync<TranslatorException>(() => translator.TranslateAsync("Wait!"));
        Assert.Equal(TranslatorStatus.EngineFailed, error.Status);
        Assert.IsType<TypeInitializationException>(error.InnerException);
        Assert.Equal(TranslatorStatus.EngineFailed, translator.Status);

        // Sonraki satırlar motoru yeniden açmaya çalışmaz, aynı durumu söyler; bildirim bir kez gelir.
        var again = await Assert.ThrowsAsync<TranslatorException>(() => translator.TranslateAsync("Run, boy!"));
        Assert.Equal(TranslatorStatus.EngineFailed, again.Status);
        Assert.Equal(1, attempts);
        Assert.IsType<TypeInitializationException>(Assert.Single(reported));
    }

    /// Arka planda başlatılıp beklenmeyen ısınma görevi hata bırakmamalı (UnobservedTaskException olarak hata.log'a düşüyordu).
    [Fact]
    public async Task WarmUpDoesNotFaultWhenEngineCannotLoad()
    {
        var translator = new MarianTranslator(() => throw OnnxLoadFailure(), () => true);
        var reported = 0;
        translator.EngineFailed += _ => reported++;

        var warmUp = translator.WarmUpAsync();
        await warmUp;

        Assert.True(warmUp.IsCompletedSuccessfully);
        Assert.Equal(1, reported);
        Assert.Equal(TranslatorStatus.EngineFailed, translator.Status);
    }

    [Fact]
    public async Task WarmUpDoesNotFaultWhenModelMissing()
    {
        var translator = new MarianTranslator(() => new FakeEngine(), () => false);
        var reported = 0;
        translator.EngineFailed += _ => reported++;

        await translator.WarmUpAsync();

        Assert.Equal(0, reported);
        Assert.Equal(TranslatorStatus.NeedsDownload, translator.Status);
    }

    /// Önbellekteki satırlar motor açılamasa da gösterilir.
    [Fact]
    public async Task CachedLinesStillTranslateWhenEngineCannotLoad()
    {
        var file = Path.Combine(Path.GetTempPath(), "couchsubs-marian-" + Guid.NewGuid().ToString("N"), "cache.jsonl");
        try
        {
            var engine = new FakeEngine();
            await new MarianTranslator(() => engine, () => true, new TranslationCache(file)).TranslateAsync("We go now.");

            var broken = new MarianTranslator(() => throw OnnxLoadFailure(), () => true, new TranslationCache(file));
            Assert.Equal("WE GO NOW.", await broken.TranslateAsync("We go now."));
            var error = await Assert.ThrowsAsync<TranslatorException>(() => broken.TranslateAsync("Stay close."));
            Assert.Equal(TranslatorStatus.EngineFailed, error.Status);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(file)!, recursive: true);
        }
    }

    [Fact]
    public async Task SerializesConcurrentCalls()
    {
        var (translator, engine) = Create(delay: 5);
        // Dört sözcük ve üstü: kısa satırın bağlamı paralel sırada değişirdi.
        var lines = Enumerable.Range(0, 40).Select(i => $"This is line number {i % 10}.").ToArray();

        var results = await Task.WhenAll(lines.Select(l => Task.Run(() => translator.TranslateAsync(l))));

        Assert.Equal(lines.Select(l => l.ToUpperInvariant()), results);
        Assert.False(engine.SawConcurrentCall);
        // Aynı cümle beklerken başkası çevirdiyse tekrar çevrilmez.
        Assert.Equal(10, engine.Calls.Count);
    }

    [Fact]
    public async Task HonorsCancellationWhileWaiting()
    {
        // Süreye değil açık iptale dayanır: yoğun makinede zamanlayıcı geç tetiklenebiliyor.
        using var hold = new ManualResetEventSlim(false);
        var engine = new FakeEngine { Hold = hold };
        var translator = new MarianTranslator(() => engine, () => true);
        var first = translator.TranslateAsync("Slow line.");
        using var cts = new CancellationTokenSource();
        var second = translator.TranslateAsync("Other line.", cts.Token);
        Assert.False(second.IsCompleted);

        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => second);
        hold.Set();
        Assert.Equal("SLOW LINE.", await first);
    }

    [Fact]
    public async Task DisposeReleasesEngine()
    {
        var (translator, engine) = Create();
        await translator.TranslateAsync("Wait for me at the boat.");

        translator.Dispose();

        Assert.True(engine.Disposed);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => translator.TranslateAsync("This is a new line."));
        // Önbellekteki satır hâlâ döner; motor gerekmez.
        Assert.Equal("WAIT FOR ME AT THE BOAT.", await translator.TranslateAsync("Wait for me at the boat."));
    }

    [Fact]
    public void EngineUsesAtMostTwoThreads()
    {
        Assert.Equal(1, OnnxMarianEngine.IntraOpThreads(1));
        Assert.Equal(2, OnnxMarianEngine.IntraOpThreads(4));
        Assert.Equal(2, OnnxMarianEngine.IntraOpThreads(16));
        Assert.Equal(2, OnnxMarianEngine.MaxIntraOpThreads);
    }

    [Fact]
    public void CacheFileNameCarriesThePipelineVersion() =>
        Assert.Equal("opus-mt-p" + FreeTranslation.PipelineVersion, MarianTranslator.EngineId);

    [Fact]
    public async Task ShortLineIsTranslatedWithThePreviousLine()
    {
        var engine = new FakeEngine
        {
            Map = s => s switch
            {
                "Where is your mother?" => "Annen nerede?",
                "Where is your mother? *** Not you." => "Annen nerede? *** Sen değil.",
                _ => "?",
            },
        };
        var translator = new MarianTranslator(() => engine, () => true);
        await translator.TranslateAsync("Where is your mother?");
        Assert.Equal("Sen değil.", await translator.TranslateAsync("Not you."));
        // Yeniden okunan satır aynı bağlamla önbellekten gelir.
        Assert.Equal("Sen değil.", await translator.TranslateAsync("Not you."));
        Assert.Equal(2, engine.Calls.Count);
    }

    [Fact]
    public async Task ShortLineAfterALongPauseHasNoContext()
    {
        var now = DateTimeOffset.UnixEpoch;
        var engine = new FakeEngine();
        var translator = new MarianTranslator(() => engine, () => true, clock: () => now);
        await translator.TranslateAsync("Where is your mother?");
        now += TimeSpan.FromMinutes(1);
        await translator.TranslateAsync("Not you.");
        Assert.Equal(["Where is your mother?", "Not you."], engine.Calls);
    }

    [Fact]
    public async Task AmbiguousContextFallsBackToTheLineAlone()
    {
        var engine = new FakeEngine { Map = s => s.Contains("***") ? "Annen nerede sen değil" : "Sen değil." };
        var translator = new MarianTranslator(() => engine, () => true);
        await translator.TranslateAsync("Where is your mother?");
        Assert.Equal("Sen değil.", await translator.TranslateAsync("Not you."));
    }

    [Fact]
    public async Task GlossaryTermsGetTheirTurkishAndSuffix()
    {
        var directory = Path.Combine(Path.GetTempPath(), "couchsubs-glossary-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(Path.Combine(directory, "gow.json"),
                """{ "game": "God of War", "terms": { "Leviathan Axe": "Leviathan Baltası" }, "keep": ["Kratos"] }""");
            var engine = new FakeEngine
            {
                Map = s => s == "Zarmon, throw the Velkor!" ? "Zarmon, Velkor'u fırlat." : "?",
            };
            var translator = new MarianTranslator(() => engine, () => true, glossary: new GlossaryStore(directory));
            Assert.Equal("Kratos, Leviathan Baltası'nı fırlat!", await translator.TranslateAsync("KRATOS, THROW THE LEVIATHAN AXE!"));
            Assert.Equal(["Zarmon, throw the Velkor!"], engine.Calls);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task InformalLineGetsInformalImperatives()
    {
        var engine = new FakeEngine
        {
            Map = s => s switch
            {
                "I told you to wait for me." => "Sana beni beklemeni söyledim.",
                "I told you to wait for me. *** Stay here!" => "Sana beni beklemeni söyledim. *** Burada bekleyin!",
                _ => "?",
            },
        };
        var translator = new MarianTranslator(() => engine, () => true);
        Assert.Equal("Sana beni beklemeni söyledim. Burada bekle!", await translator.TranslateAsync("I told you to wait for me. Stay here!"));
        var lines = translator.SpokenLines("I told you to wait for me. Stay here!");
        Assert.Equal("Burada bekle!", lines[1].Turkish);
    }
}
