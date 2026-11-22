// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core.Tests;

/// <summary>
/// Görüntü kaynağı OBS'in Program projektörü: karede CouchSubs'ın OBS katmanındaki Türkçe altyazı da var (X bildirimi,
/// capture card + OBS). Mac/iPhone OwnSubtitleTests ve Android OwnSubtitlesTest ile aynı senaryolar.
/// </summary>
public class OwnSubtitleTests
{
    private const string English = "You shouldn't have done that, Lucia.";
    private const string Turkish = "Bunu yapmamalıydın, Lucia. Çok üzgünüm.";
    private const string Next = "Get in the car, now.";
    private const string NextTurkish = "Hemen arabaya bin.";

    /// <summary>OBS projektörü: gönderilen çeviri ekrandayken okuyucu onu da (Türkçe harfleri bozulmuş) okur.</summary>
    private sealed class ProjectorScreen(bool covers) : ISubtitleSender, ITextReader
    {
        public string English { get; set; } = OwnSubtitleTests.English;
        public string? Shown { get; private set; }
        public List<string> Sent { get; } = [];
        public int Clears { get; private set; }

        public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false)
        {
            lock (Sent) { Sent.Add(text); Shown = text; }
        }
        public void Clear() { Clears++; Shown = null; }

        public static string Ocr(string text) => new(text.Select(c => c switch
        {
            'ı' => 'i', 'ş' => 's', 'ğ' => 'g', 'ç' => 'c', 'ö' => 'o', 'ü' => 'u',
            'İ' => 'I', 'Ş' => 'S', 'Ç' => 'C', 'Ö' => 'O', 'Ü' => 'U', 'Ğ' => 'G', _ => c,
        }).ToArray());

        public Reading Frame
        {
            get
            {
                var english = new TextLine(English, new TextBox(0.2, 0.40, 0.8, 0.60));
                if (Shown is not { } shown) return new Reading([english]);
                var own = new TextLine(Ocr(shown), new TextBox(0.18, covers ? 0.38 : 0.70, 0.82, covers ? 0.62 : 0.92));
                return new Reading(covers ? [own] : [english, own]);
            }
        }

        public string Read(Frame image) => Frame.Text;
        public Reading ReadLines(Frame image, bool deep) => Frame;
    }

    private sealed class Table : ITextTranslator
    {
        public List<string> Requested { get; } = [];
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            lock (Requested) Requested.Add(text);
            return Task.FromResult(text == English ? Turkish : text == Next ? NextTurkish : "Çeviri: " + text);
        }
    }

    /// <summary>Karenin izi satırla değişir (kararlayıcı aynı izli boş okumayı "satır duruyor" sayar).</summary>
    private static Frame Image(string text) =>
        new(Enumerable.Repeat((byte)(text.Length % 7 * 36), 64 * 64 * 4).ToArray(), 64, 64, 256);

    private static async Task<(ProjectorScreen Screen, Table Translator, List<string> Log)> Run(bool covers, int frames = 60,
        Func<int, string?>? script = null)
    {
        long clock = 0;
        var screen = new ProjectorScreen(covers);
        var translator = new Table();
        var log = new List<string>();
        var pipeline = new SubtitlePipeline(screen, translator, screen, clock: () => clock)
        { PackWait = 0, CleanWait = 0, Log = log.Add };
        for (var i = 0; i < frames; i++)
        {
            if (script?.Invoke(i) is { } line) screen.English = line;
            await pipeline.ProcessAsync(Image(screen.English), new CropRegion());
            await pipeline.WaitForTranslationsAsync();
            clock += 100;
        }
        return (screen, translator, log);
    }

    /// <summary>Örtme: okunan tek satır kendi çevirimizdir; önceden yeniden çevriliyor, altyazı yanıp sönüyordu.</summary>
    [Fact]
    public async Task OwnSubtitleCoveringTheLineIsNotReadAsANewLine()
    {
        var (screen, translator, log) = await Run(covers: true);
        Assert.Equal([English], translator.Requested);
        Assert.Equal([Turkish], screen.Sent);
        Assert.Equal(0, screen.Clears);
        Assert.Contains(log, line => line.Contains("kendi altyazısı"));
    }

    [Fact]
    public async Task OwnSubtitleBelowTheLineIsIgnored()
    {
        var (screen, translator, _) = await Run(covers: false);
        Assert.Equal([English], translator.Requested);
        Assert.Equal([Turkish], screen.Sent);
        Assert.Equal(0, screen.Clears);
    }

    [Fact]
    public async Task LineLeavingAndNextLineStillWorkBesideOwnSubtitle()
    {
        var (screen, translator, _) = await Run(covers: false, frames: 90, script: i => i == 30 ? "" : i == 45 ? Next : null);
        Assert.Equal([English, Next], translator.Requested);
        Assert.Equal([Turkish, NextTurkish], screen.Sent);
        Assert.Equal(1, screen.Clears);
    }

    [Fact]
    public void EnglishLineIsNeverTakenForOwnSubtitle()
    {
        long time = 0;
        var own = new OwnSubtitles(() => time);
        var lucia = new Reading([new TextLine("Lucia, Jason!", new TextBox(0.3, 0.8, 0.7, 0.9))]);
        Assert.Same(lucia, own.Split(lucia).Kept);
        own.Record("Lucia, Jason! Buraya gelin.", "Lucia, Jason! Come here.", 15000);
        time += 500;
        Assert.Empty(own.Split(lucia).Own);
        Assert.False(own.IsOwn("Lucia, Jason! Come here."));
        Assert.False(own.IsOwn("Come here, Lucia."));
        Assert.True(own.IsOwn("Lucia, Jason! Buraya gelin."));
        time += 15000 + OwnSubtitles.TextGraceMs + 1;
        Assert.False(own.IsOwn("Lucia, Jason! Buraya gelin."));
    }

    [Fact]
    public void WrappedAndGarbledOwnRowsAreDropped()
    {
        long time = 0;
        var own = new OwnSubtitles(() => time);
        own.Record("Bunu yapmamalıydın Lucia, şimdi hepimiz büyük bir belanın içindeyiz.",
                   "You shouldn't have done that, Lucia. Now we're all in big trouble.", 15000);
        time += 300;
        var first = new TextLine("Bunu yapmamaliydin Lucia, simdi", new TextBox(0.3, 0.80, 0.7, 0.85));
        var hint = new TextLine("Press X to skip", new TextBox(0.02, 0.94, 0.15, 0.97));
        var clean = own.Split(new Reading([first, new TextLine("hepimiz buyuk bir belanin icindeyiz.", new TextBox(0.31, 0.86, 0.69, 0.91)), hint]));
        Assert.Equal(["Press X to skip"], clean.Kept.Lines.Select(line => line.Text));
        var reading = new Reading([first, new TextLine("h3p!miz bvyvk b1r be!anin", new TextBox(0.32, 0.86, 0.68, 0.91)), hint]);
        var (kept, dropped) = own.Split(reading);
        Assert.Equal(["Press X to skip"], kept.Lines.Select(line => line.Text));
        Assert.Equal(2, dropped.Count);
        Assert.True(own.IsOwn("hepimiz büyük bir belanın içindeyiz."));
        Assert.True(OwnSubtitles.CoversLine(dropped, new TextBox(0.3, 0.81, 0.7, 0.9)));
        Assert.False(OwnSubtitles.CoversLine(dropped, new TextBox(0.3, 0.4, 0.7, 0.5)));
        own.Cleared();
        time += OwnSubtitles.PlaceGraceMs + 1;
        Assert.Equal(2, own.Split(reading).Kept.Lines.Count);
    }

    [Fact]
    public void ScreenTextReadersSkipOwnSubtitle()
    {
        var echo = new SubtitleEcho(() => 0);
        var own = new OwnSubtitles(() => 0);
        echo.Own = own;
        own.Record(Turkish, English, 15000);
        var reading = new Reading([new TextLine(ProjectorScreen.Ocr(Turkish)), new TextLine("Vice City Beach")]);
        Assert.Equal(["Vice City Beach"], echo.Filter(reading, geometry: false).Lines.Select(line => line.Text));
    }
}
