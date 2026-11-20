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

/** Altyazı kutusunun kapladığı alan: yazı kadar ya da tam genişlikte bant (eski TV uygulamaları alanı tanımaz, FIT gibi davranır). */
enum class SubtitleBackgroundShape { FIT, BAND }

/** TV'de altyazının görünümü (Windows: SubtitleStyle). fontSize: 36 küçük, 46 orta, 58 büyük, 72 çok büyük. */
data class SubtitleStyle(
    val fontSize: Int = 46,
    val bottomPercent: Int = 7,
    val placement: SubtitlePlacement = SubtitlePlacement.COVER,
    val background: Int = 90,
    val backgroundShape: SubtitleBackgroundShape = SubtitleBackgroundShape.FIT,
    val bold: Boolean = false,
    val textColor: SubtitleTextColor = SubtitleTextColor.WHITE,
    val displayMode: TvDisplayMode = TvDisplayMode.IN_APP,
    /** Hızlı konuşmada önceki satır(lar) yeni satırın üstünde kısa süre soluk kalsın mı; kapalıysa yeni satır eskisinin yerine geçer. */
    val stackPrevious: Boolean = true,
)

/** Altyazıları TV'ye ileten taraf. */
interface SubtitleSender {
    /**
     * [box]: oyundaki İngilizce altyazının ekrandaki yeri (kenarlara oranla); TV çeviriyi buna göre yerleştirir.
     * [replaces]: satır az önce gösterilenin uzamış ya da düzelmiş okumasıdır ([TextMatch.isRevision]); TV onu öncekinin
     * üstüne yığmaz, yerine koyar (`replace` alanı; eski TV uygulamaları yok sayar).
     */
    fun sendSubtitle(text: String, durationMs: Int = 15000, box: TextBox? = null, replaces: Boolean = false)
    fun clear()
}

/** Sunucudan geçen ve telefon ekranındaki altyazı görünümünün de gösterdiği olay. */
sealed class SubtitleEvent {
    /** [replaces]: satır öncekinin uzamış ya da düzelmiş okumasıdır; öncekinin üstüne yığılmaz, yerine geçer. */
    data class Subtitle(val text: String, val durationMs: Int, val replaces: Boolean = false) : SubtitleEvent()
    data object Cleared : SubtitleEvent()
    /** Ek alanın (görev, telefon, bildirim) çevirisi; [text] boşsa o alanın kutusu kalkar. */
    /** [blocks]: alandaki ayrı yazı gruplarının çevirileri kendi yerleri ve (otomatik ekran yazısında) özgün stilleriyle. */
    data class Region(val id: String, val text: String, val box: TextBox?, val blocks: List<ScreenTranslation.Item>? = null) : SubtitleEvent()
    /** Bütün ek alan kutuları kalktı (çeviri durdu). */
    data object RegionsCleared : SubtitleEvent()
    /** "Ekranı çevir" sonuçları: her çeviri yazının yerinde gösterilir. */
    data class Screen(val items: List<ScreenTranslation.Item>, val durationMs: Int) : SubtitleEvent()
    /** "Ekranı çevir" çevirileri kaldırıldı. */
    data object ScreenCleared : SubtitleEvent()
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
    /**
     * Bu kurulumun kalıcı kimliği (`/hello` yanıtında). Aynı ağda iki CouchSubs varken TV uygulaması kendi telefonunu ya da
     * bilgisayarını adres değişse de bununla tanır; eskiden ağda ilk bulduğuna bağlanıyordu (GitHub #425).
     */
    val instanceId: String = "",
    key: String = SubtitleAccess.createKey(),
    private val allowLegacy: Boolean = SubtitleAccess.ALLOW_LEGACY_CLIENTS,
    private val obsOverlay: String = "",
) : SubtitleSender, RegionSender {
    @Volatile var accessKey: String = key
        private set
    val pairing = SubtitlePairing()
    var onPairingRequest: ((SubtitlePairing.Ticket) -> Unit)? = null
    @Volatile var hasLegacyClient = false
        private set
    var onLegacyClient: (() -> Unit)? = null
    fun rotateKey(key: String) {
        val closing = synchronized(lock) {
            accessKey = key
            pairing.reset()
            clients.toList().also { clients.clear() }
        }
        closing.forEach { closeQuietly(it.socket) }
        onClientsChanged?.invoke(0)
    }
    companion object {
        const val DEFAULT_PORT = 8787

        /** `/hello` yanıtı: uygulama, kurulum kimliği ve bağlı TV sayısı (Mac ve Windows ile aynı biçim). */
        fun helloBody(id: String, tvs: Int): String =
            "{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"${id.filter { it.isLetterOrDigit() && it.code < 128 || it == '-' }}\",\"tvs\":${maxOf(0, tvs)}}"

        /** Bağlantı canlı tutma: yorum satırını EventSource görmez; adlı "ping" olayını TV görür. */
        const val PING_FRAME = ": ping\n\nevent: ping\ndata: {}\n\n"

        fun frame(name: String, json: Map<String, Any?>) = "event: $name\ndata: ${Json.write(json)}\n\n"

        fun boxJson(box: TextBox) = mapOf(
            "bottom" to Json.Decimal(box.bottom), "left" to Json.Decimal(box.left),
            "right" to Json.Decimal(box.right), "top" to Json.Decimal(box.top),
        )

        /** [speakerColors]: açıksa satırlardaki konuşanlar renkleriyle `speakers` alanında gider (bkz. [SpeakerColors]). */
        fun subtitleFrame(
            text: String, durationMs: Int, box: TextBox?, at: Long, paragraphs: Boolean = false, replaces: Boolean = false,
            speakerColors: Boolean = false,
        ): String {
            val json = mutableMapOf<String, Any?>("at" to at, "duration" to durationMs, "text" to text)
            if (paragraphs) json["paragraphs"] = true
            if (replaces) json["replace"] = true
            // Konuşan adı yoksa ya da ayar kapalıysa alan hiç yazılmaz; eski TV uygulamaları alanı yok sayar.
            if (speakerColors) SpeakerColors.speakers(text).takeIf { it.isNotEmpty() }?.let { speakers ->
                json["speakers"] = speakers.map { mapOf("color" to it.color, "name" to it.name) }
            }
            if (box != null) json["box"] = boxJson(box)
            return frame("subtitle", json)
        }

        fun clearFrame() = frame("clear", emptyMap())

        /**
         * Ek alanın çevirisi: alanın kimliği (`id`), çeviri (`text`; boşsa kutu kalkar), yazının karedeki yeri (`box`) ve
         * satır yüksekliği (`line`, ekrana oranla). TV çeviriyi o yerde küçük bir kutuda gösterir (Mac/iPhone ile aynı).
         */
        fun regionFrame(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>? = null,
            blocks: List<ScreenTranslation.Item>? = null,
        ): String {
            val (text, blocks) = guarded(text, box, blocks)
            val json = mutableMapOf<String, Any?>("id" to id, "text" to text)
            if (!icons.isNullOrEmpty()) json["icons"] = iconsJson(icons)
            // Alanda ayrı duran yazı gruplarının çevirileri kendi yerleriyle; eski TV uygulamaları birleşik `text`'i gösterir.
            if (!blocks.isNullOrEmpty() && text.isNotEmpty()) json["blocks"] = blocks.map { itemJson(it) }
            if (box != null) json["box"] = boxJson(box)
            if (lineHeight != null) json["line"] = Json.Decimal(Math.round(lineHeight.coerceIn(0.0, 1.0) * 10000) / 10000.0)
            return frame("region", json)
        }

        /**
         * "Ekranı çevir" sonuçları: her çeviri yazının yeri (`box`), tipik satır yüksekliği (`line`, ekrana oranla) ve
         * çok parçalıysa `paragraphs` ile gider (Mac/iPhone `screen` olayı ile aynı). TV öncekinin yerine bunları koyar.
         */
        fun screenFrame(items: List<ScreenTranslation.Item>, durationMs: Int): String {
            val kept = items.filter { area(it.box) <= MAX_BOX_AREA }
            return frame("screen", mapOf("duration" to durationMs, "items" to kept.map { itemJson(it) }))
        }

        /**
         * Ekranın bu oranından büyük çeviri kutusu gönderilmez. TV ve OBS kutuyu opak zeminle çizer; yanlış bir algılamanın
         * (otomatik ekran yazısı) ekranın büyük kısmını kaplayan kutusu oyun görüntüsünü kapatıyordu (LG'de "siyah ekran,
         * ses var"). Windows: SubtitleServer.MaxBoxArea, Mac/iPhone: SubtitleServer.maxBoxArea.
         */
        const val MAX_BOX_AREA = 0.4

        fun area(box: TextBox) = maxOf(0.0, box.right - box.left) * maxOf(0.0, box.bottom - box.top)

        /**
         * Büyük kutu koruması: alanı [MAX_BOX_AREA]'dan büyük bloklar atılır; blokların toplamı da sınırı aşıyorsa ya da
         * bloksuz alanın kutusu sınırdan büyükse alan boş gönderilir (TV kutuyu kaldırır).
         */
        fun guarded(text: String, box: TextBox?, blocks: List<ScreenTranslation.Item>?): Pair<String, List<ScreenTranslation.Item>?> {
            if (text.isEmpty()) return text to blocks
            var rest = blocks
            if (!blocks.isNullOrEmpty()) {
                val kept = blocks.filter { area(it.box) <= MAX_BOX_AREA }
                if (kept.sumOf { area(it.box) } > MAX_BOX_AREA) return "" to null
                if (kept.isNotEmpty()) return text to kept
                rest = null
            }
            return if (box != null && area(box) > MAX_BOX_AREA) "" to null else text to rest
        }

        /** Yeriyle bir çeviri ("Ekranı çevir" öğesi ya da ek alan bloğu). */
        private fun itemJson(item: ScreenTranslation.Item): Map<String, Any?> {
            val json = mutableMapOf<String, Any?>(
                "box" to boxJson(item.box), "line" to Json.Decimal(Math.round(item.lineHeight.coerceIn(0.0, 1.0) * 10000) / 10000.0),
                "text" to item.translation,
            )
            if (item.paragraphs) json["paragraphs"] = true
            item.icons?.takeIf { it.isNotEmpty() }?.let { json["icons"] = iconsJson(it) }
            // Otomatik ekran yazısının özgün görünüşü; eski TV uygulamaları bu alanları yok sayar.
            item.surface?.let { json["surface"] = mapOf("background" to it.background, "flat" to it.flat, "foreground" to it.foreground) }
            item.look?.let { json["style"] = mapOf("align" to it.align, "bold" to it.bold, "condensed" to it.condensed, "upper" to it.upper) }
            return json
        }

        /** Çevirinin içindeki kumanda simgeleri: düz metindeki yeri (`at`) ve PNG'si (`src`); eski TV uygulamaları yok sayar. */
        fun iconsJson(icons: List<IconPlacement>) = icons.map { mapOf("at" to it.at, "src" to it.image) }

        /**
         * [setApart]: "Ekran yazılarını altyazıdan ayır"; TV ek alan kutularını özgün renginde ve kendi yerinde, altyazı
         * kutusundan farklı zeminde çizer (`setApart`; eski TV uygulamaları yok sayar, yeni olanlar yoksa açık sayar).
         */
        fun styleFrame(style: SubtitleStyle, setApart: Boolean = true) = frame(
            "style", mapOf(
                "background" to style.background.coerceIn(0, 100),
                "backgroundShape" to style.backgroundShape.name.lowercase(Locale.ROOT),
                "bold" to style.bold,
                "bottomPercent" to style.bottomPercent,
                "displayMode" to if (style.displayMode == TvDisplayMode.OVERLAY) "overlay" else "inApp",
                "fontSize" to style.fontSize,
                "placement" to style.placement.name.lowercase(Locale.ROOT),
                "setApart" to setApart,
                "stackPrevious" to style.stackPrevious,
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

    /** "Ekran yazılarını altyazıdan ayır" (bkz. [styleFrame]); değişince [sendStyle] yeniden çağrılmalı. */
    @Volatile var setApart: Boolean = true

    /** Bağlı TV sayısı değişince çağrılır (sunucunun iş parçacığında). */
    @Volatile var onClientsChanged: ((Int) -> Unit)? = null

    /** Altyazı ve temizleme olayları gönderildiği anda buraya da verilir (telefon ekranındaki görünüm için). */
    @Volatile var onEvent: ((SubtitleEvent) -> Unit)? = null

    /** false ise altyazı olayları TV'lere gitmez (altyazı yalnız telefon ekranında). */
    @Volatile var sendsToTv: Boolean = true
    /** "Konuşana göre renk": altyazı olayına konuşanların renkleri eklenir (`speakers`). */
    @Volatile var speakerColors: Boolean = false

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
        pairing.setSession(false)
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

    override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
        broadcast(subtitleFrame(text, durationMs, box, clock(), replaces = replaces, speakerColors = speakerColors), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Subtitle(text, durationMs, replaces))
    }

    override fun clear() {
        broadcast(clearFrame(), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Cleared)
    }

    override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) = sendRegion(id, text, box, lineHeight, null)

    /** [icons]: çevirinin içindeki kumanda simgeleri ([ButtonIcons]); `icons` alanıyla gider. */
    override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?) =
        sendRegion(id, text, box, lineHeight, icons, null)

    /** [blocks]: alanda ayrı duran yazı gruplarının çevirileri kendi yerleriyle (`blocks`). */
    override fun sendRegion(
        id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?,
        blocks: List<ScreenTranslation.Item>?,
    ) {
        broadcast(regionFrame(id, text, box, lineHeight, icons, blocks), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Region(id, text, box, blocks?.takeIf { text.isNotEmpty() }))
    }

    override fun clearRegions() {
        broadcast(frame("region-clear", emptyMap()), subtitle = true)
        onEvent?.invoke(SubtitleEvent.RegionsCleared)
    }

    /** "Ekranı çevir" sonuçlarını TV'ye (ve telefon ekranına) gönderir. */
    fun sendScreen(items: List<ScreenTranslation.Item>, durationMs: Int) {
        broadcast(screenFrame(items, durationMs), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Screen(items, durationMs))
    }

    /** TV'deki ve telefondaki "ekranı çevir" çevirilerini kaldırır (altyazıya dokunmaz). */
    fun clearScreen() {
        broadcast(frame("screen-clear", emptyMap()), subtitle = true)
        onEvent?.invoke(SubtitleEvent.ScreenCleared)
    }

    fun sendStyle(style: SubtitleStyle) {
        synchronized(lock) { lastStyle = style }
        broadcast(styleFrame(style, setApart), subtitle = true)
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (error: IOException) {
                return
            }
            if (!SubtitleAccess.isLocalPeer(client.inetAddress)) { closeQuietly(client); continue }
            thread(name = "CouchSubs SSE client", isDaemon = true) { serve(client) }
        }
    }

    private fun serve(socket: Socket) {
        try {
            // Sessizce kaybolan TV'ler TCP canlılık denetimiyle fark edilir; küçük çerçeveler beklemeden gider.
            socket.keepAlive = true
            socket.tcpNoDelay = true
            socket.soTimeout = 10_000
            val request = readRequestLine(socket.getInputStream())?.let(SubtitleAccess::parse)
            if (request == null) { respondAndClose(socket, "400 Bad Request"); return }
            socket.soTimeout = 0
            val checkedKey = accessKey
            val access = SubtitleAccess.authorize(request, checkedKey, allowLegacy)
            val cors = SubtitleAccess.cors(request)
            if (access.status != 200) {
                respondAndClose(socket, if (access.status == 403) "403 Forbidden" else "401 Unauthorized", cors = if (access.status == 403) "" else cors)
                return
            }
            val method = request.method
            val path = request.path
            if (path == "/pair") {
                if (method == "POST") {
                    val ticket = pairing.begin()
                    if (ticket == null) { respondAndClose(socket, "409 Conflict", cors = cors); return }
                    onPairingRequest?.invoke(ticket)
                    respondAndClose(socket, "200 OK", org.json.JSONObject().put("id", ticket.id).put("code", ticket.code).toString(), cors)
                } else if (method == "GET") {
                    val body = synchronized(lock) {
                        val state = if (request.parameter("validate") == "1") {
                            val check = request.copy(target = "/events?k=" + java.net.URLEncoder.encode(request.parameter("k") ?: "", "UTF-8"))
                            if (SubtitleAccess.authorize(check, accessKey, false).status == 200) "valid" else "expired"
                        } else pairing.poll(request.parameter("id") ?: "")
                        org.json.JSONObject().put("state", state).apply { if (state == "approved") put("key", accessKey) }.toString()
                    }
                    respondAndClose(socket, "200 OK", body, cors)
                } else respondAndClose(socket, "405 Method Not Allowed", cors = cors)
                return
            }
            when {
                method == "OPTIONS" -> respondAndClose(socket, "204 No Content", cors = cors)
                method == "GET" && path == "/events" -> {
                    val obs = request.parameter("viewer") == "obs"
                    // Anahtarsız OBS sayfası eski bir OBS adresidir; TV uygulamasının eski olduğu anlamına gelmez.
                    val notify = synchronized(lock) { (access.legacy && !obs && !hasLegacyClient).also { if (it) hasLegacyClient = true } }
                    if (notify) onLegacyClient?.invoke()
                    openStream(socket, obs, cors, checkedKey)
                }
                // TV uygulaması ağdaki CouchSubs'ı bu yanıtla tanır.
                method == "GET" && path == "/obs" && obsOverlay.isNotEmpty() -> respondAndClose(socket, "200 OK", obsOverlay, cors, "text/html; charset=utf-8")
                method == "GET" && path == "/hello" -> respondAndClose(socket, "200 OK", helloBody(instanceId, connectedClients), cors)
                else -> respondAndClose(socket, "404 Not Found", cors = cors)
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
            if (text.contains("\r\n\r\n")) return text.substringBefore("\r\n\r\n")
        }
        return null
    }

    private fun respondAndClose(socket: Socket, status: String, body: String = "", cors: String = "", type: String = "application/json") {
        val data = body.toByteArray(Charsets.UTF_8)
        val head = "HTTP/1.1 $status\r\n${cors}Content-Type: $type\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: ${data.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().apply { write(head.toByteArray(Charsets.US_ASCII)); write(data); flush() }
        closeQuietly(socket)
    }

    private fun openStream(socket: Socket, viewer: Boolean, cors: String, checkedKey: String) {
        val head = StringBuilder()
            .append("HTTP/1.1 200 OK\r\n")
            .append("Content-Type: text/event-stream; charset=utf-8\r\n")
            .append("Cache-Control: no-cache\r\n")
            .append("Connection: keep-alive\r\n")
            .append(cors).append("\r\n")
            .append("retry: 2000\n\n")
        val client = Client(socket, viewer)
        // Başlık, listeye girdikten sonra gelebilecek ilk olaydan önce yazılır (istemci kilidi tutulurken eklenir).
        val count = synchronized(client) {
            val count = synchronized(lock) {
                if (accessKey != checkedKey) { closeQuietly(socket); return }
                lastStyle?.let { head.append(styleFrame(it, setApart)) }
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
