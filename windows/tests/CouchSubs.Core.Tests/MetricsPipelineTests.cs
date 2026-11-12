// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Hat, TV'ye giden her satırın ölçümlerini bildirir (sahte saatle; Mac: SubtitlePipelineTests ölçüm testleri).</summary>
public class MetricsPipelineTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    /// <summary>Her okuma sahte saati <paramref name="readMs"/> ilerletir.</summary>
    private sealed class TimedReader(TestClock clock, int readMs, params string[] texts) : ITextReader
    {
        private readonly Queue<string> texts = new(texts);
        public string Read(Frame image) => ReadLines(image, true).Text;
        public Reading ReadLines(Frame image, bool deep)
        {
            clock.Now += readMs;
            lock (texts) return Reading.FromText(texts.Count == 0 ? "" : texts.Dequeue());
        }
    }

    /// <summary>Her çeviri sahte saati <paramref name="translateMs"/> ilerletir.</summary>
    private sealed class TimedTranslator(TestClock clock, int translateMs) : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            clock.Now += translateMs;
            return Task.FromResult("TR: " + text);
        }
    }

    /// <summary>Her kare gelince saat önce 50 ms ilerler; kare saatin o anki değeriyle verilir.</summary>
    private static async Task<List<long>> Run(SubtitlePipeline pipeline, TestClock clock, int frames, int queueMs = 0)
    {
        var arrivals = new List<long>();
        for (var i = 0; i < frames; i++)
        {
            clock.Now += 50;
            var arrived = clock.Now;
            arrivals.Add(arrived);
            // Kare, okumaya başlamadan önce bir süre beklemiş olabilir (kuyrukta).
            clock.Now += queueMs;
            await pipeline.ProcessAsync(Image, new CropRegion(), arrived);
            await pipeline.WaitForTranslationsAsync();
        }
        return arrivals;
    }

    [Fact]
    public async Task TranslatedLineReportsOcrTranslationAndDelay()
    {
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(new TimedReader(clock, 40, "Hold the gate", "Hold the gate", "Hold the gate"),
            new TimedTranslator(clock, 300), new FakeSender(), clock: clock.Read);
        var reported = new List<LineMetrics>();
        var order = new List<string>();
        pipeline.MetricsReady += metrics => { reported.Add(metrics); order.Add("metrics"); };
        pipeline.PairShown += (_, _) => order.Add("pair");
        await Run(pipeline, clock, 3, queueMs: 180);
        var metrics = Assert.Single(reported);
        Assert.Equal(LineOrigin.Engine, metrics.Origin);
        Assert.Equal(40, metrics.OcrMs);
        Assert.Equal(300, metrics.TranslationMs);
        // Kare gelişinden gönderilişe: kuyruk 180 + okuma 40 + çeviri 300.
        Assert.Equal(520, metrics.TotalMs);
        Assert.Null(metrics.Confidence);
        Assert.Equal(metrics, pipeline.LastMetrics);
        Assert.Equal(["metrics", "pair"], order);
    }

    [Fact]
    public async Task PackLineReportsPackOriginWithoutTranslationTime()
    {
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(new TimedReader(clock, 25, "Get down!", "Get down!", "Get down!"),
            new TimedTranslator(clock, 300), new FakeSender(), clock: clock.Read)
        {
            PackLookup = text => text == "Get down!" ? new PackMatch("Yere yat!", []) : null,
        };
        var reported = new List<LineMetrics>();
        pipeline.MetricsReady += reported.Add;
        await Run(pipeline, clock, 3);
        var metrics = Assert.Single(reported);
        Assert.Equal(new LineMetrics(25, null, 25, null, LineOrigin.Pack), metrics);
        Assert.Equal("OCR 25 ms · Ready pack · Delay 25 ms", metrics.Summary(Localizer.ForLanguage("en")));
    }

    [Fact]
    public async Task ConfidenceComesFromTheReading()
    {
        var clock = new TestClock();
        var reading = new Reading([new TextLine("Hold the gate", null, 0.91)]);
        var pipeline = new SubtitlePipeline(new LinesReader(reading), new TimedTranslator(clock, 100), new FakeSender(), clock: clock.Read);
        LineMetrics? reported = null;
        pipeline.MetricsReady += metrics => reported = metrics;
        await Run(pipeline, clock, 3);
        Assert.Equal(91, reported?.Confidence);
    }

    [Fact]
    public async Task WithoutCaptureTimeTheDelayStartsAtProcessing()
    {
        var clock = new TestClock();
        var pipeline = new SubtitlePipeline(new TimedReader(clock, 40, "Hold the gate", "Hold the gate", "Hold the gate"),
            new TimedTranslator(clock, 300), new FakeSender(), clock: clock.Read);
        LineMetrics? reported = null;
        pipeline.MetricsReady += metrics => reported = metrics;
        for (var i = 0; i < 3; i++)
        {
            await pipeline.ProcessAsync(Image, new CropRegion());
            await pipeline.WaitForTranslationsAsync();
            clock.Now += 50;
        }
        Assert.Equal(340, reported?.TotalMs);
    }
}
