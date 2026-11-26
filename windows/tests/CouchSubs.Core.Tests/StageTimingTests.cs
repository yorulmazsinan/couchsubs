// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Aşama süreleri satırı (Mac/iPhone StageTimingTests, Android StageTimingTest ile aynı durumlar).</summary>
public class StageTimingTests
{
    private static TimeSpan Ms(double value) => TimeSpan.FromTicks((long)Math.Round(value * 10_000));

    [Fact]
    public void ReportsOncePerPeriodAndResets()
    {
        var timing = new StageTiming(30_000);
        Assert.Null(timing.Report(0));
        timing.Add("okuma", Ms(80));
        timing.Add("okuma", Ms(140.25));
        timing.Add("çizim", Ms(30.04));
        Assert.Null(timing.Report(29_999));
        Assert.Equal("aşama süreleri (30 sn): okuma 2× ort 110,1 en çok 140,3 ms; çizim 1× ort 30,0 en çok 30,0 ms",
            timing.Report(30_000));
        // Sıfırlandı: yeni ölçüm yoksa satır yok.
        Assert.Null(timing.Report(60_000));
        timing.Add("tur", Ms(5));
        Assert.Null(timing.Report(60_001));
        Assert.Equal("aşama süreleri (30 sn): tur 1× ort 5,0 en çok 5,0 ms", timing.Report(90_000));
    }

    [Fact]
    public void ClockGoingBackReportsAndRestarts()
    {
        var timing = new StageTiming(30_000);
        timing.Report(100_000);
        timing.Add("tur", Ms(1));
        Assert.Equal("aşama süreleri (0 sn): tur 1× ort 1,0 en çok 1,0 ms", timing.Report(50));
    }

    /// <summary>Erken duran sayım saf sayımla aynı sonucu verir (bütün kare ölçümü hızlandı, sonuç değişmedi).</summary>
    [Fact]
    public void EarlyStopCountsMatchFullCounts()
    {
        var random = new Random(7);
        double[] shares = [0.1, 0.5, 0.7, 0.03];
        for (var round = 0; round < 4000; round++)
        {
            var from = random.Next(20);
            var until = from + random.Next(140);
            var step = 1 + random.Next(5);
            var share = shares[random.Next(4)];
            var density = random.NextDouble();
            var cells = Enumerable.Range(0, 200).Select(_ => random.NextDouble() < density).ToArray();
            int n = 0, ok = 0;
            for (var at = from; at < until; at += step) { n++; if (cells[at]) ok++; }
            Assert.Equal(n > 0 && ok >= share * n, TextPainter.ShareAtLeast(from, until, step, share, i => cells[i]));
            var free = Enumerable.Range(0, 200)
                .Select(_ => random.NextDouble() < 0.02 ? (bool?)null : random.NextDouble() < density * 0.2).ToArray();
            var list = free[from..until];
            var open = list.Length > 0 && list.All(c => c != null) && list.Count(c => c == true) < TextPainter.BesideShare * list.Length;
            Assert.Equal(open, TextPainter.RoomOpen(from, until, i => free[i]));
        }
        Assert.False(TextPainter.ShareAtLeast(5, 5, 1, 0.5, _ => true));
        Assert.True(TextPainter.RoomOpen(0, 3, _ => false));
    }
}
