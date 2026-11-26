// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Altyazı kapısının eleme sayacı (<see cref="RejectTally"/>; beta.103 kaçan altyazı). Mac RejectTallyTests.swift ve Android
/// RejectTallyTest.kt aynı vakalar.
/// </summary>
public class RejectTallyTests
{
    [Fact]
    public void LineCarriesTheReasonCount()
    {
        var tally = new RejectTally();
        Assert.Equal(["a [bu nedenle 1. kez]"], tally.Note("menü", "a", 0));
        Assert.Empty(tally.Note("menü", null, 10));
        Assert.Equal(["b [bu nedenle 3. kez]"], tally.Note("menü", "b", 20));
        Assert.Equal(["c [bu nedenle 1. kez]"], tally.Note("telefon", "c", 30));
        Assert.Equal(3, tally.Count("menü"));
    }

    [Fact]
    public void LinesAreCappedPerMinuteAndSummarized()
    {
        var tally = new RejectTally();
        var written = new List<string>();
        for (var index = 0; index < RejectTally.PerMinute + 5; index++) written.AddRange(tally.Note("menü", $"satır {index}", index));
        tally.Note("telefon", null, 100);
        Assert.Equal(RejectTally.PerMinute, written.Count);
        var next = tally.Note("menü", "yeni", RejectTally.WindowMs + 1);
        Assert.Equal([
            $"altyazı elemesi (son 60 sn): menü ×{RejectTally.PerMinute + 5}; telefon ×1; sınır yüzünden yazılmayan 5 satır",
            $"yeni [bu nedenle {RejectTally.PerMinute + 6}. kez]",
        ], next);
    }

    [Fact]
    public void ResetForgetsTheCounts()
    {
        var tally = new RejectTally();
        tally.Note("menü", null, 0);
        tally.Reset();
        Assert.Equal(["a [bu nedenle 1. kez]"], tally.Note("menü", "a", 1));
    }
}
