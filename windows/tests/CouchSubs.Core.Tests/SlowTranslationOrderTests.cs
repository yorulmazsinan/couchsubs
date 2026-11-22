// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.Tests;

/// <summary>
/// GitHub #893: gelişmiş (yapay zekâ) çeviri açıkken bazı satırlar TV'ye hiç gitmiyordu. Çeviri satır başına bir iki
/// saniye sürüyor; ilk satırın çevirisi yenisi geldikten 2,5 sn sonra bitince atılıyor ya da yarıda bırakılıyordu.
/// Mac/iPhone (SlowTranslationOrderTests.swift) ve Android (SlowTranslationOrderTest.kt) aynı senaryoları sınar.
/// </summary>
public class SlowTranslationOrderTests
{
    private const string First = "Hold the gate.";
    private const string Second = "Run to the boat!";
    private static readonly Frame Image = Frame.Blank(64, 64);

    private sealed class Reader : ITextReader
    {
        public string Text = "";
        public string Read(Frame frame) => Text;
    }

    /// <summary>Yavaş yapay zekâ çevirisi: ilk satır bırakılana kadar bekler, diğerleri hemen döner.</summary>
    private sealed class SlowTranslator : ITextTranslator
    {
        private readonly object gate = new();
        private readonly TaskCompletionSource slow = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<string> Requested { get; } = [];
        public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            lock (gate) Requested.Add(text);
            if (text == First) await slow.Task.WaitAsync(cancellationToken);
            return "TR: " + text;
        }
        public void Release() => slow.TrySetResult();
    }

    private sealed class Scene
    {
        public readonly Reader Reader = new();
        public readonly SlowTranslator Translator = new();
        public readonly FakeSender Sender = new();
        public readonly TestClock Clock = new();
        public readonly SubtitlePipeline Pipeline;
        public Scene() => Pipeline = new(Reader, Translator, Sender, clock: Clock.Read) { CleanWait = 0 };
        public async Task Frame(string text, long time)
        {
            Reader.Text = text;
            Clock.Now = time;
            await Pipeline.ProcessAsync(Image, new CropRegion());
        }
    }

    [Fact]
    public async Task SlowFirstLineIsStillShownBeforeTheFasterNextOne()
    {
        var scene = new Scene();
        await scene.Frame(First, 0);
        await scene.Frame(Second, 1500);
        // İlk satır yenisi geldikten 2,6 sn sonra hâlâ çevriliyor: eskiden yarıda bırakılıyordu.
        await scene.Frame(Second, 1500 + SubtitlePipeline.LateResultMs + 100);
        scene.Clock.Now = 4500;
        scene.Translator.Release();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal([First, Second], scene.Translator.Requested);
        Assert.Equal(["TR: " + First, "TR: " + Second], scene.Sender.Sent);
    }

    [Fact]
    public async Task QueuedLastLineIsNotDroppedForTimeSpentWaiting()
    {
        var scene = new Scene();
        await scene.Frame(First, 0);
        await scene.Frame(Second, 500);
        for (var time = 600; time <= 2000; time += 100) await scene.Frame("", time);
        // Son satır kalktıktan 3 sn sonra sırası geldi; çevirisi hemen bitti, yine gösterilir.
        scene.Clock.Now = 5000;
        scene.Translator.Release();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: " + First, "TR: " + Second], scene.Sender.Sent);
    }

    [Fact]
    public async Task FirstLineIsGivenUpOnlyAfterTheQueuedLimit()
    {
        var scene = new Scene();
        await scene.Frame(First, 0);
        await scene.Frame(Second, 100);
        await scene.Frame(Second, 100 + SubtitlePipeline.QueuedLateResultMs + 1);
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Equal(["TR: " + Second], scene.Sender.Sent);
    }

    [Fact]
    public async Task LoneLineArrivingLongAfterItLeftIsStillDropped()
    {
        var scene = new Scene();
        await scene.Frame(First, 0);
        for (var time = 100; time <= 1500; time += 100) await scene.Frame("", time);
        scene.Clock.Now = 1500 + SubtitlePipeline.LateResultMs + 600;
        scene.Translator.Release();
        await scene.Pipeline.WaitForTranslationsAsync();
        Assert.Empty(scene.Sender.Sent);
    }
}
