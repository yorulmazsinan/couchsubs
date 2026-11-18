// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell.Tests;

/// <summary>Altyazı penceresinin yeniden öne alınma sıklığı ve hangi ön plan değişiminde öne alındığı.</summary>
public class TopmostThrottleTests
{
    private static TimeSpan Ms(double value) => TimeSpan.FromMilliseconds(value);

    [Fact]
    public void FirstCallRaises()
    {
        Assert.True(new TopmostThrottle().TryRaise(Ms(0)));
    }

    [Fact]
    public void CallsWithinIntervalAreSkipped()
    {
        var throttle = new TopmostThrottle(Ms(250));
        Assert.True(throttle.TryRaise(Ms(1000)));
        Assert.False(throttle.TryRaise(Ms(1100)));
        Assert.False(throttle.TryRaise(Ms(1249)));
        Assert.True(throttle.TryRaise(Ms(1250)));
        Assert.False(throttle.TryRaise(Ms(1300)));
    }

    [Fact]
    public void ForcedRaiseRestartsTheInterval()
    {
        var throttle = new TopmostThrottle(Ms(250));
        Assert.True(throttle.TryRaise(Ms(0)));
        throttle.Raised(Ms(400));
        Assert.False(throttle.TryRaise(Ms(500)));
        Assert.True(throttle.TryRaise(Ms(650)));
    }

    [Fact]
    public void ClockGoingBackDoesNotBlock()
    {
        var throttle = new TopmostThrottle(Ms(250));
        Assert.True(throttle.TryRaise(Ms(5000)));
        Assert.True(throttle.TryRaise(Ms(100)));
    }

    [Theory]
    [InlineData(42u, 7u, true)]
    [InlineData(7u, 7u, false)]
    [InlineData(0u, 7u, false)]
    public void RaisesOnlyForOtherProcesses(uint foreground, uint own, bool expected)
    {
        Assert.Equal(expected, TopmostThrottle.ShouldRaiseFor(foreground, own));
    }
}
