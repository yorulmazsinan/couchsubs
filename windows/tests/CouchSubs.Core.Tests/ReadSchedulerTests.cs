// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

public class ReadSchedulerTests
{
    private static byte[] Still() => Enumerable.Repeat((byte)40, 16).ToArray();

    [Fact]
    public void FirstFrameIsAlwaysRead() => Assert.Equal(ReadPlan.Read(true), new ReadScheduler().Plan(Still()));

    [Fact]
    public void UnchangedRegionReusesTheLastReading()
    {
        var scheduler = new ReadScheduler();
        scheduler.Plan(Still());
        scheduler.Record("Hello there");
        Assert.Equal(ReadPlan.Reused("Hello there"), scheduler.Plan(Still()));
    }

    [Fact]
    public void VideoNoiseCountsAsUnchanged()
    {
        var scheduler = new ReadScheduler();
        scheduler.Plan(Still());
        scheduler.Record("");
        var noisy = Still();
        noisy[3] += 8;
        Assert.Equal(ReadPlan.Reused(""), scheduler.Plan(noisy));
    }

    [Fact]
    public void OneChangedSampleTriggersAReading()
    {
        var scheduler = new ReadScheduler();
        scheduler.Plan(Still());
        scheduler.Record("Hel");
        var typed = Still();
        typed[3] += 40;
        Assert.Equal(ReadPlan.Read(false), scheduler.Plan(typed));
    }

    [Fact]
    public void ReusedReadingIsRefreshedAfterALimit()
    {
        var scheduler = new ReadScheduler(maxReuse: 2, deepEvery: 2);
        scheduler.Plan(Still());
        scheduler.Record("a line");
        Assert.True(scheduler.Plan(Still()).Reuse);
        Assert.True(scheduler.Plan(Still()).Reuse);
        Assert.Equal(ReadPlan.Read(false), scheduler.Plan(Still()));
    }

    [Fact]
    public void FastDetectionRefreshesAnUnchangedAreaAfterTwoReusedFrames()
    {
        var scheduler = new ReadScheduler(maxReuse: ReadScheduler.FastMaxReuse);
        Assert.False(scheduler.Plan(Still()).Reuse);
        scheduler.Record("");
        Assert.True(scheduler.Plan(Still()).Reuse);
        Assert.True(scheduler.Plan(Still()).Reuse);
        Assert.False(scheduler.Plan(Still()).Reuse);
    }

    [Fact]
    public void SlowerSearchRunsOnlyOnEveryThirdEmptyFrame()
    {
        var scheduler = new ReadScheduler(deepEvery: 3);
        var deep = new List<bool>();
        for (var value = 0; value < 6; value++)
        {
            deep.Add(scheduler.Plan(Enumerable.Repeat((byte)(value * 40), 16).ToArray()).Deep);
            scheduler.Record("");
        }
        Assert.Equal([true, false, false, true, false, false], deep);
    }

    [Fact]
    public void ResetForgetsThePreviousFrame()
    {
        var scheduler = new ReadScheduler();
        scheduler.Plan(Still());
        scheduler.Record("old");
        scheduler.Reset();
        Assert.Equal(ReadPlan.Read(true), scheduler.Plan(Still()));
    }

    /// <summary>Kutu verilince yalnız kutunun örttüğü örneklere bakılır; bölgenin başka yerindeki kıpırtı değişiklik sayılmaz.</summary>
    [Fact]
    public void ChangeWithinABoxIgnoresTheRestOfTheRegion()
    {
        const int width = ReadScheduler.SignatureWidth;
        var still = Enumerable.Repeat((byte)120, width * ReadScheduler.SignatureHeight).ToArray();
        var box = new TextBox(0.3, 0.6, 0.7, 0.85);
        var elsewhere = (byte[])still.Clone();
        elsewhere[0] = 250;
        elsewhere[(8 * width) + 10] = 250;
        Assert.True(ReadScheduler.Changed(still, elsewhere, ReadScheduler.ChangeThreshold));
        Assert.False(ReadScheduler.Changed(still, elsewhere, ReadScheduler.ChangeThreshold, box));
        var inside = (byte[])still.Clone();
        inside[(8 * width) + 30] = 180;
        Assert.True(ReadScheduler.Changed(still, inside, ReadScheduler.ChangeThreshold, box));
        inside[(8 * width) + 30] = 130;
        Assert.False(ReadScheduler.Changed(still, inside, ReadScheduler.ChangeThreshold, box));
    }

    /// <summary>GitHub #1019: altyazı birkaç karede belirince her kare bir öncekinden eşikten az farklıdır. Karşılaştırma son
    /// okunan kareyle yapılır: biriken fark okutur, yazının son hâli de okunur (Mac: ReadSchedulerTests).</summary>
    [Fact]
    public void GradualChangeIsComparedWithTheLastReadFrame()
    {
        var scheduler = new ReadScheduler();
        Assert.Equal(ReadPlan.Read(true), scheduler.Plan(Still()));
        scheduler.Record("");
        var frame = Still();
        var reused = new List<bool>();
        for (var i = 0; i < 6; i++)
        {
            frame = (byte[])frame.Clone();
            frame[3] += 6;
            var plan = scheduler.Plan(frame);
            reused.Add(plan.Reuse);
            if (!plan.Reuse) scheduler.Record("Lucia: Could I");
        }
        Assert.Equal([true, true, false, false, false, true], reused);
    }

    /// <summary>Oturma okumaları sınırlıdır; değişim olmadan küçük fark okutmaz.</summary>
    [Fact]
    public void SettlingReadsAreLimited()
    {
        var scheduler = new ReadScheduler();
        scheduler.Plan(Still());
        scheduler.Record("");
        var frame = Still();
        frame[3] += 40;
        Assert.False(scheduler.Plan(frame).Reuse);
        scheduler.Record("line");
        var reads = 0;
        for (var step = 0; step < 6; step++)
        {
            frame = (byte[])frame.Clone();
            frame[5] = (byte)(40 + (step % 2 == 0 ? 6 : 0));
            if (!scheduler.Plan(frame).Reuse) reads++;
        }
        Assert.Equal(ReadScheduler.SettleReads, reads);
        var quiet = new ReadScheduler();
        quiet.Plan(Still());
        quiet.Record("");
        var noisy = Still();
        noisy[3] += 6;
        Assert.True(quiet.Plan(noisy).Reuse);
    }

    [Fact]
    public void AlwaysDisablesReuse()
    {
        var scheduler = ReadScheduler.Always();
        scheduler.Plan(Still());
        scheduler.Record("");
        Assert.Equal(ReadPlan.Read(true), scheduler.Plan(Still()));
    }

    [Fact]
    public void SignatureHasAFixedSizeAndFollowsBrightness()
    {
        static Frame Filled(byte value)
        {
            var frame = Frame.Blank(640, 120);
            Array.Fill(frame.Pixels, value);
            return frame;
        }
        Assert.Equal(64 * 12, RegionCropper.Signature(Filled(50)).Length);
        Assert.Equal(RegionCropper.Signature(Filled(50)), RegionCropper.Signature(Filled(50)));
        Assert.NotEqual(RegionCropper.Signature(Filled(50)), RegionCropper.Signature(Filled(200)));
    }
}
