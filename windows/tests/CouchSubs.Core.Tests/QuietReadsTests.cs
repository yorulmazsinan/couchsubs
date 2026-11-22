// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core.Tests;

/// <summary>
/// Mac (beta.80, PS5, GTA 6): ekranda diyalog varken altyazı günlüğüne dakikalarca hiçbir satır düşmüyordu; altyazının
/// gösterilmediği mi (menü), boş mu okunduğu mu, süzgeçte mi kaldığı mı, okumanın hata mı verdiği mi anlaşılmıyordu.
/// Sessizlik sürerse nedeni dakikada bir günlüğe yazılır. Mac/iPhone QuietReadsTests ve Android QuietReadsTest ile aynı.
/// </summary>
public class QuietReadsTests
{
    private sealed class Scripted : ITextReader
    {
        public Reading Reading { get; set; } = Reading.Empty;
        public Exception? Error { get; set; }
        public string Read(Frame image) => ReadLines(image, false).Text;
        public Reading ReadLines(Frame image, bool deep) => Error is { } error ? throw error : Reading;
    }

    private sealed class Silent : ISubtitleSender
    {
        public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false) { }
        public void Clear() { }
    }

    private sealed class Plain : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default) => Task.FromResult("Çeviri: " + text);
    }

    private static Frame Image(int shade) => new(Enumerable.Repeat((byte)(shade % 7 * 36), 64 * 64 * 4).ToArray(), 64, 64, 256);

    private static async Task<List<string>> Run(Scripted reader, int frames, Func<int, bool>? menu = null)
    {
        long clock = 0;
        var index = 0;
        var log = new List<string>();
        var pipeline = new SubtitlePipeline(reader, new Plain(), new Silent(), clock: () => clock)
        { Log = log.Add, EchoPaused = () => menu?.Invoke(index) == true };
        for (; index < frames; index++)
        {
            await pipeline.ProcessAsync(Image(index), new CropRegion());
            clock += 1000;
        }
        return log;
    }

    [Fact]
    public async Task EmptyReadsAreReportedOncePerMinute()
    {
        var log = await Run(new Scripted(), 130);
        var quiet = log.Where(line => line.StartsWith("altyazı alanında")).ToList();
        Assert.Equal(2, quiet.Count);
        Assert.Contains("60 sn'dir yazı yok", quiet[0]);
        Assert.DoesNotContain(" 0 boş", quiet[0]);
    }

    [Fact]
    public async Task ReadErrorsAreReportedWithTheError()
    {
        var log = await Run(new Scripted { Error = new InvalidOperationException("bozuk kare") }, 61);
        var quiet = log.FirstOrDefault(line => line.StartsWith("altyazı alanında"));
        Assert.NotNull(quiet);
        Assert.Contains("son hata: bozuk kare", quiet);
    }

    [Fact]
    public async Task TextKeepsTheReportQuiet()
    {
        var reader = new Scripted { Reading = new Reading([new TextLine("Get in the car, now.", new TextBox(0.2, 0.4, 0.8, 0.6))]) };
        var log = await Run(reader, 130);
        Assert.DoesNotContain(log, line => line.StartsWith("altyazı alanında"));
    }

    /// <summary>Menüde altyazı gönderilmez: bu kareler sessizlik özetinde sayılır (geçişi MenuPausedSender yazar).</summary>
    [Fact]
    public async Task MenuPauseIsLogged()
    {
        var log = await Run(new Scripted(), 70, index => index >= 5 && index < 66);
        var quiet = log.FirstOrDefault(line => line.StartsWith("altyazı alanında"));
        Assert.NotNull(quiet);
        Assert.Contains("kare menü yüzünden gösterilmedi", quiet);
        Assert.DoesNotContain(" 0 kare menü", quiet);
    }
}
