// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** TV'de çevirinin oyundaki İngilizce altyazıya göre yeri. */
enum class SubtitlePlacement { COVER, ABOVE, BELOW, FIXED }

/** Android TV'de PS5 görüntüsünün nasıl gösterildiği (yalnız Android TV uygulaması kullanır). */
enum class TvDisplayMode { IN_APP, OVERLAY }

enum class SubtitleTextColor { WHITE, YELLOW }

/** TV'de altyazının görünümü (Windows: SubtitleStyle). fontSize: 36 küçük, 46 orta, 58 büyük, 72 çok büyük. */
data class SubtitleStyle(
    val fontSize: Int = 46,
    val bottomPercent: Int = 7,
    val placement: SubtitlePlacement = SubtitlePlacement.COVER,
    val background: Int = 72,
    val bold: Boolean = false,
    val textColor: SubtitleTextColor = SubtitleTextColor.WHITE,
    val displayMode: TvDisplayMode = TvDisplayMode.IN_APP,
)

/** Altyazıları TV'ye ileten taraf. */
interface SubtitleSender {
    /** [box]: oyundaki İngilizce altyazının ekrandaki yeri (kenarlara oranla); TV çeviriyi buna göre yerleştirir. */
    fun sendSubtitle(text: String, durationMs: Int = 15000, box: TextBox? = null)
    fun clear()
}

/** Sunucudan geçen ve telefon ekranındaki altyazı görünümünün de gösterdiği olay. */
sealed class SubtitleEvent {
    data class Subtitle(val text: String, val durationMs: Int) : SubtitleEvent()
    data object Cleared : SubtitleEvent()
}

/**
 * TV uygulamasının bağlandığı yerel Server-Sent Events sunucusu (Windows: SubtitleServer.cs, Mac: SubtitleServer.swift;
 * aynı protokol, aynı port). `GET /events` akışında `subtitle`, `clear`, `style` ve `ping` olaylarını yayınlar;
 * `GET /hello` TV uygulamasının ağı tararken bu cihazı tanıdığı yanıttır.
 */
class SubtitleServer(
    private val port: Int = DEFAULT_PORT,
    private val pingIntervalMs: Long = 15_000,
    private val clock: () -> Long = System::currentTimeMillis,
) : SubtitleSender {
    companion object {
        const val DEFAULT_PORT = 8787

        /** Bağlantı canlı tutma: yorum satırını EventSource görmez; adlı "ping" olayını TV görür. */
        const val PING_FRAME = ": ping\n\nevent: ping\ndata: {}\n\n"

        fun frame(name: String, json: Map<String, Any?>) = "event: $name\ndata: ${Json.write(json)}\n\n"

        fun boxJson(box: TextBox) = mapOf(
            "bottom" to Json.Decimal(box.bottom), "left" to Json.Decimal(box.left),
            "right" to Json.Decimal(box.right), "top" to Json.Decimal(box.top),
        )

        fun subtitleFrame(text: String, durationMs: Int, box: TextBox?, at: Long, paragraphs: Boolean = false): String {
            val json = mutableMapOf<String, Any?>("at" to at, "duration" to durationMs, "text" to text)
            if (paragraphs) json["paragraphs"] = true
            if (box != null) json["box"] = boxJson(box)
            return frame("subtitle", json)
        }

        fun clearFrame() = frame("clear", emptyMap())

        fun styleFrame(style: SubtitleStyle) = frame(
            "style", mapOf(
                "background" to style.background.coerceIn(0, 100),
                "bold" to style.bold,
                "bottomPercent" to style.bottomPercent,
                "displayMode" to if (style.displayMode == TvDisplayMode.OVERLAY) "overlay" else "inApp",
                "fontSize" to style.fontSize,
                "placement" to style.placement.name.lowercase(Locale.ROOT),
                "textColor" to style.textColor.name.lowercase(Locale.ROOT),
            )
        )
    }

    private class Client(val socket: Socket, val viewer: Boolean) {
        val output: OutputStream = socket.getOutputStream()
    }

    private val lock = Any()
    private val clients = mutableListOf<Client>()
    private var listener: ServerSocket? = null
    private var pinger: ScheduledExecutorService? = null
    private var lastStyle: SubtitleStyle? = null

    /** Bağlı TV sayısı değişince çağrılır (sunucunun iş parçacığında). */
    @Volatile var onClientsChanged: ((Int) -> Unit)? = null

    /** Altyazı ve temizleme olayları gönderildiği anda buraya da verilir (telefon ekranındaki görünüm için). */
    @Volatile var onEvent: ((SubtitleEvent) -> Unit)? = null

    /** false ise altyazı olayları TV'lere gitmez (altyazı yalnız telefon ekranında). */
    @Volatile var sendsToTv: Boolean = true

    val connectedClients: Int get() = synchronized(lock) { clients.count { !it.viewer } }

    /** Sunucuyu başlatır ve dinlenen portu döner (port 0 ise rastgele seçilen). */
    fun start(): Int {
        val socket = ServerSocket()
        socket.reuseAddress = true
        socket.bind(InetSocketAddress(port))
        listener = socket
        thread(name = "CouchSubs SSE accept", isDaemon = true) { acceptLoop(socket) }
        pinger = Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "CouchSubs SSE ping").apply { isDaemon = true } }
            .also { it.scheduleWithFixedDelay({ broadcast(PING_FRAME) }, pingIntervalMs, pingIntervalMs, TimeUnit.MILLISECONDS) }
        return socket.localPort
    }

    fun stop() {
        pinger?.shutdownNow()
        pinger = null
        try {
            listener?.close()
        } catch (error: IOException) {
        }
        listener = null
        val closing = synchronized(lock) { clients.toList().also { clients.clear() } }
        closing.forEach { closeQuietly(it.socket) }
        sender.shutdown()
    }

    override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?) {
        broadcast(subtitleFrame(text, durationMs, box, clock()), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Subtitle(text, durationMs))
    }

    override fun clear() {
        broadcast(clearFrame(), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Cleared)
    }

    fun sendStyle(style: SubtitleStyle) {
        synchronized(lock) { lastStyle = style }
        broadcast(styleFrame(style), subtitle = true)
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (error: IOException) {
                return
            }
            thread(name = "CouchSubs SSE client", isDaemon = true) { serve(client) }
        }
    }

    private fun serve(socket: Socket) {
        try {
            // Sessizce kaybolan TV'ler TCP canlılık denetimiyle fark edilir; küçük çerçeveler beklemeden gider.
            socket.keepAlive = true
            socket.tcpNoDelay = true
            val requestLine = readRequestLine(socket.getInputStream())
            val parts = requestLine?.split(' ') ?: emptyList()
            val method = parts.getOrElse(0) { "" }
            val target = parts.getOrElse(1) { "" }
            val path = target.substringBefore('?')
            when {
                method == "OPTIONS" -> respondAndClose(socket, "204 No Content")
                method == "GET" && path == "/events" -> openStream(socket, target.contains("viewer=obs"))
                // TV uygulaması ağdaki CouchSubs'ı bu yanıtla tanır.
                method == "GET" && path == "/hello" -> respondAndClose(socket, "200 OK", "{\"app\":\"couchsubs\"}")
                else -> respondAndClose(socket, "404 Not Found")
            }
        } catch (error: IOException) {
            closeQuietly(socket)
        }
    }

    /** Başlıkların sonuna (boş satır) kadar okur, ilk satırı döner. 64 KB'yi aşan istek kapatılır. */
    private fun readRequestLine(input: InputStream): String? {
        val head = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (head.size() < 65536) {
            val count = input.read(buffer)
            if (count <= 0) return null
            head.write(buffer, 0, count)
            val text = head.toString(Charsets.ISO_8859_1.name())
            if (text.contains("\r\n\r\n")) return text.substringBefore("\r\n")
        }
        return null
    }

    private fun respondAndClose(socket: Socket, status: String, body: String = "") {
        val head = "HTTP/1.1 $status\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body"
        socket.getOutputStream().apply {
            write(head.toByteArray(Charsets.US_ASCII))
            flush()
        }
        closeQuietly(socket)
    }

    private fun openStream(socket: Socket, viewer: Boolean) {
        val head = StringBuilder()
            .append("HTTP/1.1 200 OK\r\n")
            .append("Content-Type: text/event-stream; charset=utf-8\r\n")
            .append("Cache-Control: no-cache\r\n")
            .append("Connection: keep-alive\r\n")
            .append("Access-Control-Allow-Origin: *\r\n\r\n")
            .append("retry: 2000\n\n")
        val client = Client(socket, viewer)
        // Başlık, listeye girdikten sonra gelebilecek ilk olaydan önce yazılır (istemci kilidi tutulurken eklenir).
        val count = synchronized(client) {
            val count = synchronized(lock) {
                lastStyle?.let { head.append(styleFrame(it)) }
                clients.add(client)
                clients.count { !it.viewer }
            }
            write(client, head.toString())
            count
        }
        onClientsChanged?.invoke(count)
        // İstemci bağlantıyı kapatınca okuma biter ve listeden çıkarılır.
        try {
            val input = socket.getInputStream()
            val buffer = ByteArray(1024)
            while (input.read(buffer) > 0) {
            }
        } catch (error: IOException) {
        }
        remove(client)
    }

    private fun remove(client: Client) {
        val count = synchronized(lock) {
            if (!clients.remove(client)) return
            clients.count { !it.viewer }
        }
        closeQuietly(client.socket)
        onClientsChanged?.invoke(count)
    }

    /**
     * Gönderim hatası alan bağlantı kopmuş sayılır. Altyazı TV'ye gitmiyorsa yalnız izleyiciler (OBS) alır. Yazma tek bir
     * gönderim iş parçacığında, sırayla yapılır: yavaş bir TV okuma hattını bekletmez.
     */
    private fun broadcast(frame: String, subtitle: Boolean = false) {
        val toTvs = !subtitle || sendsToTv
        val targets = synchronized(lock) { clients.filter { toTvs || it.viewer } }
        if (targets.isEmpty()) return
        try {
            sender.execute { for (client in targets) if (!write(client, frame)) remove(client) }
        } catch (error: java.util.concurrent.RejectedExecutionException) {
        }
    }

    private val sender = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "CouchSubs SSE send").apply { isDaemon = true } }

    private fun write(client: Client, text: String): Boolean = try {
        synchronized(client) {
            client.output.write(text.toByteArray(Charsets.UTF_8))
            client.output.flush()
        }
        true
    } catch (error: IOException) {
        false
    }

    private fun closeQuietly(socket: Socket) {
        try {
            socket.close()
        } catch (error: IOException) {
        }
    }
}
