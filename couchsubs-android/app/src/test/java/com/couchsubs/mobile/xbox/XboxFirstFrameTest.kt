// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger

/** Xbox görüntüsü başlayana kadar anahtar kare isteği ve tanı satırı (#403, #530); Windows testleriyle aynı. */
class XboxFirstFrameTest {
    /** 0-[untilMs] arasını 500 ms'lik adımlarla yürütür (oturumdaki saat gibi); isteklerin ve tanıların anları. */
    private fun run(watch: XboxFirstFrameWatch, untilMs: Long = 30_000, readyAtMs: Long = 0, frameAtMs: Long? = null): Pair<List<Long>, List<Long>> {
        val keyframes = ArrayList<Long>()
        val stats = ArrayList<Long>()
        var t = 0L
        while (t <= untilMs) {
            if (frameAtMs != null && t >= frameAtMs) watch.frameArrived()
            val step = watch.tick(t, t >= readyAtMs)
            if (step.requestKeyframe) keyframes += t
            if (step.logStats) stats += t
            t += 500
        }
        return keyframes to stats
    }

    @Test fun keyframeIsRequestedEveryTwoAndAHalfSecondsForTwentySeconds() {
        val watch = XboxFirstFrameWatch()
        val (keyframes, _) = run(watch)
        assertEquals(listOf(0L, 2500, 5000, 7500, 10_000, 12_500, 15_000, 17_500, 20_000), keyframes)
        assertEquals(9, watch.keyframesRequested)
    }

    @Test fun keyframeWaitsUntilTrackAndControlChannelAreReady() {
        val (keyframes, _) = run(XboxFirstFrameWatch(), readyAtMs = 1500)
        assertEquals(1500L, keyframes[0])
        assertEquals(4000L, keyframes[1])
        assertTrue(keyframes.all { it <= 20_000 })
    }

    @Test fun firstFrameStopsKeyframesAndStats() {
        val watch = XboxFirstFrameWatch()
        val (keyframes, stats) = run(watch, frameAtMs = 6000)
        assertEquals(listOf(0L, 2500, 5000), keyframes)
        assertTrue(stats.isEmpty())
        assertTrue(watch.frameSeen)
        assertEquals(XboxWatchStep(), watch.tick(40_000, true))
    }

    @Test fun statsStartAfterTenSecondsAndRepeatEveryTenWithoutFrame() {
        val (_, stats) = run(XboxFirstFrameWatch(), untilMs = 60_000)
        assertEquals(listOf(10_000L, 20_000, 30_000, 40_000, 50_000, 60_000), stats)
    }

    @Test fun stalledClockDoesNotWriteMissedStatsTwice() {
        val watch = XboxFirstFrameWatch()
        assertTrue(watch.tick(35_000, false).logStats)
        assertFalse(watch.tick(35_500, false).logStats)
        assertTrue(watch.tick(40_000, false).logStats)
    }

    @Test fun keyframeRequestMatchesXcloudPlayer() {
        val message = JSONObject(XboxFirstFrameWatch.KEYFRAME_REQUEST)
        assertEquals("videoKeyframeRequested", message.getString("message"))
        assertTrue(message.getBoolean("ifrRequested"))
        assertEquals(2, message.length())
    }

    private val report = listOf(
        XboxStat("transport", "T01", mapOf("selectedCandidatePairId" to "CP2")),
        XboxStat("candidate-pair", "CP1", mapOf("localCandidateId" to "L1", "remoteCandidateId" to "R1", "state" to "failed", "nominated" to false)),
        XboxStat("candidate-pair", "CP2", mapOf("localCandidateId" to "L2", "remoteCandidateId" to "R2", "state" to "succeeded", "nominated" to true)),
        XboxStat("local-candidate", "L2", mapOf("candidateType" to "host", "protocol" to "udp", "networkType" to "wifi")),
        XboxStat("remote-candidate", "R2", mapOf("candidateType" to "srflx", "protocol" to "udp")),
        XboxStat("inbound-rtp", "IA", mapOf("kind" to "audio", "packetsReceived" to 900L, "bytesReceived" to BigInteger.valueOf(45000))),
        // libwebrtc uint64 alanlarını BigInteger, sayaçları Long/Integer olarak verir.
        XboxStat("inbound-rtp", "IV", mapOf("kind" to "video", "packetsReceived" to 1234L, "bytesReceived" to BigInteger.valueOf(567890),
            "packetsLost" to 3, "framesDecoded" to 0L, "framesDropped" to 0L, "keyFramesDecoded" to 0L, "pliCount" to 4L,
            "decoderImplementation" to "c2.qti.avc.decoder")),
    )

    @Test fun diagnosticLineSummarisesVideoCandidatePairAndPicture() {
        assertEquals(
            "tanı (10 sn, ilk kare yok): keyframe isteği 5; video paket 1234, bayt 567890, kayıp 3, çözülen 0, düşen 0, anahtar kare 0, PLI 4, " +
                "çözücü c2.qti.avc.decoder; ses paket 900, bayt 45000; aday yerel host/udp ağ wifi, uzak srflx, durum succeeded; görüntü parça LIVE",
            XboxStreamStats.describe(10_400, false, 5, report, XboxStreamStats.picture("LIVE")),
        )
    }

    @Test fun diagnosticLineWithoutVideoOrSelectedPair() {
        val stats = listOf(XboxStat("candidate-pair", "CP1", mapOf("state" to "in-progress", "nominated" to false)))
        assertEquals("tanı (20 sn, ilk kare yok): keyframe isteği 0; video yok; ses yok; aday seçilmedi; görüntü parça ENDED",
            XboxStreamStats.describe(20_000, false, 0, stats, XboxStreamStats.picture("ENDED")))
    }

    @Test fun nominatedSucceededPairIsUsedWhenTransportHasNoSelection() {
        val stats = listOf(
            XboxStat("candidate-pair", "CP1", mapOf("localCandidateId" to "L1", "remoteCandidateId" to "R1", "state" to "succeeded", "nominated" to true)),
            XboxStat("local-candidate", "L1", mapOf("candidateType" to "relay", "protocol" to "tcp")),
        )
        assertTrue(XboxStreamStats.describe(10_000, false, 1, stats, "görüntü").contains("aday yerel relay/tcp ağ ?, uzak ?, durum succeeded;"))
    }

    @Test fun diagnosticLineNamesTheNegotiatedCodec() {
        val stats = listOf(
            XboxStat("inbound-rtp", "IV", mapOf("kind" to "video", "packetsReceived" to 258L, "bytesReceived" to BigInteger.ZERO, "codecId" to "C1")),
            XboxStat("codec", "C1", mapOf("mimeType" to "video/H264", "sdpFmtpLine" to "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f")),
        )
        val line = XboxStreamStats.describe(10_000, false, 4, stats, "görüntü")
        assertTrue(line, line.contains("çözücü kurulmadı, görüntü verisi gelmedi, kodek video/H264 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f; ses yok; aday seçilmedi"))
        assertTrue("codec" in XboxStreamStats.TYPES)
    }

    /** #1416: video yalnız dolgu paketi (bayt 0); ses akıyor mu ayrı yazılır (iPhone/Mac ve Windows'la aynı satır). */
    @Test fun diagnosticLineShowsAudioNextToPaddingOnlyVideo() {
        val stats = listOf(
            XboxStat("inbound-rtp", "IV", mapOf("kind" to "video", "packetsReceived" to 151L, "bytesReceived" to BigInteger.ZERO)),
            XboxStat("inbound-rtp", "IA", mapOf("mediaType" to "audio", "packetsReceived" to 480L, "bytesReceived" to BigInteger.valueOf(61234))),
        )
        val line = XboxStreamStats.describe(10_000, false, 5, stats, "görüntü")
        assertTrue(line, line.contains("video paket 151, bayt 0,"))
        assertTrue(line, line.contains("; ses paket 480, bayt 61234; aday seçilmedi; görüntü"))
    }

    /** #1416: input kanalının ServerMetadata iletisi baytlarıyla yazılır; titreşim (128) yazılmaz. */
    @Test fun inputMessageLine() {
        val metadata = byteArrayOf(0x10, 0x00, 0x80.toByte(), 0x07, 0x00, 0x00, 0x38, 0x04, 0x00, 0x00)
        assertEquals("ikili ileti, tür 16 (ServerMetadata), 10 bayt: 10 00 80 07 00 00 38 04 00 00", XboxChannels.describeInput(metadata))
        assertEquals(null, XboxChannels.describeInput(byteArrayOf(0x80.toByte(), 0x00, 0x00)))
        assertEquals("ikili ileti, tür -1, 0 bayt", XboxChannels.describeInput(ByteArray(0)))
        val long = byteArrayOf(0x02) + ByteArray(39) { 0xff.toByte() }
        assertEquals("ikili ileti, tür 2, 40 bayt: 02 " + List(31) { "ff" }.joinToString(" ") + " …", XboxChannels.describeInput(long))
    }
}
