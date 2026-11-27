// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;

namespace CouchSubs.Shell.Tests;

/// <summary>Xbox görüntüsü başlayana kadar anahtar kare isteği ve tanı satırı (#403, #530).</summary>
public class XboxFirstFrameWatchTests
{
    private static TimeSpan Ms(double value) => TimeSpan.FromMilliseconds(value);

    /// <summary>0-30 sn arasını 500 ms'lik adımlarla yürütür (oturumdaki saat gibi); isteklerin ve tanıların anları.</summary>
    private static (List<double> keyframes, List<double> stats) Run(XboxFirstFrameWatch watch, double untilMs = 30_000, double readyAtMs = 0, double? frameAtMs = null)
    {
        var keyframes = new List<double>();
        var stats = new List<double>();
        for (double t = 0; t <= untilMs; t += 500)
        {
            if (frameAtMs is { } frame && t >= frame) watch.FrameArrived();
            var step = watch.Tick(Ms(t), t >= readyAtMs);
            if (step.RequestKeyframe) keyframes.Add(t);
            if (step.LogStats) stats.Add(t);
        }
        return (keyframes, stats);
    }

    [Fact]
    public void KeyframeIsRequestedEveryTwoAndAHalfSecondsForTwentySeconds()
    {
        var watch = new XboxFirstFrameWatch();
        var (keyframes, _) = Run(watch);
        Assert.Equal([0, 2500, 5000, 7500, 10_000, 12_500, 15_000, 17_500, 20_000], keyframes);
        Assert.Equal(9, watch.KeyframesRequested);
    }

    [Fact]
    public void KeyframeWaitsUntilTrackAndControlChannelAreReady()
    {
        var (keyframes, _) = Run(new XboxFirstFrameWatch(), readyAtMs: 1500);
        Assert.Equal(1500, keyframes[0]);
        Assert.Equal(4000, keyframes[1]);
        Assert.All(keyframes, t => Assert.True(t <= 20_000));
    }

    [Fact]
    public void FirstFrameStopsKeyframesAndStats()
    {
        var watch = new XboxFirstFrameWatch();
        var (keyframes, stats) = Run(watch, frameAtMs: 6000);
        Assert.Equal([0, 2500, 5000], keyframes);
        Assert.Empty(stats);
        Assert.True(watch.FrameSeen);
        Assert.Equal(default, watch.Tick(Ms(40_000), true));
    }

    [Fact]
    public void StatsStartAfterTenSecondsAndRepeatEveryTenWithoutFrame()
    {
        var (_, stats) = Run(new XboxFirstFrameWatch(), untilMs: 60_000);
        Assert.Equal([10_000, 20_000, 30_000, 40_000, 50_000, 60_000], stats);
    }

    [Fact]
    public void FirstFrameLimitIsReportedOnceAfterThirtySeconds()
    {
        var watch = new XboxFirstFrameWatch();
        var limits = new List<double>();
        for (double t = 0; t <= 45_000; t += 500)
            if (watch.Tick(Ms(t), true).NoPicture) limits.Add(t);
        Assert.Equal([30_000], limits);
    }

    [Fact]
    public void FirstFrameBeforeTheLimitNeverReportsNoPicture()
    {
        var watch = new XboxFirstFrameWatch();
        Assert.False(watch.Tick(Ms(29_500), true).NoPicture);
        watch.FrameArrived();
        Assert.False(watch.Tick(Ms(31_000), true).NoPicture);
    }

    [Fact]
    public void DiagnosticLineNamesTheNegotiatedCodec()
    {
        using var report = JsonDocument.Parse("""
            [{"type":"inbound-rtp","id":"IV","kind":"video","packetsReceived":258,"bytesReceived":0,"codecId":"C1"},
             {"type":"codec","id":"C1","mimeType":"video/H264","sdpFmtpLine":"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f"}]
            """);
        var line = XboxStreamStats.Describe(Ms(10_000), false, 4, report.RootElement, "görüntü");
        Assert.Contains("çözücü kurulmadı, görüntü verisi gelmedi, kodek video/H264 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f; ses yok; aday seçilmedi", line);
    }

    [Fact]
    public void StalledClockDoesNotWriteMissedStatsTwice()
    {
        var watch = new XboxFirstFrameWatch();
        Assert.True(watch.Tick(Ms(35_000), false).LogStats);
        Assert.False(watch.Tick(Ms(35_500), false).LogStats);
        Assert.True(watch.Tick(Ms(40_000), false).LogStats);
    }

    private const string Report = """
        [
          {"type":"transport","id":"T01","selectedCandidatePairId":"CP2"},
          {"type":"candidate-pair","id":"CP1","localCandidateId":"L1","remoteCandidateId":"R1","state":"failed","nominated":false},
          {"type":"candidate-pair","id":"CP2","localCandidateId":"L2","remoteCandidateId":"R2","state":"succeeded","nominated":true},
          {"type":"local-candidate","id":"L2","candidateType":"host","protocol":"udp","networkType":"ethernet"},
          {"type":"remote-candidate","id":"R2","candidateType":"srflx","protocol":"udp"},
          {"type":"inbound-rtp","id":"IA","kind":"audio","packetsReceived":900,"bytesReceived":45000},
          {"type":"inbound-rtp","id":"IV","kind":"video","packetsReceived":1234,"bytesReceived":567890.0,"packetsLost":3,
           "framesDecoded":0,"framesDropped":0,"keyFramesDecoded":0,"pliCount":4,"decoderImplementation":"D3D11VideoDecoder"}
        ]
        """;

    [Fact]
    public void DiagnosticLineSummarisesVideoCandidatePairAndPicture()
    {
        using var report = JsonDocument.Parse(Report);
        var picture = XboxStreamStats.Picture(0, 0, 0, "visible", 0);
        Assert.Equal(
            "tanı (10 sn, ilk kare yok): keyframe isteği 5; video paket 1234, bayt 567890, kayıp 3, çözülen 0, düşen 0, anahtar kare 0, PLI 4, " +
            "çözücü D3D11VideoDecoder; ses paket 900, bayt 45000; aday yerel host/udp ağ ethernet, uzak srflx, durum succeeded; " +
            "görüntü readyState 0, 0x0, görünürlük visible, kare geri çağrısı 0",
            XboxStreamStats.Describe(Ms(10_400), false, 5, report.RootElement, picture));
    }

    [Fact]
    public void DiagnosticLineWithoutVideoOrSelectedPair()
    {
        using var report = JsonDocument.Parse("""[{"type":"candidate-pair","id":"CP1","state":"in-progress","nominated":false}]""");
        Assert.Equal("tanı (20 sn, ilk kare yok): keyframe isteği 0; video yok; ses yok; aday seçilmedi; görüntü readyState 2, 1920x1080, görünürlük hidden, kare geri çağrısı 0",
            XboxStreamStats.Describe(Ms(20_000), false, 0, report.RootElement, XboxStreamStats.Picture(2, 1920, 1080, "hidden", 0)));
    }

    [Fact]
    public void NominatedSucceededPairIsUsedWhenTransportHasNoSelection()
    {
        using var report = JsonDocument.Parse("""
            [{"type":"candidate-pair","id":"CP1","localCandidateId":"L1","remoteCandidateId":"R1","state":"succeeded","nominated":true},
             {"type":"local-candidate","id":"L1","candidateType":"relay","protocol":"tcp"}]
            """);
        var line = XboxStreamStats.Describe(Ms(10_000), false, 1, report.RootElement, "görüntü");
        Assert.Contains("aday yerel relay/tcp ağ ?, uzak ?, durum succeeded;", line);
    }

    /// <summary>#1416: video yalnız dolgu paketi (bayt 0); ses akıyor mu ayrı yazılır (Mac/iPhone ve Android'le aynı satır).</summary>
    [Fact]
    public void DiagnosticLineShowsAudioNextToPaddingOnlyVideo()
    {
        using var report = JsonDocument.Parse("""
            [{"type":"inbound-rtp","id":"IV","kind":"video","packetsReceived":151,"bytesReceived":0},
             {"type":"inbound-rtp","id":"IA","mediaType":"audio","packetsReceived":480,"bytesReceived":61234}]
            """);
        var line = XboxStreamStats.Describe(Ms(10_000), false, 5, report.RootElement, "görüntü");
        Assert.Contains("video paket 151, bayt 0,", line);
        Assert.Contains("; ses paket 480, bayt 61234; aday seçilmedi; görüntü", line);
    }

    /// <summary>#1416: input kanalının ServerMetadata iletisi baytlarıyla yazılır; titreşim (128) yazılmaz.</summary>
    [Fact]
    public void InputMessageLine()
    {
        byte[] metadata = [0x10, 0x00, 0x80, 0x07, 0x00, 0x00, 0x38, 0x04, 0x00, 0x00];
        Assert.Equal("ikili ileti, tür 16 (ServerMetadata), 10 bayt: 10 00 80 07 00 00 38 04 00 00", XboxInputMessage.Describe(metadata, metadata.Length));
        Assert.Null(XboxInputMessage.Describe([0x80, 0x00, 0x00], 3));
        Assert.Equal("ikili ileti, tür -1, 0 bayt", XboxInputMessage.Describe([], 0));
        // Oynatıcı sayfası yalnız ilk 32 baytı gönderir; tam uzunluk ayrıca gelir.
        byte[] head = [0x02, .. Enumerable.Repeat((byte)0xff, 31)];
        Assert.Equal("ikili ileti, tür 2, 40 bayt: 02 " + string.Join(" ", Enumerable.Repeat("ff", 31)) + " …", XboxInputMessage.Describe(head, 40));
    }
}
