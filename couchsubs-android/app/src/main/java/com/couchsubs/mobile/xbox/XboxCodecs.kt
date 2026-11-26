// SPDX-License-Identifier: AGPL-3.0-only
// Xbox görüntü kodeği (#1252). libwebrtc'nin Android donanım çözücü fabrikası H.264 High profilini yalnız adı
// "OMX.qcom." ya da "OMX.Exynos." ile başlayan çözücülerde teklif eder (MediaCodecVideoDecoderFactory
// .isH264HighProfileSupported); Android 10 ve sonrasının çözücüleri "c2.qti.", "c2.mtk.", "c2.exynos." adlıdır, bu
// telefonlar Xbox'a yalnız Constrained Baseline (42e01f) teklif ediyordu. iPhone, Mac (VideoToolbox) ve Windows
// (Chromium) Constrained High (640c1f) teklif eder; Android'de görüntünün geldiği tek kayıt da (#285, OnePlus 5,
// OMX.qcom) High teklif edilen oturumdu. #1252'deki Poco M6 Pro'da (c2.mtk) Xbox sesi gönderiyor, görüntüde yalnız
// dolgu paketi var ("video paket 150, bayt 0"). Burada telefonda herhangi bir H.264 çözücüsü varsa telefon da 640c1f
// teklif eder ve H.264 teklifin başına alınır (XboxAvcDecoders); SDP'deki kodekler, telefonun H.264 çözücüleri ve
// kurulan çözücünün durumu günlüğe yazılır.
package com.couchsubs.mobile.xbox

/** SDP'nin görüntü bölümündeki kodekler (oynatıcı günlüğü ve tanı satırı için). iPhone/Mac ve Windows'la aynı biçim. */
object XboxSdp {
    private val SKIPPED = setOf("rtx", "red", "ulpfec", "flexfec-03")

    /** `m=video` bölümündeki kodekler m= satırındaki sırayla: "H264 640c1f", "VP8". Bölüm yoksa ya da reddedildiyse boş. */
    fun videoCodecs(sdp: String): List<String> {
        val lines = sdp.split('\n').map { it.trimEnd('\r') }
        val start = lines.indexOfFirst { it.startsWith("m=video ") }
        if (start < 0) return emptyList()
        val media = lines[start].split(' ')
        if (media.getOrNull(1) == "0") return emptyList()
        val section = lines.drop(start + 1).takeWhile { !it.startsWith("m=") }
        val names = HashMap<String, String>()
        val formats = HashMap<String, String>()
        for (line in section) {
            when {
                line.startsWith("a=rtpmap:") -> {
                    val rest = line.removePrefix("a=rtpmap:")
                    val type = rest.substringBefore(' ')
                    names[type] = rest.substringAfter(' ').substringBefore('/')
                }
                line.startsWith("a=fmtp:") -> {
                    val rest = line.removePrefix("a=fmtp:")
                    formats[rest.substringBefore(' ')] = rest.substringAfter(' ', "")
                }
            }
        }
        return media.drop(3).mapNotNull { type ->
            val name = names[type] ?: return@mapNotNull null
            if (name.lowercase() in SKIPPED) return@mapNotNull null
            val profile = formats[type]?.split(';')?.map { it.trim() }
                ?.firstOrNull { it.startsWith("profile-level-id=", ignoreCase = true) }?.substringAfter('=')
            if (name.equals("H264", ignoreCase = true) && profile != null) "$name ${profile.lowercase()}" else name
        }.distinct()
    }

    /** Xbox'ın yanıtta seçtiği görüntü kodeği (ilk kodek); yoksa null. */
    fun negotiated(answer: String): String? = videoCodecs(answer).firstOrNull()

    /** "SDP görüntü kodekleri: teklif H264 640c1f, H264 42e01f, VP8; Xbox yanıtı H264 640c1f" */
    fun summary(offer: String, answer: String): String {
        val offered = videoCodecs(offer).joinToString(", ").ifEmpty { "yok" }
        val chosen = videoCodecs(answer).joinToString(", ").ifEmpty { "görüntü yok" }
        return "SDP görüntü kodekleri: teklif $offered; Xbox yanıtı $chosen"
    }
}

/** Telefondaki bir H.264 çözücüsü: MediaCodec adı, donanım mı, High (ya da Constrained High) profilini bildiriyor mu. */
data class XboxAvcDecoder(val name: String, val hardware: Boolean, val high: Boolean)

/**
 * High (640c1f) teklif kararı (#1252). Eskiden yalnız listedeki ilk donanım çözücüsünün bildirdiği profillere
 * bakılıyordu; o çözücü High'ı bildirmeyince telefon Xbox'a yalnız Constrained Baseline teklif ediyordu, Xbox da
 * görüntü kodlamıyordu. Android'in H.264 çözücüleri pratikte High'ı çözer (donanım çözemezse libwebrtc yazılım
 * çözücüsüne, c2.android.avc.decoder'a geçer); iPhone, Mac ve Windows da High teklif eder. Bu yüzden telefonda herhangi
 * bir H.264 çözücüsü varsa High teklif edilir; çözücüler ve bildirdikleri günlüğe yazılır.
 */
object XboxAvcDecoders {
    fun offersHigh(decoders: List<XboxAvcDecoder>): Boolean = decoders.isNotEmpty()

    /** "H.264 çözücüleri: c2.mtk.avc.decoder (donanım, High yok), c2.android.avc.decoder (yazılım, High); High (640c1f) teklif ediliyor" */
    fun note(decoders: List<XboxAvcDecoder>): String {
        if (decoders.isEmpty()) return "H.264 çözücüsü yok; High teklif edilmiyor"
        val list = decoders.joinToString(", ") {
            "${it.name} (${if (it.hardware) "donanım" else "yazılım"}, ${if (it.high) "High" else "High yok"})"
        }
        return "H.264 çözücüleri: $list; High (${XboxCodecOrder.CONSTRAINED_HIGH}) teklif ediliyor"
    }
}

/** Teklif edilecek görüntü kodeğinin adı ve SDP parametreleri (org.webrtc.VideoCodecInfo'nun sade karşılığı). */
data class XboxCodec(val name: String, val params: Map<String, String>)

object XboxCodecOrder {
    const val CONSTRAINED_HIGH = "640c1f"
    const val CONSTRAINED_BASELINE = "42e01f"

    fun profile(codec: XboxCodec): String? = codec.params["profile-level-id"]?.lowercase()

    /**
     * Teklif sırası: H.264 Constrained High (donanım çözücüsü High'ı destekliyorsa, libwebrtc eklemediyse eklenir),
     * sonra öbür H.264'ler, sonra kalan kodekler (VP8, VP9, AV1) geldikleri sırayla.
     */
    fun order(codecs: List<XboxCodec>, highSupported: Boolean): List<XboxCodec> {
        val all = codecs.distinct().toMutableList()
        val h264 = all.filter { it.name.equals("H264", ignoreCase = true) }
        if (highSupported && h264.isNotEmpty() && h264.none { profile(it) == CONSTRAINED_HIGH }) {
            val base = h264.firstOrNull { profile(it) == CONSTRAINED_BASELINE } ?: h264.first()
            all.add(0, XboxCodec(base.name, base.params + ("profile-level-id" to CONSTRAINED_HIGH)))
        }
        val (videoH264, rest) = all.partition { it.name.equals("H264", ignoreCase = true) }
        return videoH264.sortedBy { if (profile(it) == CONSTRAINED_HIGH) 0 else 1 } + rest
    }
}

/**
 * Görüntü çözücüsünün durumu tanı satırı için ("çözücü" alanı; getStats'ın decoderImplementation'ı ilk kare çözülene
 * kadar boştur). libwebrtc çözücüyü ilk görüntü karesi gelince kurar; hiç kurulmadıysa null döner.
 */
class XboxDecoderNote {
    @Volatile private var created: String? = null
    @Volatile private var failure: String? = null

    /** [name]: MediaCodec adı (c2.mtk.avc.decoder) ya da yerel yazılım çözücüsü. */
    fun created(codec: String, name: String, hardware: Boolean) {
        created = "$codec $name (${if (hardware) "donanım" else "yazılım"})"
    }

    fun initFailed(name: String, status: String) {
        failure = "$name başlatılamadı: $status"
    }

    fun describe(): String? {
        val made = created ?: return failure
        return failure?.let { "$made; $it" } ?: made
    }
}
