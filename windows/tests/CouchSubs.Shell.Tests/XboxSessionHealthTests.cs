// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Shell.Tests;

/// <summary>Xbox yayınının canlı tutulması, durunca gösterilen metin ve günlük özeti.</summary>
public class XboxSessionHealthTests
{
    [Fact]
    public void SingleKeepaliveFailureDoesNotEndTheStream()
    {
        // Eskiden oynatıcıdaki tek başarısız canlı tutma isteği görüntü akarken oturumu kapatıyordu.
        var keepalive = new XboxKeepalive();
        Assert.False(keepalive.Failed());
        Assert.False(keepalive.Failed());
        keepalive.Succeeded();
        Assert.Equal(0, keepalive.Failures);
        Assert.False(keepalive.Failed());
    }

    [Fact]
    public void ThreeConsecutiveKeepaliveFailuresEndTheStream()
    {
        var keepalive = new XboxKeepalive();
        Assert.False(keepalive.Failed());
        Assert.False(keepalive.Failed());
        Assert.True(keepalive.Failed());
        Assert.Equal(XboxKeepalive.MaxFailures, keepalive.Failures);
    }

    [Theory]
    [InlineData("{\"code\":\"ServerInUse\"}", XboxStopKind.Busy)]
    [InlineData("AlreadyStreaming", XboxStopKind.Busy)]
    [InlineData("{\"code\":\"ConsoleOffline\"}", XboxStopKind.ConsoleUnavailable)]
    [InlineData("StreamingDisabled", XboxStopKind.ConsoleUnavailable)]
    [InlineData("Xbox WebRTC failed", XboxStopKind.Other)]
    [InlineData(null, XboxStopKind.Other)]
    public void StopIsClassifiedFromTheReason(string? reason, XboxStopKind kind) => Assert.Equal(kind, XboxStop.Classify(reason));

    [Fact]
    public void BusyMessageTellsTheUserToCloseTheOtherSession()
    {
        var text = XboxStop.Message(Localizer.ForLanguage("tr"), "{\"code\":\"ServerInUse\"}");
        Assert.Contains("başka bir cihaza yayın yapıyor", text);
        Assert.DoesNotContain("ServerInUse", text);
    }

    [Fact]
    public void OtherMessageShowsAShortReason()
    {
        var reason = "Xbox service HTTP 500: " + new string('x', 600);
        var text = XboxStop.Message(Localizer.ForLanguage("en"), reason);
        Assert.StartsWith("The Xbox stream stopped (Xbox service HTTP 500: ", text);
        Assert.True(text.Length < 250, text);
        Assert.Contains("…)", text);
    }

    [Fact]
    public void SummarySeparatesNoPictureFromPictureThenDrop()
    {
        Assert.Equal("bağlantı bitti: WebRTC failed; kare 0, ilk kareden sonra ilk kare yok", XboxStop.Summary("WebRTC failed", 0, null));
        Assert.Equal("bağlantı bitti: durduruldu; kare 1200, ilk kareden sonra 95 sn", XboxStop.Summary(null, 1200, TimeSpan.FromSeconds(95.4)));
    }

    [Fact]
    public void BridgeOutputHidesTokenLikeValues()
    {
        var token = new string('A', 30) + "." + new string('b', 30);
        var output = "line one\nError: invalid_grant " + token + "\n    at handle (bridge.cjs:12)";
        var line = XboxStop.RedactBridgeOutput(output);
        Assert.DoesNotContain(token, line);
        Assert.Contains("[gizlendi]", line);
        Assert.Contains("invalid_grant", line);
        Assert.Equal("", XboxStop.RedactBridgeOutput("  "));
    }
}
