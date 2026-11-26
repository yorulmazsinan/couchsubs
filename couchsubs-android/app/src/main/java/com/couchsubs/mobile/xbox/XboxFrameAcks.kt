// SPDX-License-Identifier: AGPL-3.0-only
// Kare onayı: Windows'taki xbox-xcloud-player 0.2.11 (MIT, unknownskl) her gösterilen karede `input` kanalına bir
// Metadata kaydı yazar (Component/Video.ts `requestVideoFrameCallback` → Channel/Input.ts `addProcessedFrame`, 16 ms'de
// bir paket). Xbox bu onayları bekler: "Without sending any data back the stream will only last for +- 40 seconds. ...
// To maintain the stream, you have to send data back to the Xbox via the input channel. You have to confirm the packets
// back that you have processed." (Greenlight wiki, WebRTC). Telefon önceden yalnız ilk ClientMetadata paketini
// gönderiyordu; Xbox yayını kısa sürede kapatıp "uzaktan yürütmeyi durdurdu" diyordu, uygulama da baştan bağlanıyordu.
package com.couchsubs.mobile.xbox

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.os.SystemClock
import org.webrtc.EglBase
import org.webrtc.EncodedImage
import org.webrtc.HardwareVideoDecoderFactory
import org.webrtc.PlatformSoftwareVideoDecoderFactory
import org.webrtc.SoftwareVideoDecoderFactory
import org.webrtc.VideoCodecInfo
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoDecoder
import org.webrtc.VideoDecoderFactory
import org.webrtc.VideoDecoderFallback
import java.util.concurrent.ConcurrentHashMap

/** Çözülen kare: RTP zaman damgasının milisaniyesi (damga / 90), çözücüye geliş ve çözülme anı (elapsedRealtime, ms). */
internal fun interface DecodedFrameListener {
    fun onDecoded(rtpMs: Long, arrivedAt: Long, decodedAt: Long)
}

/**
 * DefaultVideoDecoderFactory'nin aynısı (donanım çözücüsü, yoksa ya da bozulursa yazılım), yalnız Java çözücüleri
 * çözdükleri kareyi bildirir. libwebrtc karenin RTP zaman damgasını Java'ya yalnız buradan, çözücüye giden karenin
 * `captureTimeNs`'i olarak verir (sdk/android/src/jni/video_decoder_wrapper.cc: `capture_time_ms_ = RtpTimestamp() /
 * kNumRtpTicksPerMillisec`); görüntü alıcısına (VideoSink) giden karede ise gösterim zamanı vardır.
 */
internal class XboxDecoderFactory(
    private val listener: DecodedFrameListener,
    private val note: XboxDecoderNote = XboxDecoderNote(),
) : VideoDecoderFactory {
    private val hardware = HardwareVideoDecoderFactory(null as EglBase.Context?)
    private val software = SoftwareVideoDecoderFactory()
    private val platform = PlatformSoftwareVideoDecoderFactory(null)

    override fun createDecoder(info: VideoCodecInfo): VideoDecoder? {
        // MediaCodec çözücüsü yalnız MIME türüne bakar: teklife eklenen H.264 High da donanım çözücüsüne gider.
        val hw = hardware.createDecoder(info)?.let { ReportingDecoder(it, note, listener) }
        // SoftwareVideoDecoderFactory'ninkiler yereldir (C++); onlardan kare bilgisi alınamaz.
        val native = software.createDecoder(info)
        val sw = native ?: platform.createDecoder(info)?.let { ReportingDecoder(it, note, listener) }
        when {
            hw != null -> note.created(info.name, hw.implementationName, hardware = true)
            native != null -> note.created(info.name, "libwebrtc", hardware = false)
            sw != null -> note.created(info.name, sw.implementationName, hardware = false)
            else -> note.initFailed(info.name, "bu telefonda çözücü yok")
        }
        return if (hw != null && sw != null) VideoDecoderFallback(sw, hw) else hw ?: sw
    }

    override fun getSupportedCodecs(): Array<VideoCodecInfo> {
        val all = LinkedHashSet<VideoCodecInfo>().apply {
            addAll(software.supportedCodecs)
            addAll(hardware.supportedCodecs)
            addAll(platform.supportedCodecs)
        }.map { XboxCodec(it.name, it.params) }
        return XboxCodecOrder.order(all, AvcHighProfile.supported)
            .map { VideoCodecInfo(it.name, it.params, emptyList()) }.toTypedArray()
    }
}

/**
 * Telefonun H.264 çözücüleri (MediaCodecList'ten) ve High (640c1f) teklif kararı (bkz. XboxAvcDecoders). Eskiden
 * yalnız listedeki ilk donanım çözücüsüne bakılıyordu; o çözücü High'ı bildirmeyince (#1252) telefon yalnız Baseline
 * teklif ediyordu.
 */
internal object AvcHighProfile {
    private const val MIME = "video/avc"
    private val SOFTWARE = listOf("OMX.google.", "OMX.SEC.", "c2.android")

    val decoders: List<XboxAvcDecoder> by lazy {
        runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
                !info.isEncoder && !info.name.endsWith(".secure") &&
                    info.supportedTypes.any { it.equals(MIME, ignoreCase = true) }
            }.map { info ->
                val high = runCatching {
                    info.getCapabilitiesForType(MIME).profileLevels.any {
                        it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh ||
                            it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedHigh
                    }
                }.getOrDefault(false)
                XboxAvcDecoder(info.name, hardware(info), high)
            }
        }.getOrDefault(emptyList())
    }

    val supported: Boolean get() = XboxAvcDecoders.offersHigh(decoders)

    /** Günlük satırı: çözücüler ve teklif kararı. */
    val note: String get() = XboxAvcDecoders.note(decoders)

    private fun hardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isHardwareAccelerated
        else SOFTWARE.none { info.name.startsWith(it) }
}

/** Java çözücüsünü sarar: girişte geliş anını, çıkışta kareyi bildirir; kareye dokunmaz. Başlatma hatası tanıya yazılır. */
internal class ReportingDecoder(
    private val inner: VideoDecoder,
    private val note: XboxDecoderNote? = null,
    private val listener: DecodedFrameListener,
) : VideoDecoder {
    /** captureTimeNs → çözücüye geliş anı. AndroidVideoDecoder çıkan karenin zamanını girişteki captureTimeNs'ten verir. */
    private val arrivals = ConcurrentHashMap<Long, Long>()

    override fun initDecode(settings: VideoDecoder.Settings, callback: VideoDecoder.Callback): VideoCodecStatus {
        val status = start(settings, callback)
        if (status != VideoCodecStatus.OK) note?.initFailed(inner.implementationName, status.name)
        return status
    }

    private fun start(settings: VideoDecoder.Settings, callback: VideoDecoder.Callback): VideoCodecStatus =
        inner.initDecode(settings) { frame, decodeTimeMs, qp ->
            val now = SystemClock.elapsedRealtime()
            val arrived = arrivals.remove(frame.timestampNs) ?: now
            try {
                listener.onDecoded(frame.timestampNs / 1_000_000, arrived, now)
            } finally {
                callback.onDecodedFrame(frame, decodeTimeMs, qp)
            }
        }

    override fun decode(frame: EncodedImage, info: VideoDecoder.DecodeInfo?): VideoCodecStatus {
        // Çözücünün düşürdüğü karelerin kaydı birikmesin.
        if (arrivals.size > 240) arrivals.clear()
        arrivals[frame.captureTimeNs] = SystemClock.elapsedRealtime()
        return inner.decode(frame, info)
    }

    override fun release(): VideoCodecStatus {
        arrivals.clear()
        return inner.release()
    }

    override fun getImplementationName(): String = inner.implementationName
}

/** Gönderilmeyi bekleyen kare onayları (oynatıcının `_frameMetadataQueue`'su). */
internal class XboxFrameAckQueue(private val capacity: Int = 600) {
    private val items = ArrayDeque<XboxFrameAck>()

    @Synchronized fun offer(ack: XboxFrameAck) {
        // Kanal açılmadan biriken onaylar eskir; en yeniler tutulur.
        if (items.size >= capacity) items.removeFirst()
        items.addLast(ack)
    }

    @Synchronized fun drain(max: Int = XboxChannels.MAX_FRAME_ACKS): List<XboxFrameAck> {
        val count = minOf(max, items.size)
        return List(count) { items.removeFirst() }
    }

    @Synchronized fun clear() = items.clear()

    companion object {
        /** RTP damgasının milisaniyesinden serverDataKey (90 kHz saat; u32). */
        fun serverDataKey(rtpMs: Long): Long = (rtpMs * 90) and 0xFFFFFFFFL
    }
}
