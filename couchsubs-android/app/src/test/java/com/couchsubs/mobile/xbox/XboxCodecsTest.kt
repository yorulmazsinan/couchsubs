// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger

/** Xbox görüntü kodeği teklifi ve tanı satırının kodek/çözücü alanları (#1252); iPhone/Mac ve Windows testleriyle aynı. */
class XboxCodecsTest {
    private val h264Params = mapOf("level-asymmetry-allowed" to "1", "packetization-mode" to "1")
    private val baseline = XboxCodec("H264", h264Params + ("profile-level-id" to "42e01f"))
    private val vp8 = XboxCodec("VP8", emptyMap())
    private val vp9 = XboxCodec("VP9", mapOf("profile-id" to "0"))
    private val av1 = XboxCodec("AV1", emptyMap())

    /** #1252'deki Poco M6 Pro'nun (c2.mtk) libwebrtc'den aldığı sıra: yazılım VP8/VP9/AV1, donanım yalnız Baseline. */
    private val mtk = listOf(vp8, vp9, av1, baseline)

    @Test fun highProfileIsOfferedFirstWhenHardwareDecodesIt() {
        val ordered = XboxCodecOrder.order(mtk, highSupported = true)
        assertEquals(listOf("640c1f", "42e01f"), ordered.take(2).map { XboxCodecOrder.profile(it) })
        assertEquals(h264Params + ("profile-level-id" to "640c1f"), ordered[0].params)
        assertEquals(listOf(vp8, vp9, av1), ordered.drop(2))
    }

    @Test fun withoutHighSupportOnlyTheOrderChanges() {
        assertEquals(listOf(baseline, vp8, vp9, av1), XboxCodecOrder.order(mtk, highSupported = false))
    }

    @Test fun highIsNotAddedTwiceWhenLibwebrtcAlreadyOffersIt() {
        // OMX.qcom çözücülü eski telefonlarda (#285) libwebrtc High'ı kendisi ekler.
        val high = XboxCodec("H264", h264Params + ("profile-level-id" to "640c1f"))
        val ordered = XboxCodecOrder.order(listOf(vp8, high, baseline, baseline), highSupported = true)
        assertEquals(listOf(high, baseline, vp8), ordered)
    }

    /** #1252: ilk donanım çözücüsü High bildirmese de telefonda H.264 çözücüsü varsa High teklif edilir. */
    @Test fun anyH264DecoderOffersHighAndIsNamedInTheLog() {
        val decoders = listOf(XboxAvcDecoder("c2.mtk.avc.decoder", hardware = true, high = false),
            XboxAvcDecoder("c2.android.avc.decoder", hardware = false, high = true))
        assertTrue(XboxAvcDecoders.offersHigh(decoders))
        assertTrue(XboxAvcDecoders.offersHigh(decoders.take(1)))
        assertEquals("H.264 çözücüleri: c2.mtk.avc.decoder (donanım, High yok), c2.android.avc.decoder (yazılım, High); " +
            "High (640c1f) teklif ediliyor", XboxAvcDecoders.note(decoders))
        assertEquals(false, XboxAvcDecoders.offersHigh(emptyList()))
        assertEquals("H.264 çözücüsü yok; High teklif edilmiyor", XboxAvcDecoders.note(emptyList()))
    }

    @Test fun noH264MeansNothingIsInvented() {
        assertEquals(listOf(vp8, vp9), XboxCodecOrder.order(listOf(vp8, vp9), highSupported = true))
    }

    private val offer = listOf(
        "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1; stereo=1",
        "m=video 9 UDP/TLS/RTP/SAVPF 102 103 96 97 98 35",
        "a=rtpmap:102 H264/90000", "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f",
        "a=rtpmap:103 rtx/90000", "a=fmtp:103 apt=102",
        "a=rtpmap:96 H264/90000", "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
        "a=rtpmap:97 VP8/90000", "a=rtpmap:98 VP9/90000", "a=rtpmap:35 AV1/90000",
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
    ).joinToString("\r\n", postfix = "\r\n")

    private val answer = listOf(
        "v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2",
        "m=video 9 UDP/TLS/RTP/SAVPF 102 103",
        "a=rtpmap:102 H264/90000", "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640C1F",
        "a=rtpmap:103 rtx/90000", "a=fmtp:103 apt=102",
    ).joinToString("\r\n")

    @Test fun sdpVideoCodecsFollowTheMediaLineAndSkipRetransmission() {
        assertEquals(listOf("H264 640c1f", "H264 42e01f", "VP8", "VP9", "AV1"), XboxSdp.videoCodecs(offer))
        assertEquals("H264 640c1f", XboxSdp.negotiated(answer))
        assertEquals("SDP görüntü kodekleri: teklif H264 640c1f, H264 42e01f, VP8, VP9, AV1; Xbox yanıtı H264 640c1f",
            XboxSdp.summary(offer, answer))
    }

    @Test fun rejectedOrMissingVideoSectionHasNoCodec() {
        val rejected = "v=0\nm=video 0 UDP/TLS/RTP/SAVPF 96\na=rtpmap:96 H264/90000\n"
        assertNull(XboxSdp.negotiated(rejected))
        assertNull(XboxSdp.negotiated("v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"))
        assertEquals("SDP görüntü kodekleri: teklif H264 640c1f, H264 42e01f, VP8, VP9, AV1; Xbox yanıtı görüntü yok",
            XboxSdp.summary(offer, rejected))
    }

    /** #1252: dolgu paketleri sayılıyor, bayt 0, çözücü kurulmamış, getStats'ta kodek yok. */
    private val paddingOnly = listOf(XboxStat("inbound-rtp", "IV", mapOf("kind" to "video", "packetsReceived" to 150L,
        "bytesReceived" to BigInteger.ZERO, "packetsLost" to 0, "framesDecoded" to 0L, "framesDropped" to 0L,
        "keyFramesDecoded" to 0L, "pliCount" to 0L)))

    @Test fun diagnosticLineNamesSdpCodecAndMissingDecoderWhenNoVideoBytesArrive() {
        val line = XboxStreamStats.describe(10_000, false, 5, paddingOnly, "görüntü parça LIVE", negotiatedCodec = "H264 42e01f")
        assertEquals("tanı (10 sn, ilk kare yok): keyframe isteği 5; video paket 150, bayt 0, kayıp 0, çözülen 0, düşen 0, " +
            "anahtar kare 0, PLI 0, çözücü kurulmadı, görüntü verisi gelmedi, kodek H264 42e01f (SDP yanıtı); aday seçilmedi; " +
            "görüntü parça LIVE", line)
    }

    @Test fun diagnosticLineUsesTheAppsDecoderNoteBeforeGuessing() {
        val note = XboxDecoderNote()
        assertNull(note.describe())
        note.created("H264", "c2.mtk.avc.decoder", hardware = true)
        note.initFailed("c2.mtk.avc.decoder", "ERROR")
        assertEquals("H264 c2.mtk.avc.decoder (donanım); c2.mtk.avc.decoder başlatılamadı: ERROR", note.describe())
        val line = XboxStreamStats.describe(10_000, false, 5, paddingOnly, "görüntü", "H264 640c1f", note.describe())
        assertTrue(line, line.contains("çözücü H264 c2.mtk.avc.decoder (donanım); c2.mtk.avc.decoder başlatılamadı: ERROR, kodek H264 640c1f (SDP yanıtı);"))
    }

    @Test fun statsDecoderAndCodecWinOverAppNotes() {
        val stats = listOf(
            XboxStat("inbound-rtp", "IV", mapOf("kind" to "video", "bytesReceived" to BigInteger.TEN, "codecId" to "C1",
                "decoderImplementation" to "c2.qti.avc.decoder")),
            XboxStat("codec", "C1", mapOf("mimeType" to "video/H264", "sdpFmtpLine" to "profile-level-id=640c1f")),
        )
        val line = XboxStreamStats.describe(10_000, true, 1, stats, "görüntü", "H264 42e01f", "H264 başka (donanım)")
        assertTrue(line, line.contains("çözücü c2.qti.avc.decoder, kodek video/H264 profile-level-id=640c1f;"))
    }

    @Test fun unknownDecoderWithVideoBytesStaysQuestionMark() {
        val stats = listOf(XboxStat("inbound-rtp", "IV", mapOf("kind" to "video", "bytesReceived" to 500L)))
        assertTrue(XboxStreamStats.describe(10_000, false, 1, stats, "görüntü").contains("çözücü ?;"))
    }
}
