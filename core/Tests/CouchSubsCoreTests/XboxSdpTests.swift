// SPDX-License-Identifier: AGPL-3.0-only
// SDP'deki görüntü kodekleri ve tanı satırının kodek/çözücü alanları (#1252). Android'deki XboxCodecsTest ve
// Windows'taki XboxSdpTests ile aynı durumlar.

import XCTest
@testable import CouchSubsCore

final class XboxSdpTests: XCTestCase {
    private let offer = [
        "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1; stereo=1",
        "m=video 9 UDP/TLS/RTP/SAVPF 102 103 96 97 98 35",
        "a=rtpmap:102 H264/90000", "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f",
        "a=rtpmap:103 rtx/90000", "a=fmtp:103 apt=102",
        "a=rtpmap:96 H264/90000", "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
        "a=rtpmap:97 VP8/90000", "a=rtpmap:98 VP9/90000", "a=rtpmap:35 AV1/90000",
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
    ].joined(separator: "\r\n") + "\r\n"

    private let answer = [
        "v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2",
        "m=video 9 UDP/TLS/RTP/SAVPF 102 103",
        "a=rtpmap:102 H264/90000", "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640C1F",
        "a=rtpmap:103 rtx/90000", "a=fmtp:103 apt=102",
    ].joined(separator: "\r\n")

    func testVideoCodecsFollowTheMediaLineAndSkipRetransmission() {
        XCTAssertEqual(XboxSdp.videoCodecs(offer), ["H264 640c1f", "H264 42e01f", "VP8", "VP9", "AV1"])
        XCTAssertEqual(XboxSdp.negotiated(answer), "H264 640c1f")
        XCTAssertEqual(XboxSdp.summary(offer: offer, answer: answer),
                       "SDP görüntü kodekleri: teklif H264 640c1f, H264 42e01f, VP8, VP9, AV1; Xbox yanıtı H264 640c1f")
    }

    func testRejectedOrMissingVideoSectionHasNoCodec() {
        let rejected = "v=0\nm=video 0 UDP/TLS/RTP/SAVPF 96\na=rtpmap:96 H264/90000\n"
        XCTAssertNil(XboxSdp.negotiated(rejected))
        XCTAssertNil(XboxSdp.negotiated("v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"))
        XCTAssertEqual(XboxSdp.summary(offer: offer, answer: rejected),
                       "SDP görüntü kodekleri: teklif H264 640c1f, H264 42e01f, VP8, VP9, AV1; Xbox yanıtı görüntü yok")
    }

    /// #1252: dolgu paketleri sayılıyor, bayt 0, çözücü kurulmamış, getStats'ta kodek yok.
    private let paddingOnly = [XboxStat(type: "inbound-rtp", id: "IV", members: [
        "kind": "video", "packetsReceived": 150, "bytesReceived": 0, "packetsLost": 0, "framesDecoded": 0, "framesDropped": 0,
        "keyFramesDecoded": 0, "pliCount": 0,
    ])]

    func testDiagnosticLineNamesSdpCodecAndMissingDecoderWhenNoVideoBytesArrive() {
        let line = XboxStreamStats.describe(sinceConnectedMs: 10_000, frameSeen: false, keyframes: 5, stats: paddingOnly,
                                            picture: "görüntü parça LIVE", negotiatedCodec: "H264 42e01f")
        XCTAssertEqual(line, "tanı (10 sn, ilk kare yok): keyframe isteği 5; video paket 150, bayt 0, kayıp 0, çözülen 0, düşen 0, "
            + "anahtar kare 0, PLI 0, çözücü kurulmadı, görüntü verisi gelmedi, kodek H264 42e01f (SDP yanıtı); ses yok; aday seçilmedi; "
            + "görüntü parça LIVE")
    }

    func testDiagnosticLineUsesTheAppsDecoderNoteBeforeGuessing() {
        let line = XboxStreamStats.describe(sinceConnectedMs: 10_000, frameSeen: false, keyframes: 5, stats: paddingOnly,
                                            picture: "görüntü", negotiatedCodec: "H264 640c1f", decoder: "H264 VideoToolbox (donanım)")
        XCTAssertTrue(line.contains("çözücü H264 VideoToolbox (donanım), kodek H264 640c1f (SDP yanıtı);"), line)
    }

    func testStatsDecoderAndCodecWinOverAppNotes() {
        let stats = [
            XboxStat(type: "inbound-rtp", id: "IV", members: ["kind": "video", "bytesReceived": 10, "codecId": "C1",
                                                               "decoderImplementation": "VideoToolbox"]),
            XboxStat(type: "codec", id: "C1", members: ["mimeType": "video/H264", "sdpFmtpLine": "profile-level-id=640c1f"]),
        ]
        let line = XboxStreamStats.describe(sinceConnectedMs: 10_000, frameSeen: true, keyframes: 1, stats: stats, picture: "görüntü",
                                            negotiatedCodec: "H264 42e01f", decoder: "H264 başka (yazılım)")
        XCTAssertTrue(line.contains("çözücü VideoToolbox, kodek video/H264 profile-level-id=640c1f;"), line)
    }

    func testUnknownDecoderWithVideoBytesStaysQuestionMark() {
        let stats = [XboxStat(type: "inbound-rtp", id: "IV", members: ["kind": "video", "bytesReceived": 500])]
        XCTAssertTrue(XboxStreamStats.describe(sinceConnectedMs: 10_000, frameSeen: false, keyframes: 1, stats: stats, picture: "görüntü")
            .contains("çözücü ?;"))
    }
}
