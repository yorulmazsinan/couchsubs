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
    public void AudioWithoutPictureAsksForAFullXboxRestartAndIsNotRetried()
    {
        // #1432: ses geliyor, görüntü 0 bayt; Xbox'ın görüntü yayını takılı, yeniden denemek aynı sonucu veriyordu.
        var reason = XboxFirstFrameWatch.NoPictureReason(audioOnly: true);
        Assert.Equal("Xbox'tan 30 sn içinde görüntü gelmedi (ses geliyor, görüntü 0 bayt)", reason);
        Assert.True(XboxStop.IsAudioOnly(reason));
        Assert.False(XboxStop.IsAudioOnly(XboxFirstFrameWatch.NoPictureReason(audioOnly: false)));
        Assert.Equal(XboxStopKind.StuckPicture, XboxStop.Classify(reason, noFirstFrame: true));
        Assert.Equal(XboxStopKind.NoPicture, XboxStop.Classify(XboxFirstFrameWatch.NoPictureReason(false), noFirstFrame: true));
        var tr = XboxStop.Message(Localizer.ForLanguage("tr"), reason, noFirstFrame: true);
        Assert.StartsWith("Xbox ses gönderdi ama görüntü göndermedi", tr);
        Assert.Contains("10 sn", tr);
        Assert.Contains("10 seconds", XboxStop.Message(Localizer.ForLanguage("en"), reason, noFirstFrame: true));
        Assert.Null(new XboxRetryPlan().Failed(permanent: false, noFirstFrame: true, streamedMs: null, reason));
        // Sesi de olmayan görüntüsüz bağlantı eskisi gibi bir kez daha denenir.
        Assert.Equal(5000, new XboxRetryPlan().Failed(false, true, null, XboxFirstFrameWatch.NoPictureReason(false)));
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
        // Görüntü geldi, bir dakikadan uzun sürdü: görüntüsüz bağlantı dizisi baştan sayılır, bu görüntüsüz bağlantı durdurmaz.
        Assert.Equal(5000, plan.Failed(false, noFirstFrame: true, streamedMs: XboxRetryPlan.HealthyStreamMs));
        // Görüntü gelmiş yayının kopma dizisi: ikinci deneme daha uzun bekler.
        Assert.Equal(15_000, plan.Failed(false, noFirstFrame: false, streamedMs: null));
    }

    /// <summary>
    /// Oynanan (görüntü gelmiş) yayın koparsa kullanıcıya sormadan en çok iki kez, geri çekilerek (5, 15 sn) yeniden
    /// bağlanılır; ikisi de kısa sürede koparsa durulur ve sınırın dolduğu bildirilir ("Xbox bağlantısı koptu"). Görüntü hiç
    /// gelmediyse yine tek deneme. CouchSubsCore ve Android'deki aynı adlı testle aynı.
    /// </summary>
    [Fact]
    public void RealDropReconnectsSilentlyUpToTwoTimes()
    {
        var plan = new XboxRetryPlan();
        plan.PictureArrived();
        Assert.Equal(2, plan.MaxRetries);
        Assert.Equal(5000, plan.Failed(false, false, 120_000));
        Assert.Equal(1, plan.Failures);
        Assert.False(plan.DropLimitReached);
        // Yeniden bağlanma da kısa sürede koptu: 15 sn sonra yine denenir, üçüncü kopmada durulur.
        plan.PictureArrived();
        Assert.Equal(15_000, plan.Failed(false, false, 10_000));
        plan.PictureArrived();
        Assert.Null(plan.Failed(false, false, 10_000));
        Assert.True(plan.DropLimitReached);
        // Bağlanırken hata (görüntü hiç gelmedi): eskisi gibi en çok bir deneme.
        var fresh = new XboxRetryPlan();
        Assert.Equal(1, fresh.MaxRetries);
        Assert.Equal(5000, fresh.Failed(false, false, null));
        Assert.Null(fresh.Failed(false, false, null));
        Assert.Null(new XboxRetryPlan().Failed(permanent: true, noFirstFrame: false, streamedMs: null));
    }

    /// <summary>
    /// #1252: birkaç dakikada bir kopan yayın. Eskiden sayaç 60 sn'lik yayından sonra sıfırlanıyordu: her kopmada yeniden
    /// bağlanılıyor, Xbox'ta "uzaktan yürütme durdu / başladı" bildirimi sonsuza dek tekrarlanıyordu. Artık sayaç ancak 10 dk
    /// sağlıklı yayından sonra sıfırlanır ve 10 dk içinde en çok iki sessiz yeniden bağlanma yapılır; sonra durulur.
    /// </summary>
    [Fact]
    public void StreamDroppingEveryFewMinutesStopsAfterTwoReconnects()
    {
        long now = 1000;
        var plan = new XboxRetryPlan(() => now);
        var retries = new List<int?>();
        for (var i = 0; i < 10 && !plan.DropLimitReached; i++)
        {
            plan.PictureArrived();
            now += 3 * 60_000;
            var delay = plan.Failed(false, false, 3 * 60_000, "Xbox ICE bağlantısı koptu (failed)");
            retries.Add(delay);
            now += delay ?? 0;
        }
        Assert.Equal(new int?[] { 5000, 15_000, null }, retries);
        Assert.True(plan.DropLimitReached);
        Assert.Equal("sessiz yeniden bağlanma sınırı doldu (10 dk içinde en çok 2): yeniden denenmiyor, yayın durdu", XboxEndCauses.LimitLine);
    }

    /// <summary>Kopmadan sonraki ret için tanınan deneme de oturum sınırına sayılır: döngüye ek bildirim katmaz.</summary>
    [Fact]
    public void GraceRetryCountsTowardsTheSessionLimit()
    {
        long now = 1000;
        var plan = new XboxRetryPlan(() => now);
        plan.PictureArrived();
        now += 3 * 60_000;
        Assert.Equal(5000, plan.Failed(false, false, 3 * 60_000));
        // Xbox eski oturumu bırakmadan yenisini reddetti: bir kez, 15 sn sonra denenir (ikinci deneme).
        Assert.Equal(15_000, plan.Failed(permanent: true, noFirstFrame: false, streamedMs: null));
        plan.PictureArrived();
        now += 3 * 60_000;
        Assert.Null(plan.Failed(false, false, 3 * 60_000));
        Assert.True(plan.DropLimitReached);
    }

    /// <summary>#1216'nın amacı: tek, kısa bir Wi-Fi takılması kullanıcı fark etmeden kapanır; seyrek kopmalar da hep sessiz.</summary>
    [Fact]
    public void SingleDropIsSilentAndRareDropsStaySilent()
    {
        long now = 1000;
        var plan = new XboxRetryPlan(() => now);
        for (var i = 0; i < 5; i++)
        {
            plan.PictureArrived();
            now += 25 * 60_000;
            Assert.Equal(5000, plan.Failed(false, false, 25 * 60_000));
            Assert.False(plan.DropLimitReached);
            now += 5000;
        }
        // Takılmada ilk deneme Xbox eski oturumu bırakmadan düştü: ikinci deneme yine sessiz.
        Assert.Equal(15_000, plan.Failed(false, false, null));
        Assert.False(plan.DropLimitReached);
    }

    [Fact]
    public void RetryLine()
    {
        Assert.Equal("sessiz yeniden bağlanma 2/3: 15 sn sonra", XboxEndCauses.RetryLine(2, 3, 15_000));
        Assert.Equal("sessiz yeniden bağlanma ek deneme: 15 sn sonra", XboxEndCauses.RetryLine(4, 3, 15_000));
    }

    [Fact]
    public void HealthyStreamResetsRetries()
    {
        var plan = new XboxRetryPlan();
        Assert.Equal(5000, plan.Failed(false, false, null));
        // Bir dakikadan uzun süren yayın: yeni dizi.
        Assert.Equal(5000, plan.Failed(false, false, XboxRetryPlan.HealthyStreamMs));
        // Kısa süren yayın sayacı sıfırlamaz.
        Assert.Null(plan.Failed(false, false, 1_000));
    }

    /// <summary>Görüntü akarken başarısız canlı tutma (404 dahil) yayını kapatmaz; görüntü durmuşsa eskisi gibi kapatır.</summary>
    [Fact]
    public void KeepaliveFailureDoesNotEndAFlowingStream()
    {
        Assert.False(XboxKeepalive.ShouldEnd(gone: true, exhausted: false, pictureFlowing: true));
        Assert.False(XboxKeepalive.ShouldEnd(gone: false, exhausted: true, pictureFlowing: true));
        Assert.True(XboxKeepalive.ShouldEnd(gone: true, exhausted: false, pictureFlowing: false));
        Assert.True(XboxKeepalive.ShouldEnd(gone: false, exhausted: true, pictureFlowing: false));
        Assert.False(XboxKeepalive.ShouldEnd(gone: false, exhausted: false, pictureFlowing: false));
    }

    [Fact]
    public void SummarySeparatesNoPictureFromPictureThenDrop()
    {
        Assert.Equal("bağlantı bitti: WebRTC failed; kare 0, ilk kareden sonra ilk kare yok", XboxStop.Summary("WebRTC failed", 0, null));
        Assert.Equal("bağlantı bitti: durduruldu; kare 1200, ilk kareden sonra 95 sn", XboxStop.Summary(null, 1200, TimeSpan.FromSeconds(95.4)));
    }

    [Fact]
    public void RefusalAfterDropIsRetriedOnce()
    {
        // "Bir kez kopunca tekrar bağlanmıyor": görüntü gelmiş yayın koptuktan sonra Xbox eski oturumu bırakmadan
        // yenisini reddedebiliyor. Bu ret bir kez, uzun beklenip denenir; ikinci ret yayını durdurur.
        var plan = new XboxRetryPlan();
        plan.PictureArrived();
        Assert.Equal(5000, plan.Failed(false, false, 10_000, "WebRTC failed"));
        Assert.Equal(XboxRetryPlan.ReconnectGraceMs, plan.Failed(permanent: false, noFirstFrame: false, streamedMs: null, "Xbox service HTTP 500: " + CloudServiceTimeout));
        Assert.Null(plan.Failed(permanent: true, noFirstFrame: false, streamedMs: null));
        // Görüntü hiç gelmeden gelen ret eskisi gibi denenmez.
        Assert.Null(new XboxRetryPlan().Failed(permanent: true, noFirstFrame: false, streamedMs: null));
    }

    [Fact]
    public void EndCauseIsLoggedAndShown()
    {
        Assert.Equal("kapanma nedeni: sunucu kapattı (Xbox görüntü kanalını kapattı)", XboxEndCauses.Line(XboxEndCause.Server, "Xbox görüntü kanalını kapattı"));
        Assert.Equal("bağlantı bitti (ağ): x; kare 3, ilk kareden sonra 1 sn", XboxStop.Summary("x", 3, TimeSpan.FromSeconds(1), XboxEndCause.Network));
        Assert.Equal(XboxEndCause.Timeout, XboxEndCauses.FromMessage("Xbox WebRTC exchange timed out (SDP, 30 sn)"));
        Assert.Equal(XboxEndCause.Server, XboxEndCauses.FromMessage("Xbox service HTTP 409: {}"));
        Assert.Equal(XboxEndCause.Network, XboxEndCauses.FromMessage("fetch failed"));
        Assert.True(XboxKeepalive.SessionGone("Xbox service HTTP 404: "));
        Assert.False(XboxKeepalive.SessionGone("Xbox service HTTP 500: "));
        // Ekrandaki metinler Mac kataloğunda (Türkçesiyle) var.
        foreach (var cause in Enum.GetValues<XboxEndCause>())
            Assert.NotEqual(XboxEndCauses.RetryMessage(cause), Localizer.ForLanguage("tr")[XboxEndCauses.RetryMessage(cause)]);
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
