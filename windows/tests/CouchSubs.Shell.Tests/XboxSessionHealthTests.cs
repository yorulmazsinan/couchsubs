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

    /// <summary>#871: Xbox kartında Xbox'ın JSON hata nesnesi olduğu gibi görünüyordu.</summary>
    private const string CloudServiceTimeout = "{\"message\":\"Agent : -2147019873 : Timed out waiting for Cloud Streaming Service to be ready. at xbox\\\\streaming\\\\manager\"}";

    [Fact]
    public void CloudStreamingServiceTimeoutIsReadableAndNotRetried()
    {
        Assert.Equal("0x8007139F", XboxStop.ErrorCode(CloudServiceTimeout));
        Assert.Equal(XboxStopKind.ServiceNotReady, XboxStop.Classify(CloudServiceTimeout));
        Assert.Equal(XboxStopKind.ServiceNotReady, XboxStop.Classify("Xbox service HTTP 500: " + CloudServiceTimeout));
        Assert.StartsWith("Agent : -2147019873 : Timed out waiting for Cloud Streaming Service to be ready. at xbox\\streaming", XboxStop.ErrorMessage(CloudServiceTimeout));
        var tr = XboxStop.Message(Localizer.ForLanguage("tr"), CloudServiceTimeout);
        Assert.Equal("Xbox uzaktan oynatma hizmetini başlatamadı. Xbox'ı güç düğmesine 10 sn basılı tutarak tam kapatıp açın, Uzak özelliklerin açık olduğunu denetleyin, sonra yeniden deneyin.", tr);
        var en = XboxStop.Message(Localizer.ForLanguage("en"), CloudServiceTimeout);
        Assert.DoesNotContain("{", en);
        Assert.Contains("10 seconds", en);
        // HTTP hatası olarak gelse de yeniden denenmez.
        Assert.Null(new XboxRetryPlan().Failed(false, false, null, "Xbox service HTTP 500: " + CloudServiceTimeout));
    }

    [Fact]
    public void UnknownXboxErrorShowsOnlyTheCode()
    {
        const string reason = "{\"message\":\"Agent : -2147024891 : Access is denied.\"}";
        Assert.Equal(XboxStopKind.StartFailed, XboxStop.Classify(reason));
        var tr = XboxStop.Message(Localizer.ForLanguage("tr"), reason);
        Assert.StartsWith("Xbox yayını başlatamadı (kod 0x80070005). ", tr);
        Assert.DoesNotContain("{", tr);
        Assert.Equal("Conflict", XboxStop.DisplayReason("{\"code\":\"Conflict\",\"message\":\"x\"}", XboxStopKind.StartFailed));
        Assert.Equal("0x8007139F", XboxStop.ErrorCode("hr 0x8007139f"));
        Assert.Null(XboxStop.ErrorCode("{\"code\":null,\"message\":\"x\"}"));
        Assert.Equal(XboxStopKind.Other, XboxStop.Classify("{\"message\":\"something odd\"}"));
        Assert.Equal("something odd", XboxStop.DisplayReason("{\"message\":\"something odd\"}", XboxStopKind.Other));
        Assert.Equal("Xbox service HTTP 500", XboxStop.DisplayReason("Xbox service HTTP 500: {\"x\":1}", XboxStopKind.Other));
        // Bilinmeyen hata yeniden deneme kuralını değiştirmez.
        Assert.Equal(5000, new XboxRetryPlan().Failed(false, false, null, reason));
    }

    [Fact]
    public void NoPictureMessageNamesTheXboxSettingAndCable()
    {
        // #403 / X: Xbox görüntü göndermeyince ekranda yalnız "WebRTC bağlantısı kesildi" görünüyordu.
        var tr = XboxStop.Message(Localizer.ForLanguage("tr"), "Xbox WebRTC bağlantısı kesildi", noFirstFrame: true);
        Assert.Contains("görüntü gelmedi", tr);
        Assert.Contains("Ayarlar › Cihazlar ve bağlantılar › Uzak özellikler", tr);
        Assert.Contains("kablo", tr);
        Assert.DoesNotContain("WebRTC", tr);
        var en = XboxStop.Message(Localizer.ForLanguage("en"), null, noFirstFrame: true);
        Assert.Contains("Settings › Devices & connections › Remote features", en);
        Assert.Equal("Xbox'tan görüntü gelmedi. Bir kez daha deneniyor…", Localizer.ForLanguage("tr")[XboxStop.NoPictureRetrying]);
        Assert.Equal(XboxStopKind.NoPicture, XboxStop.Classify("ServerInUse", noFirstFrame: true));
    }

    [Fact]
    public void ConnectionsWithoutPictureStopAfterTwoAttempts()
    {
        // Eskiden görüntüsüz her bağlantı ~60 sn sürüp dört kez açılıp kapanıyordu (Xbox'ta "uzaktan oynatma başlatıldı / durduruldu").
        var plan = new XboxRetryPlan();
        Assert.Equal(5000, plan.Failed(permanent: false, noFirstFrame: true, streamedMs: null));
        Assert.Null(plan.Failed(permanent: false, noFirstFrame: true, streamedMs: null));
    }

    [Fact]
    public void PictureResetsTheNoPictureStreakButNotOtherFailures()
    {
        var plan = new XboxRetryPlan();
        Assert.Equal(5000, plan.Failed(false, noFirstFrame: true, streamedMs: null));
        plan.PictureArrived();
        // Görüntü geldi, 10 sn sonra kesildi: sıradan kopma, ikinci deneme.
        Assert.Equal(15000, plan.Failed(false, noFirstFrame: false, streamedMs: 10_000));
        Assert.Equal(45000, plan.Failed(false, noFirstFrame: true, streamedMs: null));
        Assert.Null(plan.Failed(false, noFirstFrame: false, streamedMs: null));
    }

    [Fact]
    public void OtherFailuresKeepThreeRetriesAndHealthyStreamResets()
    {
        var plan = new XboxRetryPlan();
        Assert.Equal(5000, plan.Failed(false, false, null));
        Assert.Equal(15000, plan.Failed(false, false, null));
        // Bir dakikadan uzun süren yayın: yeni dizi.
        Assert.Equal(5000, plan.Failed(false, false, XboxRetryPlan.HealthyStreamMs));
        Assert.Equal(15000, plan.Failed(false, false, null));
        Assert.Equal(45000, plan.Failed(false, false, null));
        Assert.Null(plan.Failed(false, false, null));
        Assert.Null(new XboxRetryPlan().Failed(permanent: true, noFirstFrame: false, streamedMs: null));
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
