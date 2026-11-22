// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>"Bağlanıyor…" 30 sn'yi geçince nedeni söylenir (core LogShareTests.swift ve Android ConnectingHintTest ile aynı).</summary>
public sealed class ConnectingHintTests
{
    private static readonly Localizer En = Localizer.ForLanguage("en");

    [Fact]
    public void HiddenBeforeThirtySeconds() =>
        Assert.Null(ConnectingHint.Text(TimeSpan.FromSeconds(29), ConnectStep.Waking, En));

    [Fact]
    public void NamesTheStep()
    {
        Assert.Equal("The PS5 is being woken from rest mode. This can take up to a minute.",
            ConnectingHint.Text(TimeSpan.FromSeconds(30), ConnectStep.Waking, En));
        Assert.Equal("The PS5 answered, but the connection is taking long. If it doesn't connect, stop and start translating again.",
            ConnectingHint.Text(TimeSpan.FromSeconds(45), ConnectStep.Opening, En));
        Assert.Equal("The PS5 is not answering. Make sure it is on and on the same network as this device.",
            ConnectingHint.Text(TimeSpan.FromSeconds(60), null, En));
        Assert.Equal(ConnectingHint.Text(TimeSpan.FromSeconds(60), null, En),
            ConnectingHint.Text(TimeSpan.FromSeconds(60), ConnectStep.NoAnswer, En));
        Assert.Equal("PS5 dinlenme modundan uyandırılıyor. Bu bir dakikayı bulabilir.",
            ConnectingHint.Text(TimeSpan.FromSeconds(31), ConnectStep.Waking, Localizer.ForLanguage("tr")));
    }
}
