// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;

namespace CouchSubs.Shell.Tests;

/// <summary>
/// SDP'deki görüntü kodekleri ve tanı satırının kodek/çözücü alanları (#1252). Android'deki XboxCodecsTest ve
/// iPhone/Mac'teki XboxSdpTests ile aynı durumlar.
/// </summary>
public class XboxSdpTests
{
    private static readonly string Offer = string.Join("\r\n",
        "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1; stereo=1",
        "m=video 9 UDP/TLS/RTP/SAVPF 102 103 96 97 98 35",
        "a=rtpmap:102 H264/90000", "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f",
        "a=rtpmap:103 rtx/90000", "a=fmtp:103 apt=102",
        "a=rtpmap:96 H264/90000", "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
        "a=rtpmap:97 VP8/90000", "a=rtpmap:98 VP9/90000", "a=rtpmap:35 AV1/90000",
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel") + "\r\n";

    private static readonly string Answer = string.Join("\r\n",
        "v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2",
        "m=video 9 UDP/TLS/RTP/SAVPF 102 103",
        "a=rtpmap:102 H264/90000", "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640C1F",
        "a=rtpmap:103 rtx/90000", "a=fmtp:103 apt=102");

    private static TimeSpan Ms(double value) => TimeSpan.FromMilliseconds(value);

    [Fact]
    public void VideoCodecsFollowTheMediaLineAndSkipRetransmission()
    {
        Assert.Equal(["H264 640c1f", "H264 42e01f", "VP8", "VP9", "AV1"], XboxSdp.VideoCodecs(Offer));
        Assert.Equal("H264 640c1f", XboxSdp.Negotiated(Answer));
        Assert.Equal("SDP görüntü kodekleri: teklif H264 640c1f, H264 42e01f, VP8, VP9, AV1; Xbox yanıtı H264 640c1f",
            XboxSdp.Summary(Offer, Answer));
    }

    [Fact]
    public void RejectedOrMissingVideoSectionHasNoCodec()
    {
        const string rejected = "v=0\nm=video 0 UDP/TLS/RTP/SAVPF 96\na=rtpmap:96 H264/90000\n";
        Assert.Null(XboxSdp.Negotiated(rejected));
        Assert.Null(XboxSdp.Negotiated("v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"));
        Assert.Null(XboxSdp.Negotiated(null));
        Assert.Equal("SDP görüntü kodekleri: teklif H264 640c1f, H264 42e01f, VP8, VP9, AV1; Xbox yanıtı görüntü yok",
            XboxSdp.Summary(Offer, rejected));
    }

    /// <summary>#1252: dolgu paketleri sayılıyor, bayt 0, çözücü kurulmamış, getStats'ta kodek yok.</summary>
    private const string PaddingOnly = """
        [{"type":"inbound-rtp","id":"IV","kind":"video","packetsReceived":150,"bytesReceived":0,"packetsLost":0,
          "framesDecoded":0,"framesDropped":0,"keyFramesDecoded":0,"pliCount":0}]
        """;

    [Fact]
    public void DiagnosticLineNamesSdpCodecAndMissingDecoderWhenNoVideoBytesArrive()
    {
        using var report = JsonDocument.Parse(PaddingOnly);
        Assert.Equal("tanı (10 sn, ilk kare yok): keyframe isteği 5; video paket 150, bayt 0, kayıp 0, çözülen 0, düşen 0, " +
            "anahtar kare 0, PLI 0, çözücü kurulmadı, görüntü verisi gelmedi, kodek H264 42e01f (SDP yanıtı); ses yok; aday seçilmedi; " +
            "görüntü parça LIVE",
            XboxStreamStats.Describe(Ms(10_000), false, 5, report.RootElement, "görüntü parça LIVE", "H264 42e01f"));
    }

    [Fact]
    public void DiagnosticLineUsesTheAppsDecoderNoteBeforeGuessing()
    {
        using var report = JsonDocument.Parse(PaddingOnly);
        var line = XboxStreamStats.Describe(Ms(10_000), false, 5, report.RootElement, "görüntü", "H264 640c1f", "H264 D3D11 (donanım)");
        Assert.Contains("çözücü H264 D3D11 (donanım), kodek H264 640c1f (SDP yanıtı);", line);
    }

    [Fact]
    public void StatsDecoderAndCodecWinOverAppNotes()
    {
        using var report = JsonDocument.Parse("""
            [{"type":"inbound-rtp","id":"IV","kind":"video","bytesReceived":10,"codecId":"C1","decoderImplementation":"D3D11VideoDecoder"},
             {"type":"codec","id":"C1","mimeType":"video/H264","sdpFmtpLine":"profile-level-id=640c1f"}]
            """);
        var line = XboxStreamStats.Describe(Ms(10_000), true, 1, report.RootElement, "görüntü", "H264 42e01f", "H264 başka (yazılım)");
        Assert.Contains("çözücü D3D11VideoDecoder, kodek video/H264 profile-level-id=640c1f;", line);
    }

    [Fact]
    public void UnknownDecoderWithVideoBytesStaysQuestionMark()
    {
        using var report = JsonDocument.Parse("""[{"type":"inbound-rtp","id":"IV","kind":"video","bytesReceived":500}]""");
        Assert.Contains("çözücü ?;", XboxStreamStats.Describe(Ms(10_000), false, 1, report.RootElement, "görüntü"));
    }
}
