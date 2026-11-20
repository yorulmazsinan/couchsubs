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
        XboxStat("inbound-rtp", "IA", mapOf("kind" to "audio", "packetsReceived" to 900L)),
        // libwebrtc uint64 alanlarını BigInteger, sayaçları Long/Integer olarak verir.
        XboxStat("inbound-rtp", "IV", mapOf("kind" to "video", "packetsReceived" to 1234L, "bytesReceived" to BigInteger.valueOf(567890),
            "packetsLost" to 3, "framesDecoded" to 0L, "framesDropped" to 0L, "keyFramesDecoded" to 0L, "pliCount" to 4L,
            "decoderImplementation" to "c2.qti.avc.decoder")),
    )

    @Test fun diagnosticLineSummarisesVideoCandidatePairAndPicture() {
        assertEquals(
            "tanı (10 sn, ilk kare yok): keyframe isteği 5; video paket 1234, bayt 567890, kayıp 3, çözülen 0, düşen 0, anahtar kare 0, PLI 4, " +
                "çözücü c2.qti.avc.decoder; aday yerel host/udp ağ wifi, uzak srflx, durum succeeded; görüntü parça LIVE",
            XboxStreamStats.describe(10_400, false, 5, report, XboxStreamStats.picture("LIVE")),
        )
    }

    @Test fun diagnosticLineWithoutVideoOrSelectedPair() {
        val stats = listOf(XboxStat("candidate-pair", "CP1", mapOf("state" to "in-progress", "nominated" to false)))
        assertEquals("tanı (20 sn, ilk kare yok): keyframe isteği 0; video yok; aday seçilmedi; görüntü parça ENDED",
            XboxStreamStats.describe(20_000, false, 0, stats, XboxStreamStats.picture("ENDED")))
    }

    @Test fun nominatedSucceededPairIsUsedWhenTransportHasNoSelection() {
        val stats = listOf(
            XboxStat("candidate-pair", "CP1", mapOf("localCandidateId" to "L1", "remoteCandidateId" to "R1", "state" to "succeeded", "nominated" to true)),
            XboxStat("local-candidate", "L1", mapOf("candidateType" to "relay", "protocol" to "tcp")),
        )
        assertTrue(XboxStreamStats.describe(10_000, false, 1, stats, "görüntü").contains("aday yerel relay/tcp ağ ?, uzak ?, durum succeeded;"))
    }
}
