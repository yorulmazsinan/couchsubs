// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Canlı ölçüm satırı: süreler, sınırlar, güven ve ekrandaki parçalar (Mac: LineMetricsTests).</summary>
public class LineMetricsTests
{
    private static readonly Localizer English = Localizer.ForLanguage("en");

    [Fact]
    public void MeasuresDurationsFromTheSameClock()
    {
        var metrics = LineMetrics.Measure(1000, 40, (1100, 1400), 1520, null, LineOrigin.Engine);
        Assert.Equal(new LineMetrics(40, 300, 520, null, LineOrigin.Engine), metrics);
    }

    [Fact]
    public void NegativeDurationsBecomeZero()
    {
        var metrics = LineMetrics.Measure(2000, -5, (1500, 1400), 1000, null, LineOrigin.Engine);
        Assert.Equal(0, metrics.OcrMs);
        Assert.Equal(0, metrics.TranslationMs);
        Assert.Equal(0, metrics.TotalMs);
    }

    [Theory]
    [InlineData(0.934, 93)]
    [InlineData(0.936, 94)]
    [InlineData(1.2, 100)]
    [InlineData(-0.1, 0)]
    public void ConfidenceIsARoundedPercent(double confidence, int percent) =>
        Assert.Equal(percent, LineMetrics.Measure(0, null, null, 0, confidence, LineOrigin.Engine).Confidence);

    [Fact]
    public void PackLineHasNoTranslationTime()
    {
        var metrics = LineMetrics.Measure(1000, 35, null, 1060, null, LineOrigin.Pack);
        Assert.Null(metrics.TranslationMs);
        Assert.Equal(["OCR 35 ms", "Ready pack", "Delay 60 ms"], metrics.Parts(English));
    }

    [Fact]
    public void PartsAreInOrder()
    {
        var metrics = LineMetrics.Measure(1000, 40, (1100, 1400), 1520, null, LineOrigin.Engine);
        Assert.Equal("OCR 40 ms · Translation 300 ms · Delay 520 ms", metrics.Summary(English));
        var sure = metrics with { Confidence = 93 };
        Assert.Equal(["OCR 40 ms", "Translation 300 ms", "Delay 520 ms", "Confidence 93%"], sure.Parts(English));
    }

    [Fact]
    public void UnknownValuesAreLeftOut()
    {
        var metrics = new LineMetrics(null, null, 250, null, LineOrigin.Engine);
        Assert.Equal("Delay 250 ms", metrics.Summary(English));
    }

    [Fact]
    public void ReadingConfidenceIsTheAverageOfKnownLines()
    {
        Assert.Null(Reading.FromText("Hold the gate").Confidence);
        var reading = new Reading([new TextLine("Hold", null, 0.9), new TextLine("the gate", null, 0.7), new TextLine("now")]);
        Assert.Equal(0.8, reading.Confidence!.Value, 6);
        Assert.Equal(0.8, reading.WithoutOcrNoise().WithoutButtonPrompts().Confidence!.Value, 6);
    }
}
