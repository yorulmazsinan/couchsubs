// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell.Tests;

/// <summary>Pencere yakalamanın dakikalık kare sayımı: günlük satırı ve sıfırlama (#822, Mac ile aynı).</summary>
public class WindowFrameCountsTests
{
    [Fact]
    public void MinuteLineCountsAndResets()
    {
        var counts = new WindowFrameCounts();
        for (var i = 0; i < 3; i++) counts.Delivered();
        counts.Idle();
        counts.Fallback();
        counts.Fallback();
        Assert.Equal("pencere kareleri: 3/dk, boş: 1, yedek: 2", counts.MinuteLine());
        Assert.Equal("pencere kareleri: 0/dk, boş: 0, yedek: 0", counts.MinuteLine());
    }
}
