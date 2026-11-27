// SPDX-License-Identifier: AGPL-3.0-only
// WebRTC veri kanallarının iletileri: Windows'taki xbox-xcloud-player 0.2.11'in (MIT, unknownskl) gönderdikleriyle
// birebir (Channel/Message.ts, Control.ts, Input/Packet.ts). Kumanda ve dokunma girdisi gönderilmez.
package com.couchsubs.mobile.xbox

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder

object XboxChannels {
    /** Kanal adı → protokol; `input` sıralıdır. Oluşturma sırası oynatıcıdaki gibi. */
    val CHANNELS = listOf("input" to "1.0", "chat" to "chatV1", "control" to "controlV1", "message" to "messageV1")

    const val HANDSHAKE = "{\"type\":\"Handshake\",\"version\":\"messageV1\",\"id\":\"f9c5f412-0e69-4ede-8e62-92c7f5358c56\",\"cv\":\"\"}"
    const val AUTHORIZATION = "{\"message\":\"authorizationRequest\",\"accessKey\":\"4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E\"}"
    const val GAMEPAD_ADDED = "{\"message\":\"gamepadChanged\",\"gamepadIndex\":0,\"wasAdded\":true}"
    private const val MESSAGE_ID = "41f93d5a-900f-4d33-b7a1-2d4ca6747072"

    fun isHandshakeAck(text: String): Boolean = try {
        JSONObject(text).optString("type") == "HandshakeAck"
    } catch (error: Exception) {
        false
    }

    /** `message` kanalına HandshakeAck'ten sonra gönderilen altı yapılandırma iletisi. */
    fun configurationMessages(width: Int = 1920, height: Int = 1080): List<String> = listOf(
        message("/streaming/systemUi/configuration", JSONObject().put("version", JSONArray(listOf(0, 1, 0))).put("systemUis", JSONArray())),
        message("/streaming/properties/clientappinstallidchanged", JSONObject().put("clientAppInstallId", "c11ddb2e-c7e3-4f02-a62b-fd5448e0b851")),
        message("/streaming/characteristics/orientationchanged", JSONObject().put("orientation", 0)),
        message("/streaming/characteristics/touchinputenabledchanged", JSONObject().put("touchInputEnabled", false)),
        message("/streaming/characteristics/clientdevicecapabilities", JSONObject()),
        message("/streaming/characteristics/dimensionschanged", JSONObject().put("horizontal", width).put("vertical", height)
            .put("preferredWidth", width).put("preferredHeight", height).put("safeAreaLeft", 0).put("safeAreaTop", 0)
            .put("safeAreaRight", width).put("safeAreaBottom", height).put("supportsCustomResolution", true)),
    )

    private fun message(target: String, data: JSONObject): String = JSONObject()
        .put("type", "Message").put("content", data.toString()).put("id", MESSAGE_ID).put("target", target).put("cv", "").toString()

    /**
     * `input` kanalının ilk paketi (ClientMetadata, 15 bayt): rapor türü 8 (u16 LE), sıra no (u32 LE), zaman damgası
     * (f64 LE, ms), en çok dokunma noktası (u8; oynatıcı 2 gönderir).
     */
    fun clientMetadataPacket(sequence: Int = 0, timestampMs: Double, maxTouchpoints: Int = 2): ByteArray {
        val buffer = ByteBuffer.allocate(15).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putShort(8.toShort())
        buffer.putInt(sequence)
        buffer.putDouble(timestampMs)
        buffer.put(maxTouchpoints.toByte())
        return buffer.array()
    }

    /**
     * `input` kanalından gelen ikili iletinin günlük metni (#1416): tür, uzunluk ve ilk [INPUT_HEX_BYTES] bayt onaltılı.
     * Xbox el sıkışmadan sonra 16 (ServerMetadata) gönderir; içeriği Xbox'ın görüntü ayarını gösterebilir (görüntü hiç
     * gelmeyen oturumu çalışan oturumla karşılaştırmak için). 128 (titreşim) her an gelir, yazılmaz (null).
     */
    fun describeInput(bytes: ByteArray): String? {
        val type = if (bytes.isEmpty()) -1 else bytes[0].toInt() and 0xff
        if (type == 128) return null
        val name = if (type == 16) " (ServerMetadata)" else ""
        val hex = bytes.take(INPUT_HEX_BYTES).joinToString(" ") { "%02x".format(it.toInt() and 0xff) }
        return "ikili ileti, tür $type$name, ${bytes.size} bayt" + (if (hex.isEmpty()) "" else ": $hex") +
            (if (bytes.size > INPUT_HEX_BYTES) " …" else "")
    }

    const val INPUT_HEX_BYTES = 32

    /** Oynatıcı bir pakette en çok 29 kare onaylar (Input.ts `getMetadataQueue(30)` → `splice(0, 29)`). */
    const val MAX_FRAME_ACKS = 29

    /**
     * `input` kanalının kare onayı paketi (Input/Packet.ts, rapor türü 1 = Metadata): tür (u16 LE), sıra no (u32 LE),
     * zaman damgası (f64 LE, ms), kare sayısı (u8), her kare için yedi u32 LE: serverDataKey (karenin RTP zaman
     * damgası), varış, gönderim, çözülme, gösterim, paket hazırlama ve gönderme anları (ms). Son ikisi oynatıcıda
     * paketin yazıldığı an; burada [timestampMs].
     */
    fun frameAckPacket(sequence: Int, timestampMs: Double, frames: List<XboxFrameAck>): ByteArray {
        require(frames.size in 1..MAX_FRAME_ACKS) { "kare sayısı: ${frames.size}" }
        val buffer = ByteBuffer.allocate(14 + 1 + 28 * frames.size).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putShort(1.toShort())
        buffer.putInt(sequence)
        buffer.putDouble(timestampMs)
        buffer.put(frames.size.toByte())
        val now = timestampMs.toLong()
        for (frame in frames) {
            // JavaScript'teki setUint32 gibi: alt 32 bit yazılır.
            buffer.putInt(frame.serverDataKey.toInt())
            buffer.putInt(frame.arrivalMs.toInt())
            buffer.putInt(frame.arrivalMs.toInt())
            buffer.putInt(frame.decodedMs.toInt())
            buffer.putInt(frame.decodedMs.toInt())
            buffer.putInt(now.toInt())
            buffer.putInt(now.toInt())
        }
        return buffer.array()
    }

    /** Oynatıcının SDP düzeltmesi: stereo ses (`useinbandfec=1` ilk geçişte). */
    fun mungeOffer(sdp: String): String = sdp.replaceFirst("useinbandfec=1", "useinbandfec=1; stereo=1")
}

/** Çözülen bir görüntü karesinin onayı: [serverDataKey] karenin RTP zaman damgası, anlar oturum saatine göre ms. */
data class XboxFrameAck(val serverDataKey: Long, val arrivalMs: Long, val decodedMs: Long)
