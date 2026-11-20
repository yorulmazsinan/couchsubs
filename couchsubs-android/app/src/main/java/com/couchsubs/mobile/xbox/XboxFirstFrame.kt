// SPDX-License-Identifier: AGPL-3.0-only
// Xbox görüntüsü başlayana kadar yapılanlar (#403, #530). Xbox kare onayı alamazsa oturumu ~60 sn sonra kapatır; onay
// yalnız çözülen karede gider, kare hiç gelmezse onay da gitmez. İlk kare gelene kadar kontrol kanalından anahtar kare
// istenir (xbox-xcloud-player 0.2.11 Channel/Control.ts `requestKeyframeRequest`; XStreaming de ister) ve bağlantıdan
// 10 sn sonra, sonra 10 sn'de bir getStats tanı satırı yazılır. Windows'taki CouchSubs.Shell/XboxFirstFrameWatch.cs ile
// birebir (zamanlama ve satır biçimi).
package com.couchsubs.mobile.xbox

/** Bir saat adımında yapılacaklar: Xbox'tan anahtar kare istenir mi, tanı satırı yazılır mı. */
data class XboxWatchStep(val requestKeyframe: Boolean = false, val logStats: Boolean = false)

class XboxFirstFrameWatch {
    companion object {
        const val KEYFRAME_INTERVAL_MS = 2500L
        /** Bu süreden sonra anahtar kare istenmez; tanı satırları sürer. */
        const val KEYFRAME_WINDOW_MS = 20_000L
        const val STATS_DELAY_MS = 10_000L
        const val STATS_INTERVAL_MS = 10_000L
        /** Kontrol kanalı iletisi (Control.ts `requestKeyframeRequest`). */
        const val KEYFRAME_REQUEST = "{\"message\":\"videoKeyframeRequested\",\"ifrRequested\":true}"
    }

    private var lastKeyframe: Long? = null
    private var nextStats = STATS_DELAY_MS

    /** İlk kare geldi; bundan sonra hiçbir şey yapılmaz. */
    @Volatile var frameSeen = false
        private set
    @Volatile var keyframesRequested = 0
        private set

    fun frameArrived() {
        frameSeen = true
    }

    /**
     * [sinceConnectedMs]: bağlantıdan (input kanalı açıldı) bu yana geçen süre. [keyframeReady]: görüntü parçası var ve
     * kontrol kanalı açık.
     */
    @Synchronized fun tick(sinceConnectedMs: Long, keyframeReady: Boolean): XboxWatchStep {
        if (frameSeen) return XboxWatchStep()
        val last = lastKeyframe
        val keyframe = keyframeReady && sinceConnectedMs <= KEYFRAME_WINDOW_MS && (last == null || sinceConnectedMs - last >= KEYFRAME_INTERVAL_MS)
        if (keyframe) {
            lastKeyframe = sinceConnectedMs
            keyframesRequested++
        }
        val stats = sinceConnectedMs >= nextStats
        // Saat takıldıysa kaçan satırlar art arda yazılmaz.
        if (stats) while (nextStats <= sinceConnectedMs) nextStats += STATS_INTERVAL_MS
        return XboxWatchStep(keyframe, stats)
    }
}

/** getStats raporunun bir girdisi (RTCStats: tür, kimlik, alanlar). */
data class XboxStat(val type: String, val id: String, val members: Map<String, Any?>)

/** WebRTC getStats özetini tek günlük satırına çevirir; Windows'taki XboxStreamStats ile aynı biçim. */
object XboxStreamStats {
    val TYPES = setOf("inbound-rtp", "candidate-pair", "local-candidate", "remote-candidate", "transport")

    /** Telefonda video öğesi yok: görüntü parçasının durumu (LIVE, ENDED). */
    fun picture(trackState: String): String = "görüntü parça $trackState"

    fun describe(sinceConnectedMs: Long, frameSeen: Boolean, keyframes: Int, stats: List<XboxStat>, picture: String): String = buildString {
        append("tanı (${sinceConnectedMs / 1000} sn, ${if (frameSeen) "ilk kare geldi" else "ilk kare yok"}): keyframe isteği $keyframes; ")
        val video = stats.firstOrNull { it.type == "inbound-rtp" && (text(it, "kind") ?: text(it, "mediaType")) == "video" }
        if (video != null) {
            append("video paket ${number(video, "packetsReceived")}, bayt ${number(video, "bytesReceived")}, kayıp ${number(video, "packetsLost")}, ")
            append("çözülen ${number(video, "framesDecoded")}, düşen ${number(video, "framesDropped")}, anahtar kare ${number(video, "keyFramesDecoded")}, ")
            append("PLI ${number(video, "pliCount")}, çözücü ${text(video, "decoderImplementation") ?: "?"}; ")
        } else {
            append("video yok; ")
        }
        val pair = selectedPair(stats)
        if (pair != null) {
            val local = byId(stats, text(pair, "localCandidateId"))
            val remote = byId(stats, text(pair, "remoteCandidateId"))
            append("aday yerel ${field(local, "candidateType")}/${field(local, "protocol")} ağ ${field(local, "networkType")}, ")
            append("uzak ${field(remote, "candidateType")}, durum ${text(pair, "state") ?: "?"}; ")
        } else {
            append("aday seçilmedi; ")
        }
        append(picture)
    }

    private fun selectedPair(stats: List<XboxStat>): XboxStat? {
        for (transport in stats.filter { it.type == "transport" }) {
            byId(stats, text(transport, "selectedCandidatePairId"))?.let { return it }
        }
        val pairs = stats.filter { it.type == "candidate-pair" }
        return pairs.firstOrNull { it.members["selected"] == true }
            ?: pairs.firstOrNull { it.members["nominated"] == true && text(it, "state") == "succeeded" }
    }

    private fun byId(stats: List<XboxStat>, id: String?): XboxStat? = id?.let { wanted -> stats.firstOrNull { it.id == wanted } }

    private fun field(stat: XboxStat?, name: String): String = stat?.let { text(it, name) } ?: "?"

    /** libwebrtc bazı metin alanlarını (ör. RTCStatsIceCandidatePairState) Java'ya enum adıyla da verebilir. */
    private fun text(stat: XboxStat, name: String): String? = stat.members[name]?.takeIf { it !is Number && it !is Boolean }?.toString()

    private fun number(stat: XboxStat, name: String): String = (stat.members[name] as? Number)?.toLong()?.toString() ?: "?"
}
