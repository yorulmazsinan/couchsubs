// SPDX-License-Identifier: AGPL-3.0-only

using Xunit;

namespace CouchSubs.Core.Tests;

public class FrameGateTests
{
    [Fact]
    public void OnlyOneFrameIsReadAtATime()
    {
        var gate = new FrameGate();
        var first = gate.TryEnter(0);
        Assert.Equal(FrameGate.EntryKind.Enter, first.Kind);
        Assert.Equal(FrameGate.EntryKind.Busy, gate.TryEnter(100).Kind);
        gate.Leave(first.Token);
        Assert.Equal(FrameGate.EntryKind.Enter, gate.TryEnter(200).Kind);
    }

    // Tek okuma bitmezse çeviri tamamen duruyordu; "Durdur / Başlat" düzeltmiyordu (ese, 2026-11-13).
    [Fact]
    public void ResetLetsTheNextFrameInAndALateLeaveChangesNothing()
    {
        var gate = new FrameGate();
        var stuck = gate.TryEnter(0);
        gate.Reset();
        var fresh = gate.TryEnter(50);
        Assert.Equal(FrameGate.EntryKind.Enter, fresh.Kind);
        gate.Leave(stuck.Token);
        Assert.True(gate.IsBusy);
        Assert.Equal(FrameGate.EntryKind.Busy, gate.TryEnter(60).Kind);
    }

    [Fact]
    public void AReadThatNeverEndsIsReportedAsStuck()
    {
        var gate = new FrameGate(stuckAfterMs: 1000);
        gate.TryEnter(0);
        Assert.Equal(FrameGate.EntryKind.Busy, gate.TryEnter(999).Kind);
        var stuck = gate.TryEnter(1000);
        Assert.Equal(FrameGate.EntryKind.Stuck, stuck.Kind);
        Assert.Equal(1000, stuck.Ms);
        Assert.Equal(FrameGate.EntryKind.Enter, gate.TryEnter(1001).Kind);
    }
}
