// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell.Tests;

/// <summary>Seçilen pencereden kare gelmiyorsa nedeni altyazi.log'a yazılır (#566).</summary>
public class WindowCaptureWatchTests
{
    private static TimeSpan S(double value) => TimeSpan.FromSeconds(value);

    [Fact]
    public void NothingIsReportedBeforeFiveSeconds()
    {
        var watch = new WindowCaptureWatch();
        Assert.Null(watch.Tick(S(4.9)));
    }

    [Fact]
    public void NoFramesFromWindowsIsReportedThenRepeatedEveryThirtySeconds()
    {
        var watch = new WindowCaptureWatch();
        var first = watch.Tick(S(5));
        Assert.NotNull(first);
        Assert.Contains("hiç kare vermedi", first);
        Assert.Null(watch.Tick(S(6)));
        Assert.Null(watch.Tick(S(34)));
        Assert.NotNull(watch.Tick(S(35)));
    }

    [Fact]
    public void CopyFailureIsReportedWithTheError()
    {
        var watch = new WindowCaptureWatch();
        watch.Arrived();
        Assert.True(watch.Failed("COMException: The parameter is incorrect."));
        watch.Arrived();
        Assert.False(watch.Failed("COMException: The parameter is incorrect."));
        var note = watch.Tick(S(5));
        Assert.Contains("2 kare kopyalanamadı", note);
        Assert.Contains("The parameter is incorrect.", note);
    }

    [Fact]
    public void StuckCopyIsReported()
    {
        var watch = new WindowCaptureWatch();
        watch.Arrived();
        watch.CopyStarted(S(1));
        Assert.Contains("kopyalama 4000 ms'dir bitmedi", watch.Tick(S(5)));
    }

    [Fact]
    public void FirstDeliveredFrameSilencesTheWatch()
    {
        var watch = new WindowCaptureWatch();
        watch.Arrived();
        Assert.True(watch.FrameDelivered());
        Assert.False(watch.FrameDelivered());
        Assert.True(watch.Delivered);
        Assert.Null(watch.Tick(S(60)));
    }

    /// <summary>#566: Windows 10'da pencereden hiç kare gelmedi; beş saniye sonra yedek yakalamaya (PrintWindow) geçilir.</summary>
    [Fact]
    public void FallsBackWhenNoFrameReachesReadingWithinFiveSeconds()
    {
        var watch = new WindowCaptureWatch();
        Assert.False(watch.ShouldFallBack(S(4.9)));
        Assert.True(watch.ShouldFallBack(S(5)));
    }

    [Fact]
    public void FallsBackWhenFramesArriveButNoneCanBeCopied()
    {
        var watch = new WindowCaptureWatch();
        watch.Arrived();
        watch.CopyStarted(S(0.5));
        Assert.True(watch.ShouldFallBack(S(6)));
    }

    [Fact]
    public void WorkingCaptureNeverFallsBack()
    {
        var watch = new WindowCaptureWatch();
        watch.Arrived();
        Assert.True(watch.FrameDelivered());
        Assert.False(watch.ShouldFallBack(S(60)));
    }

    [Fact]
    public void ClockJumpWritesOneReport()
    {
        var watch = new WindowCaptureWatch();
        Assert.NotNull(watch.Tick(S(200)));
        Assert.Null(watch.Tick(S(201)));
    }
}
