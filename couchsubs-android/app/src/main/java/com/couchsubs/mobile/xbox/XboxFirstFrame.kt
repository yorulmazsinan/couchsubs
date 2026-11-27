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
        /**
         * Bağlantıdan sonra ilk kare için beklenen en uzun süre; dolunca bağlantı NO_FIRST_FRAME ile kapatılır, Xbox'ın
         * kendisi kapatması (~60 sn) beklenmez (Windows, iPhone ve Mac'te de 30 sn).
         */
        const val FIRST_FRAME_LIMIT_MS = 30_000L
        const val KEYFRAME_INTERVAL_MS = 2500L
        /** Bu süreden sonra anahtar kare istenmez; tanı satırları sürer. */
        const val KEYFRAME_WINDOW_MS = 20_000L
        const val STATS_DELAY_MS = 10_000L
        const val STATS_INTERVAL_MS = 10_000L
        /** Kontrol kanalı iletisi (Control.ts `requestKeyframeRequest`). */
        const val KEYFRAME_REQUEST = "{\"message\":\"videoKeyframeRequested\",\"ifrRequested\":true}"

        /**
         * İlk kare sınırı dolunca bağlantıyı bitiren neden. [audioOnly]: son tanıda ses geliyordu, görüntü 0 bayttı
         * ([XboxStreamStats.audioOnly]); nedene [XboxSessionMachine.AUDIO_ONLY_NOTE] eklenir, ekranda "Xbox'u tam kapatıp
         * açın" çıkar ve yeniden denenmez (#1432, #1416).
         */
        fun noPictureReason(audioOnly: Boolean): String =
            "Xbox'tan ${FIRST_FRAME_LIMIT_MS / 1000} sn içinde görüntü gelmedi" +
                if (audioOnly) " (${XboxSessionMachine.AUDIO_ONLY_NOTE})" else ""
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
    /** `codec`: anlaşılan görüntü kodeği tanı satırına girer. */
    val TYPES = setOf("inbound-rtp", "candidate-pair", "local-candidate", "remote-candidate", "transport", "codec")

    /** Telefonda video öğesi yok: görüntü parçasının durumu (LIVE, ENDED). */
    fun picture(trackState: String): String = "görüntü parça $trackState"

    /** Görüntü verisi hiç gelmediyse (bayt 0) libwebrtc çözücüyü kurmaz; "çözücü" alanı bunu söyler. */
    const val DECODER_NOT_STARTED = "kurulmadı, görüntü verisi gelmedi"

    /**
     * [negotiatedCodec]: Xbox'ın SDP yanıtında seçtiği görüntü kodeği (getStats kodeği ilk kareye kadar boştur).
     * [decoder]: uygulamanın bildiği çözücü durumu (ad, donanım/yazılım, başlatma hatası); getStats'ta yoksa kullanılır.
     */
    fun describe(
        sinceConnectedMs: Long, frameSeen: Boolean, keyframes: Int, stats: List<XboxStat>, picture: String,
        negotiatedCodec: String? = null, decoder: String? = null,
    ): String = buildString {
        append("tanı (${sinceConnectedMs / 1000} sn, ${if (frameSeen) "ilk kare geldi" else "ilk kare yok"}): keyframe isteği $keyframes; ")
        val video = stats.firstOrNull { it.type == "inbound-rtp" && (text(it, "kind") ?: text(it, "mediaType")) == "video" }
        if (video != null) {
            append("video paket ${number(video, "packetsReceived")}, bayt ${number(video, "bytesReceived")}, kayıp ${number(video, "packetsLost")}, ")
            append("çözülen ${number(video, "framesDecoded")}, düşen ${number(video, "framesDropped")}, anahtar kare ${number(video, "keyFramesDecoded")}, ")
            val noData = number(video, "bytesReceived") == "0"
            append("PLI ${number(video, "pliCount")}, çözücü ${text(video, "decoderImplementation") ?: decoder ?: if (noData) DECODER_NOT_STARTED else "?"}")
            val codec = byId(stats, text(video, "codecId"))
            if (codec != null) {
                append(", kodek ${text(codec, "mimeType") ?: "?"} ${text(codec, "sdpFmtpLine") ?: ""}".trimEnd())
            } else if (negotiatedCodec != null) {
                append(", kodek $negotiatedCodec (SDP yanıtı)")
            }
            append("; ")
        } else {
            append("video yok; ")
        }
        // Ses de geliyor mu (#1416): video yalnız dolgu paketiyken (bayt 0) ses akıyorsa Xbox yayını başlatmış, yalnız
        // görüntüyü kodlamıyor; ses de yoksa Xbox'ın yayın hizmeti hiç başlamamış.
        val audio = stats.firstOrNull { it.type == "inbound-rtp" && (text(it, "kind") ?: text(it, "mediaType")) == "audio" }
        if (audio != null) {
            append("ses paket ${number(audio, "packetsReceived")}, bayt ${number(audio, "bytesReceived")}; ")
        } else {
            append("ses yok; ")
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

    /**
     * Xbox ses gönderiyor ama görüntü göndermiyor (#1432, #1416): ses verisi var (bayt > 0), görüntü parçası yok ya da
     * yalnız boş (dolgu) paketleri geliyor (bayt 0). Aynı Xbox'ta aynı SDP yanıtıyla birkaç dakika önce görüntü gelen
     * oturumlar vardı: kodek ya da çözünürlük değil, Xbox'ın görüntü yayını takılı kalmış.
     */
    fun audioOnly(stats: List<XboxStat>): Boolean {
        fun bytes(kind: String): Double? {
            val entry = stats.firstOrNull { it.type == "inbound-rtp" && (text(it, "kind") ?: text(it, "mediaType")) == kind } ?: return null
            return (entry.members["bytesReceived"] as? Number)?.toDouble() ?: -1.0
        }
        val audio = bytes("audio") ?: return false
        if (audio <= 0) return false
        val video = bytes("video") ?: return true
        return video == 0.0
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
