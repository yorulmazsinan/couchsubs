// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell.Tests;

/// <summary>
/// İlk kareden sonra Xbox görüntüsü kesilince uyarı ve yeniden kurma. Sahte saat: anlar ms olarak verilir.
/// CouchSubsCore XboxPictureWatchTests ve Android'deki XboxPictureWatchTest ile aynı durumlar.
/// </summary>
public class XboxPictureWatchTests
{
    [Fact]
    public void NothingIsDecidedBeforeTheFirstFrame()
    {
        var watch = new XboxPictureWatch();
        watch.IceChanged(XboxPictureWatch.Ice.Disconnected, 0);
        Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(60_000));
    }

    [Fact]
    public void FlowingPictureIsFine()
    {
        var watch = new XboxPictureWatch();
        for (long second = 0; second < 120; second++)
        {
            watch.FrameArrived(second * 1000);
            Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(second * 1000 + 500));
        }
    }

    [Fact]
    public void WarnsOnceThenReconnectsWhenFramesStopWhileTheConnectionLooksOpen()
    {
        var watch = new XboxPictureWatch();
        watch.FrameArrived(10_000);
        Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(14_000));
        Assert.Equal(XboxPictureVerdict.Warn, watch.Tick(15_000));
        Assert.True(watch.Warned);
        Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(16_000));
        Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(21_000));
        Assert.Equal(XboxPictureVerdict.Stalled("Xbox'tan 12 sn'dir görüntü gelmiyor (bağlantı açık görünüyor)"), watch.Tick(22_000));
    }

    [Fact]
    public void RecoversWhenFramesComeBackBeforeTheLimit()
    {
        var watch = new XboxPictureWatch();
        watch.FrameArrived(0);
        Assert.Equal(XboxPictureVerdict.Warn, watch.Tick(6000));
        watch.FrameArrived(8000);
        Assert.Equal(XboxPictureVerdict.Recovered, watch.Tick(8500));
        Assert.False(watch.Warned);
        Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(9500));
    }

    [Fact]
    public void IceDisconnectedWarnsAfterOneSecondWithoutFrames()
    {
        var watch = new XboxPictureWatch();
        watch.FrameArrived(0);
        watch.IceChanged(XboxPictureWatch.IceFrom("disconnected"), 200);
        Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(500));
        Assert.Equal(XboxPictureVerdict.Warn, watch.Tick(1200));
        watch.IceChanged(XboxPictureWatch.IceFrom("connected"), 3000);
        watch.FrameArrived(3100);
        Assert.Equal(XboxPictureVerdict.Recovered, watch.Tick(3500));
    }

    [Fact]
    public void IceStuckInDisconnectedEndsTheSessionAtTheLimit()
    {
        var watch = new XboxPictureWatch();
        watch.FrameArrived(0);
        watch.IceChanged(XboxPictureWatch.Ice.Disconnected, 100);
        Assert.Equal(XboxPictureVerdict.Warn, watch.Tick(1000));
        Assert.Equal(XboxPictureVerdict.Stalled("Xbox'tan 12 sn'dir görüntü gelmiyor (ICE disconnected)"), watch.Tick(12_000));
    }

    [Fact]
    public void IceFailedEndsTheSessionAtOnce()
    {
        var watch = new XboxPictureWatch();
        watch.FrameArrived(0);
        watch.IceChanged(XboxPictureWatch.IceFrom("failed"), 500);
        Assert.Equal(XboxPictureVerdict.Stalled("Xbox ICE bağlantısı koptu (failed)"), watch.Tick(600));
    }

    [Fact]
    public void FramesWhileIceSaysDisconnectedDoNotWarn()
    {
        var watch = new XboxPictureWatch();
        watch.IceChanged(XboxPictureWatch.Ice.Disconnected, 0);
        for (long second = 0; second < 20; second++)
        {
            watch.FrameArrived(second * 1000);
            Assert.Equal(XboxPictureVerdict.Fine, watch.Tick(second * 1000 + 300));
        }
    }

    [Fact]
    public void UnknownStatesAreIgnored()
    {
        Assert.Equal(XboxPictureWatch.Ice.Other, XboxPictureWatch.IceFrom("checking"));
        Assert.Equal(XboxPictureWatch.Ice.Other, XboxPictureWatch.IceFrom(null));
    }
}
