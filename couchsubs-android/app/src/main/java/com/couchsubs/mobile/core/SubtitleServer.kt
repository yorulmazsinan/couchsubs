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
/**
 * Android TV'de PS5 görüntüsünün nasıl gösterildiği (Mac/iPhone TVDisplayMode, Windows TvDisplayMode ile aynı). AUTO
 * varsayılandır: TV uygulaması katmana izin veriyorsa katman, yoksa uygulama içi. Eski kayıttaki "IN_APP" (eski
 * varsayılan; Philips/TCL'de uygulama içi siyah kalıyordu) tanınmaz ve AUTO olur. TV'ye AUTO "inApp", bilerek seçilen
 * uygulama içi "inAppOnly" gider; eski TV uygulaması "inApp"i eskisi gibi uygulama içi sayar.
 */
enum class TvDisplayMode { AUTO, IN_APP_ONLY, OVERLAY }

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
    val displayMode: TvDisplayMode = TvDisplayMode.AUTO,
    /** Hızlı konuşmada önceki satır(lar) yeni satırın üstünde kısa süre soluk kalsın mı; kapalıysa yeni satır eskisinin yerine geçer. */
    val stackPrevious: Boolean = true,
    /** Zeminin rengi ("#RRGGBB"); koyuluğu [background]. TV'ye `backgroundColor`; eski TV uygulaması siyah çizer. */
    val backgroundColor: String = DEFAULT_BACKGROUND_COLOR,
    /** Yazının rengi ("#RRGGBB"); null ise [textColor] (beyaz/sarı). TV'ye `textHex`. */
    val textHex: String? = null,
    /** Karakter adının rengi (Mac/iPhone NameColorMode): yazıyla aynı, tek renk ya da karaktere göre. */
    val nameColorMode: NameColorMode = NameColorMode.SPEAKER,
    /** "Tek Renk"te adların rengi. */
    val nameHex: String? = null,
    /** "Karaktere Göre"de kullanıcının seçtiği renkler (küçük harfli ad → "#RRGGBB"). */
    val characterColors: Map<String, String> = emptyMap(),
    /** Konuşan rengi yalnız adı boyar; TV'ye `nameOnly`. */
    val nameOnly: Boolean = false,
    /** Kurulumda seçilen TV girişi (HDMI 1–4); TV uygulaması değer değişince o girişi açar. TV'ye `hdmiInput`. */
    val hdmiInput: Int? = null,
) {
    companion object {
        const val DEFAULT_BACKGROUND_COLOR = "#101014"

        /** Geçerli "#RRGGBB" ise büyük harfle; değilse null (Mac SubtitleStyle.hex ile aynı). */
        fun hex(value: String?): String? =
            value?.takeIf { it.length == 7 && it[0] == '#' && it.drop(1).all { c -> c.isDigit() || c.lowercaseChar() in 'a'..'f' } }?.uppercase(Locale.ROOT)
    }
}

/** Karakter adının rengi (Mac/iPhone NameColorMode, Windows NameColorMode ile aynı). */
enum class NameColorMode {
    TEXT, SINGLE, SPEAKER,
    /** "Tüm Satır": karaktere göre renk; ad ve cümle o karakterin renginde (TV'ye `style.wholeLine`). */
    LINE,
}

/** Altyazıları TV'ye ileten taraf. */
interface SubtitleSender {
    /**
     * [box]: oyundaki İngilizce altyazının ekrandaki yeri (kenarlara oranla); TV çeviriyi buna göre yerleştirir.
     * [replaces]: satır az önce gösterilenin uzamış ya da düzelmiş okumasıdır ([TextMatch.isRevision]); TV onu öncekinin
     * üstüne yığmaz, yerine koyar (`replace` alanı; eski TV uygulamaları yok sayar).
     */
    fun sendSubtitle(text: String, durationMs: Int = 15000, box: TextBox? = null, replaces: Boolean = false)
    fun clear()

    /** Ekrandaki görev satırının karedeki yeri (yoksa null): altyazı kutusu onu örtmez, üstüne kayar ([MissionLine.clearance]). */
    fun sendObjective(box: TextBox?) {}
}

/** Sunucudan geçen ve telefon ekranındaki altyazı görünümünün de gösterdiği olay. */
sealed class SubtitleEvent {
    /**
     * [replaces]: satır öncekinin uzamış ya da düzelmiş okumasıdır; öncekinin üstüne yığılmaz, yerine geçer. [box]: oyundaki
     * altyazının karedeki yeri (Mac ve Windows'taki altyazı penceresi "Yazı kadar" kutuyu onu örtecek kadar büyütür; telefon
     * ekranı oyunun üstünde durmadığından kullanmaz, iPhone'daki gibi).
     */
    data class Subtitle(val text: String, val durationMs: Int, val replaces: Boolean = false, val box: TextBox? = null) : SubtitleEvent()
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
    /** İkinci ekran sayfası (`/view`, assets/second-screen.html; Mac ve Windows ile aynı dosya). */
    private val secondScreenPage: String = "",
    /**
     * Eşleştirme durumu. Sunucu yeni örnekle yeniden kurulunca (port değişti) eskisininki verilir: onay bekleyen istek,
     * "TV eşleştir" süresi ve onaylanmış istek taşınır (Mac/iPhone ve Windows ile aynı).
     */
    val pairing: SubtitlePairing = SubtitlePairing(),
) : SubtitleSender, RegionSender {
    @Volatile var accessKey: String = key
        private set
    var onPairingRequest: ((SubtitlePairing.Ticket) -> Unit)? = null
    @Volatile var hasLegacyClient = false
        private set
    var onLegacyClient: (() -> Unit)? = null
    /** 403 alan Origin değerleri günlüğe bir kez yazılır (GitHub #1132; uygulamanın günlüğü, [DropLog.sink]). */
    private val rejectedOrigins = SubtitleAccess.RejectedOrigins()
    private val tvEvents = SubtitleAccess.TvEventLog()
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

        /** Oyun içi telefonun çevirisini taşıyan ek alanın kimliği (Mac/iPhone ve Windows ile aynı). */
        const val GAME_PHONE_ID = "game-phone"

        /**
         * Okuma turu bu kadar süredir dönmüyorsa (uygulama donmuş, tur takılmış) gösterilen alanlar TV'de yenilenmez ve
         * yeni bağlanan TV'ye yinelenmez: TV onları 15 sn'lik ömrü dolunca kendisi kaldırır. Yenileme kendi zamanlayıcısıyla
         * döndüğü için uygulama donsa da sürüyor, son çeviri TV'de sonsuza dek kalıyordu (#1271; Mac/iPhone, Windows aynı).
         */
        const val REGION_ALIVE_MS = 20_000L

        /** Gösterilen alanlar yenilenir mi: tur hiç bildirilmediyse (eski akış) ya da en son [REGION_ALIVE_MS] içinde döndüyse. */
        fun keepsRegions(aliveAt: Long, now: Long): Boolean = aliveAt < 0 || now - aliveAt <= REGION_ALIVE_MS

        private fun uptimeMs(): Long = System.nanoTime() / 1_000_000

        /**
         * Eski TV uygulamaları (0.9.7'den önce) `clear` gelir gelmez satırı kaldırır. Oyundaki satır ekrandan ~1 sn'de
         * kalkınca çevirisi TV'de yalnız bir an görünüyordu: "TV'de test et" yazısı (8 sn, `clear` yok) görünüyor, oyun
         * altyazıları hiç görünmüyordu. Yeni TV uygulaması satırı kendisi `min(5000, 2000 + 60 × harf)` ms tutar
         * (tv-webos/app.js `holdUntil`); sürüm bildirmeyen bağlantılara `clear` bu süre dolunca gider, arada yeni satır
         * gelirse hiç gitmez (Mac/iPhone ve Windows ile aynı kural).
         */
        fun legacyClearHoldMs(textLength: Int): Long = minOf(5000, 2000 + 60 * maxOf(0, textLength)).toLong()

        /** `v` parametresi: yalnız rakam ve nokta, en çok 20 karakter; yoksa ya da bozuksa boş (eski TV sayılır). */
        fun tvAppVersion(value: String?): String =
            value?.takeIf { it.isNotEmpty() && it.length <= 20 && it.all { c -> c in '0'..'9' || c == '.' } } ?: ""

        /**
         * Sürümü bildiren TV kayıtlı (bu telefonun kurduğu ya da seçtiği) TV mi? Adreslerden biri bilinmiyorsa evet sayılır
         * (Android TV adressiz eşlenebilir). Aynı ağda iki TV varken (LG ve Android TV) öbür TV'nin uygulaması bağlanıp
         * sürümünü bildirince bu sürüm kayıtlı TV'ninki sanılıyor, kayıtlı TV için güncelleme öneriliyor ve kayıttaki sürüm
         * öbür TV'ninkiyle değişiyordu. Mac/iPhone ve Windows ile aynı.
         */
        fun isFromSavedTv(reporter: String, saved: String?): Boolean {
            val from = reporter.trim()
            val to = saved?.trim().orEmpty()
            if (from.isEmpty() || to.isEmpty()) return true
            if (from.equals(to, ignoreCase = true)) return true
            val mapped = to.removePrefix("[").removeSuffix("]").let { if (it.lowercase().startsWith("::ffff:") && it.contains('.')) it.substring(7) else it }
            return mapped.equals(from, ignoreCase = true)
        }

        /** Kayıtlı olmayan TV'nin uygulaması bağlandı: günlük satırı (Mac/iPhone ve Windows ile aynı metin). */
        fun otherTvReportLine(reporter: String, saved: String, version: String): String =
            "TV uygulaması kayıtlı TV'den ($saved) değil, başka bir TV'den ($reporter) bağlandı, sürüm " +
                "${version.ifEmpty { "< 0.9.69" }}; kayıtlı TV için güncelleme ya da kurulum önerilmiyor."

        /** TV'nin bildirdiği sürüm (boş: sürüm bildirmeyen eski TV uygulaması) bu cihazdaki TV paketinden eski mi? */
        fun isTvAppOutdated(reported: String, bundled: String): Boolean {
            if (bundled.isEmpty()) return false
            if (reported.isEmpty()) return true
            val x = bundled.split('.').map { it.toIntOrNull() ?: 0 }
            val y = reported.split('.').map { it.toIntOrNull() ?: 0 }
            for (i in 0 until maxOf(x.size, y.size)) {
                val left = x.getOrElse(i) { 0 }
                val right = y.getOrElse(i) { 0 }
                if (left != right) return left > right
            }
            return false
        }

        /** `hdmi` parametresi: 1-4 arası tek rakam, değilse null. */
        fun hdmiPort(value: String?): Int? = value?.singleOrNull()?.takeIf { it in '1'..'4' }?.let { it - '0' }

        /**
         * `/hello` yanıtı: uygulama, kurulum kimliği, bağlı TV sayısı ve `live` (Mac ve Windows ile aynı biçim). `live`: bu
         * telefon çeviriyor ve altyazıyı TV'ye gönderiyor (1) ya da boşta (0). Aynı ağda iki CouchSubs varken TV kayıtlı ama
         * boştaki CouchSubs'a bağlı kalıyor, "bağlı" görünüp altyazı hiç gelmiyordu; TV çevireni bununla seçer.
         */
        fun helloBody(id: String, tvs: Int, live: Boolean = false): String =
            "{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"${id.filter { it.isLetterOrDigit() && it.code < 128 || it == '-' }}\",\"tvs\":${maxOf(0, tvs)},\"live\":${if (live) 1 else 0}}"

        /** Bağlantı canlı tutma: yorum satırını EventSource görmez; adlı "ping" olayını TV görür. */
        const val PING_FRAME = ": ping\n\nevent: ping\ndata: {}\n\n"

        /** Bu süre alındı gelmeyen (bir kez göndermiş) TV bağlantısı kopmuş sayılır: üç ping (bkz. [onTvStale]). */
        fun ackTimeoutMs(pingIntervalMs: Long): Long = pingIntervalMs * ACK_MISS_LIMIT

        /** Bu kadar ping turu alındısız geçerse bağlantı kopmuş sayılır (#1055: saat değil, gönderilen ping sayılır). */
        const val ACK_MISS_LIMIT = 3

        private val LINK_LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        private val random = java.security.SecureRandom()

        /** `link` olayındaki bağlantı kimliği: tahmin edilemez, URL'de kaçışsız gider. */
        fun makeLinkId(): String = String(CharArray(16) { LINK_LETTERS[random.nextInt(LINK_LETTERS.length)] })

        fun frame(name: String, json: Map<String, Any?>) = "event: $name\ndata: ${Json.write(json)}\n\n"

        fun boxJson(box: TextBox) = mapOf(
            "bottom" to Json.Decimal(box.bottom), "left" to Json.Decimal(box.left),
            "right" to Json.Decimal(box.right), "top" to Json.Decimal(box.top),
        )

        /**
         * [speakerColors]: açıksa satırlardaki konuşanlar renkleriyle `speakerNames` alanında gider; TV yalnız adı boyar
         * (bkz. [SpeakerColors]). Eski `speakers` alanı gönderilmez: 0.9.79'dan eski TV uygulamaları onunla bütün satırı
         * boyuyor, kullanıcının yazı rengini eziyordu.
         */
        fun subtitleFrame(
            text: String, durationMs: Int, box: TextBox?, at: Long, paragraphs: Boolean = false, replaces: Boolean = false,
            speakerColors: Boolean = false, keep: TextBox? = null,
        ): String {
            val json = mutableMapOf<String, Any?>("at" to at, "duration" to durationMs, "text" to text)
            // Ekrandaki görev satırının yeri: TV/OBS altyazı kutusunu onun üstüne taşır (eski TV yok sayar).
            if (keep != null && !paragraphs) json["keep"] = boxJson(keep)
            if (paragraphs) json["paragraphs"] = true
            if (replaces) json["replace"] = true
            // Konuşan adı yoksa ya da ayar kapalıysa alan hiç yazılmaz; eski TV uygulamaları alanı yok sayar.
            if (speakerColors) SpeakerColors.speakers(text).takeIf { it.isNotEmpty() }?.let { speakers ->
                json["speakerNames"] = speakers.map { mapOf("color" to it.color, "name" to it.name) }
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
        ): String = frame("region", regionJson(id, text, box, lineHeight, icons, blocks))

        /** [regionFrame]'in verisi; gösterilen alanlar TV'ye yeniden gönderilmek üzere saklanır ([liveRegions]). */
        fun regionJson(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>? = null,
            blocks: List<ScreenTranslation.Item>? = null,
        ): Map<String, Any?> {
            val (text, blocks) = guarded(text, box, blocks)
            val json = mutableMapOf<String, Any?>("id" to id, "text" to text)
            if (!icons.isNullOrEmpty()) json["icons"] = iconsJson(icons)
            // Alanda ayrı duran yazı gruplarının çevirileri kendi yerleriyle; eski TV uygulamaları birleşik `text`'i gösterir.
            if (!blocks.isNullOrEmpty() && text.isNotEmpty()) json["blocks"] = blocks.map { itemJson(it, phone = id == GAME_PHONE_ID) }
            if (box != null) json["box"] = boxJson(box)
            if (lineHeight != null) json["line"] = Json.Decimal(Math.round(lineHeight.coerceIn(0.0, 1.0) * 10000) / 10000.0)
            return json
        }

        /** Saklanan alanın yeniden gönderimi: `keep` ile TV aynı alanı yeniden çizmez, yalnız ömrünü uzatır. */
        private fun keptFrame(json: Map<String, Any?>) = frame("region", json + ("keep" to true))

        /** Gösterilen ek alanların TV'de yenilenme aralığı (TV'deki 15 sn'lik ömrün üçte biri; tv-webos REGION_LIFE_MS). */
        const val REGION_REFRESH_MS = 5_000L

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
                // Sohbet panelinin balonları panelin zemininin içindedir: toplam alana bir kez (zemin olarak) girer (Mac ile aynı).
                if (kept.filter { it.panel == null || it.panel == ScreenPhoneCard.PanelPart.CARD }.sumOf { area(it.box) } > MAX_BOX_AREA) return "" to null
                if (kept.isNotEmpty()) return text to kept
                rest = null
            }
            return if (box != null && area(box) > MAX_BOX_AREA) "" to null else text to rest
        }

        /** Yeriyle bir çeviri ("Ekranı çevir" öğesi ya da ek alan bloğu). */
        private fun itemJson(item: ScreenTranslation.Item, phone: Boolean = false): Map<String, Any?> {
            val json = mutableMapOf<String, Any?>(
                "box" to boxJson(item.box), "line" to Json.Decimal(Math.round(item.lineHeight.coerceIn(0.0, 1.0) * 10000) / 10000.0),
                "text" to item.translation,
            )
            if (item.paragraphs) json["paragraphs"] = true
            // Yerleşim ([ScreenFit]): kutunun genişleyebileceği alan ve özgün satır sayısı (eski TV yok sayar).
            item.room?.let { json["room"] = boxJson(it) }
            if (item.rows > 1) json["rows"] = item.rows
            item.icons?.takeIf { it.isNotEmpty() }?.let { json["icons"] = iconsJson(it) }
            // Otomatik ekran yazısının özgün görünüşü; eski TV uygulamaları bu alanları yok sayar.
            // Oyun telefonunun balonu yalnız zemin ve yazı rengini taşır (Mac/iPhone ve Windows ile aynı; `flat` yok).
            item.surface?.let {
                if (!phone) json["surface"] = mapOf("background" to it.background, "flat" to it.flat, "foreground" to it.foreground)
                else if (isRgb(it.background) && isRgb(it.foreground)) json["surface"] = mapOf("background" to it.background, "foreground" to it.foreground)
            }
            item.look?.let { json["style"] = mapOf("align" to it.align, "bold" to it.bold, "condensed" to it.condensed, "upper" to it.upper) }
            // Yerinde birebir çizim ([TextPaint]; eski TV yok sayar): opak kutu tam örtü sınırında, ölçülen zeminle (degrade
            // dahil), yazı özgün renk, kalınlık, büyük harf, hiza ve satır aralığıyla; grup aynı boyda, boş alana uzayabilir.
            val paint = item.paint
            val look = item.look
            val surface = item.surface
            if (paint != null && look != null && surface != null && isRgb(paint.background) && isRgb(surface.foreground)) {
                json["bg"] = paint.background
                val second = paint.background2
                if (second != null && isRgb(second) && paint.direction != null) {
                    json["bg2"] = second
                    json["bgDir"] = paint.direction
                }
                if (paint.patterned) json["bgPat"] = true
                json["fg"] = surface.foreground
                json["weight"] = if (look.bold) 700 else 400
                json["upper"] = look.upper
                json["align"] = look.align
                json["lineH"] = Json.Decimal(Math.round(paint.pitch.coerceIn(0.0, 1.0) * 10000) / 10000.0)
                json["cover"] = boxJson(paint.cover)
                paint.grow?.let { json["grow"] = boxJson(it) }
                paint.group?.let { json["group"] = it }
                // Çizim kipi ([TextPaint.mode]; TV uygulaması 0.9.108): yanına yazma ya da ikiz panel. Eski TV alanları yok
                // sayıp yukarıdaki örtüyle çizer.
                val spot = paint.spot
                val room = paint.spotRoom
                if (paint.mode != TextPaint.MODE_COVER && spot != null && room != null) {
                    json["mode"] = paint.mode
                    json["spot"] = boxJson(spot)
                    json["spotRoom"] = boxJson(room)
                    // Menüde yanına yazılan Türkçenin etiket zemini (TV uygulaması 0.9.124; eski TV zeminsiz yazar).
                    val label = paint.label
                    if (paint.mode == TextPaint.MODE_BESIDE && label != null && isRgb(label)) json["label"] = label
                    val twin = paint.twin
                    if (paint.mode == TextPaint.MODE_TWIN && twin != null) {
                        json["twinBox"] = boxJson(twin)
                        json["radius"] = Json.Decimal(Math.round(paint.radius.coerceIn(0.0, 1.0) * 10000) / 10000.0)
                        json["scale"] = Json.Decimal(Math.round(paint.scale.coerceIn(0.0, 1.0) * 10000) / 10000.0)
                        paint.tail?.let { json["tail"] = it }
                        // Kenar çizgisi (TV uygulaması 0.9.109; eski TV yok sayar).
                        val edge = paint.edge
                        if (edge != null && isRgb(edge.color)) {
                            fun unit(v: Double) = Json.Decimal(Math.round(v.coerceIn(0.0, 1.0) * 10000) / 10000.0)
                            json["edge"] = mapOf("color" to edge.color, "top" to unit(edge.top), "right" to unit(edge.right),
                                "bottom" to unit(edge.bottom), "left" to unit(edge.left))
                        }
                        val image = paint.portraitImage
                        val at = paint.portraitTwin
                        // Görev kartının resmi köşeli kare (TV uygulaması 0.9.124; eski TV yuvarlak çizer).
                        if (image != null && at != null) {
                            json["icon"] = if (paint.portraitSquare) mapOf("src" to image, "box" to boxJson(at), "square" to true)
                                else mapOf("src" to image, "box" to boxJson(at))
                        }
                    }
                }
            }
            // Telefon mesajı kendi balonunda: TV çeviriyi balona sığdırır (eski TV yok sayar, özgün stilde çizer).
            if (item.bubble) json["bubble"] = true
            // Telefonun yanındaki sohbet panelinin parçası: yeni TV paneli akışla çizer; eski TV alanı yok sayar.
            item.panel?.let { json["panel"] = it.wire }
            // Hizalı panel (TV uygulaması 0.9.106): parçalar kutularının yerinde, zeminsiz; eski TV akışla çizer (Mac ile aynı).
            if (item.aligned) json["aligned"] = true
            // Liste kartı (TV uygulaması 0.9.110): avatar, kalın ad, önizleme, rozet, seçim çerçevesi. Eski TV yok sayar,
            // `text`'i (ad ve önizleme iki satır) yerinde çizer (iPhone ile aynı).
            item.listRow?.let { json["row"] = rowJson(it) }
            return json
        }

        fun rowJson(row: ScreenPhoneCard.ListRow): Map<String, Any> {
            val json = linkedMapOf<String, Any>("name" to row.name, "preview" to row.preview)
            row.avatar?.let { json["avatar"] = it }
            row.badge?.let { json["badge"] = it }
            row.selected?.takeIf(::isRgb)?.let { json["selected"] = it }
            if (row.widget) json["widget"] = true
            return json
        }

        private fun isRgb(color: String) =
            color.length == 7 && color[0] == '#' && color.drop(1).all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

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
                "displayMode" to when (style.displayMode) {
                    TvDisplayMode.OVERLAY -> "overlay"
                    TvDisplayMode.IN_APP_ONLY -> "inAppOnly"
                    TvDisplayMode.AUTO -> "inApp"
                },
                "fontSize" to style.fontSize,
                "placement" to style.placement.name.lowercase(Locale.ROOT),
                "setApart" to setApart,
                "stackPrevious" to style.stackPrevious,
                "textColor" to style.textColor.name.lowercase(Locale.ROOT),
                // Mac/iPhone SubtitleStyle.json ile aynı alanlar; textHex ve hdmiInput yalnız seçildiyse gider.
                "backgroundColor" to (SubtitleStyle.hex(style.backgroundColor) ?: SubtitleStyle.DEFAULT_BACKGROUND_COLOR),
                "nameOnly" to style.nameOnly,
                "wholeLine" to (style.nameColorMode == NameColorMode.LINE),
            ) + listOfNotNull(
                SubtitleStyle.hex(style.textHex)?.let { "textHex" to it },
                style.hdmiInput?.takeIf { it in 1..4 }?.let { "hdmiInput" to it },
            )
        )
    }

    /** [legacy]: sürüm bildirmeyen (0.9.69'den eski) TV uygulaması; `clear` ona geciktirilerek gider ([legacyClearHoldMs]). */
    /**
     * [link]: `link` olayıyla TV'ye bildirilen kimlik (izleyicide boş). [ackMisses]: son alındıdan beri geçen ping turu;
     * -1 ise bu bağlantı hiç alındı göndermedi (eski TV uygulaması), alındı denetimi ona uygulanmaz.
     */
    private class Client(val socket: Socket, val viewer: Boolean, val legacy: Boolean = false, val link: String = "") {
        val output: OutputStream = socket.getOutputStream()
        @Volatile var ackMisses: Int = -1
    }

    private val lock = Any()
    private val clients = mutableListOf<Client>()
    private var listener: ServerSocket? = null
    private var pinger: ScheduledExecutorService? = null
    private var lastStyle: SubtitleStyle? = null

    /**
     * Gösterilen ek alanların son `region` olayları ([lock] ile). TV yeniden bağlanınca bunlar yeniden gönderilir,
     * gösterilmeyenler kaldırılır (`region-sync`); her [regionRefreshMs]'de telefon kartı dışındakiler `keep` bayrağıyla
     * yenilenir. TV, yenilenmeyen alanı 15 sn sonra kendisi kaldırır: kopukken kaçan boşaltma olayı yüzünden menü ve
     * tabela çevirisi ekranda kalıyordu (#1198; Mac/iPhone ve Windows SubtitleServer.liveRegions ile aynı).
     */
    private val liveRegions = HashMap<String, Map<String, Any?>>()

    /** [liveRegions]'ın yenilenme aralığı; [start]'tan önce ayarlanır (testler kısaltır). */
    internal var regionRefreshMs = REGION_REFRESH_MS

    /** Ek alanların okuma turunun en son döndüğü an ([regionsAlive]; -1: hiç bildirilmedi). */
    @Volatile private var regionAliveAt = -1L

    /** Ek alanların okuma turu döndü ([RegionSender.regionsAlive]). */
    override fun regionsAlive() {
        regionAliveAt = uptimeMs()
    }

    private fun regionsFresh(): Boolean = keepsRegions(regionAliveAt, uptimeMs())

    /** "Ekran yazılarını altyazıdan ayır" (bkz. [styleFrame]); değişince [sendStyle] yeniden çağrılmalı. */
    @Volatile var setApart: Boolean = true

    /** Bağlı TV sayısı değişince çağrılır (sunucunun iş parçacığında). */
    @Volatile var onClientsChanged: ((Int) -> Unit)? = null

    /**
     * TV'nin alındısı (bağlantı denetimi; Mac/iPhone ve Windows ile aynı). Ping yalnız telefondan TV'ye gidiyordu; TV'nin
     * onu gerçekten aldığı bilinmiyordu. LG uygulaması arka plana düşüp askıya alınınca (ya da Android TV uygulamayı
     * dondurunca) TV'nin ağ katmanı soketi açık tutuyor, gönderim hatası hiç gelmiyordu: telefon saatlerce "Bağlı"
     * gösteriyor, altyazı TV'ye ulaşmıyordu; ancak CouchSubs'tan çıkıp girince düzeliyordu. Akış açılınca `link` olayı
     * bağlantının kimliğini (`id`) taşır; 0.9.76+ TV her ping'de (ve `link`'te) `GET /ack?c=<id>` gönderir. Bir kez alındı
     * gönderen bağlantıdan [ACK_MISS_LIMIT] ping turu alındı gelmezse bağlantı kopmuş sayılıp kapatılır (TV sayısı düşer);
     * TV'den başka bağlantı kalmadıysa bu çağrılır (ping iş parçacığında): çağıran "Yeniden bağlanılıyor" gösterip TV
     * bekçisini yeniler. Hiç alındı göndermeyen eski TV uygulaması eskisi gibi kalır. Bilinmeyen kimliğe 404 döner: TV
     * hemen yeniden bağlanır.
     */
    @Volatile var onTvStale: (() -> Unit)? = null

    /** Altyazı ve temizleme olayları gönderildiği anda buraya da verilir (telefon ekranındaki görünüm için). */
    @Volatile var onEvent: ((SubtitleEvent) -> Unit)? = null

    /** false ise altyazı olayları TV'lere gitmez (altyazı yalnız telefon ekranında). */
    @Volatile var sendsToTv: Boolean = true
    /** "Konuşan adını renklendir": altyazı olayına konuşanların renkleri eklenir (`speakerNames`). */
    @Volatile var speakerColors: Boolean = false

    val connectedClients: Int get() = synchronized(lock) { clients.count { !it.viewer } }

    /**
     * TV uygulamasının gösterdiği HDMI girişi (1-4): altyazı akışına bağlanırken `/events?hdmi=2` ile bildirir. Bağlantı
     * kopsa da son bildirilen akılda kalır. LG bekçisi PS tuşunun TV'yi konsol girişine geçirmesini kullanıcının başka
     * girişe geçmesinden bununla ayırır (Windows ve Mac/iPhone ile aynı). Eski TV uygulaması bildirmez: null.
     */
    @Volatile var consolePort: Int? = null
        private set

    /**
     * Bağlanan TV uygulamasının altyazı akışıyla bildirdiği sürüm (`/events?v=0.9.69`). null: bu çalışmada henüz TV
     * bağlanmadı. Boş: bağlanan TV sürüm bildirmedi, yani 0.9.69'den eski bir TV uygulaması. LG'de geliştirici modu
     * kapalıyken ya da anahtar bu telefonda değilken TV'deki sürüm başka yoldan okunamıyor, TV uygulaması eski kalıyor ve
     * hiç "TV uygulamasını güncelle" çıkmıyordu (GitHub #884, #891). Windows ve Mac/iPhone ile aynı.
     */
    @Volatile var tvAppVersion: String? = null
        private set

    /** TV uygulaması altyazı akışına her bağlandığında bildirdiği sürümle (boş: eski TV uygulaması) çağrılır (sunucunun iş parçacığında). */
    @Volatile var onTvAppVersion: ((version: String, host: String) -> Unit)? = null

    /**
     * Bu telefonun paketindeki TV uygulamasının sürümü: `link` olayının `latest` alanıyla TV'ye bildirilir. TV'deki
     * uygulama bundan eskiyse TV'nin paneli "TV uygulaması eski" der (GitHub #1199: LG'de 0.9.71 kalmıştı, düzeltme
     * 0.9.94'teydi). null ya da boş: alan gönderilmez. Windows ve Mac/iPhone ile aynı.
     */
    @Volatile var latestTvAppVersion: String? = null

    /** Sunucuyu başlatır ve dinlenen portu döner (port 0 ise rastgele seçilen). */
    fun start(): Int {
        val socket = ServerSocket()
        socket.reuseAddress = true
        socket.bind(InetSocketAddress(port))
        listener = socket
        thread(name = "CouchSubs SSE accept", isDaemon = true) { acceptLoop(socket) }
        pinger = Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "CouchSubs SSE ping").apply { isDaemon = true } }
            .also {
                it.scheduleWithFixedDelay({
                    dropSilentTvs()
                    broadcast(PING_FRAME)
                }, pingIntervalMs, pingIntervalMs, TimeUnit.MILLISECONDS)
                it.scheduleWithFixedDelay(::refreshRegions, regionRefreshMs, regionRefreshMs, TimeUnit.MILLISECONDS)
            }
        return socket.localPort
    }

    /**
     * `keepPairing`: sunucu hemen yeniden açılacaksa eşleştirme durumu korunur. Sıradan kapanış (çeviri durdu) onay
     * bekleyen isteği ve "TV eşleştir" süresini siler.
     */
    fun stop(keepPairing: Boolean = false) {
        if (!keepPairing) pairing.setSession(false)
        pinger?.shutdownNow()
        pinger = null
        try {
            listener?.close()
        } catch (error: IOException) {
        }
        listener = null
        val closing = synchronized(lock) {
            // Sunucu hemen yeniden açılacaksa TV yeniden bağlanınca gösterilen alanlar geri gelsin.
            if (!keepPairing) liveRegions.clear()
            clients.toList().also { clients.clear() }
        }
        closing.forEach { closeQuietly(it.socket) }
        sender.shutdown()
    }

    override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
        synchronized(lock) {
            legacyHoldGeneration++
            legacyHoldUntil = System.currentTimeMillis() + legacyClearHoldMs(text.length)
        }
        val keep = synchronized(lock) { objective }
        broadcast(subtitleFrame(text, durationMs, box, clock(), replaces = replaces, speakerColors = speakerColors, keep = keep), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Subtitle(text, durationMs, replaces, box))
    }

    private var objective: TextBox? = null

    /**
     * Ekrandaki görev satırının karedeki yeri (yoksa null; [MissionLine.clearance]). Değişince `objective` olayı gider ve
     * sonraki her altyazı `keep` alanında taşır (sonradan bağlanan TV de alır). TV ve OBS sayfası altyazıyı (örtüsüyle)
     * görev satırının üstüne taşır; eski TV uygulamaları yok sayar. Mac/iPhone ve Windows aynı.
     */
    override fun sendObjective(box: TextBox?) {
        synchronized(lock) {
            if (objective == box) return
            objective = box
        }
        broadcast(frame("objective", if (box != null) mapOf("box" to boxJson(box)) else emptyMap()), subtitle = true)
    }

    override fun clear() {
        val frame = clearFrame()
        val (wait, generation) = synchronized(lock) { (legacyHoldUntil - System.currentTimeMillis()) to legacyHoldGeneration }
        if (wait <= 0 || !sendsToTv) {
            broadcast(frame, subtitle = true)
        } else {
            // Eski TV'ler satırı kendileri tutmaz: `clear` onlara satırın en az görünme süresi dolunca gider.
            broadcast(frame, subtitle = true, legacy = false)
            try {
                legacyTimer.schedule({
                    if (synchronized(lock) { generation == legacyHoldGeneration }) broadcast(frame, subtitle = true, legacy = true)
                }, wait, TimeUnit.MILLISECONDS)
            } catch (error: java.util.concurrent.RejectedExecutionException) {
            }
        }
        onEvent?.invoke(SubtitleEvent.Cleared)
    }

    private var legacyHoldUntil = 0L
    private var legacyHoldGeneration = 0
    private val legacyTimer = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "CouchSubs legacy clear").apply { isDaemon = true }
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
        val blocks = if (id != GAME_PHONE_ID && blocks != null) steadied(blocks.filter { area(it.box) <= MAX_BOX_AREA }) else blocks
        if (id != GAME_PHONE_ID) {
            val visible = synchronized(screenStyle) {
                if (text.isEmpty() || blocks.isNullOrEmpty()) {
                    regionShown.remove(id)
                    regionVisible.remove(id)
                } else {
                    regionShown[id] = RegionSent(text, box, lineHeight, icons, blocks)
                    regionVisible[id] = blocks.map { !presence.hidden(it) }
                }
                blocks?.filter { !presence.hidden(it) }
            }
            if (blocks != null && visible != null && visible.size != blocks.size) {
                emitRegion(id, if (visible.isEmpty()) "" else text, box, lineHeight, icons, visible)
                return
            }
        }
        emitRegion(id, text, box, lineHeight, icons, blocks)
    }

    private fun emitRegion(
        id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?,
        blocks: List<ScreenTranslation.Item>?,
    ) {
        val json = regionJson(id, text, box, lineHeight, icons, blocks)
        // Sıra gönderimle aynı kalsın: yeni bağlanan TV, kuyruktaki son olaydan eskisini almasın.
        synchronized(lock) {
            if ((json["text"] as String).isEmpty()) liveRegions.remove(id) else liveRegions[id] = json
            broadcast(frame("region", json), subtitle = true)
        }
        if (id == GAME_PHONE_ID) {
            // Telefon ekranında oyun telefonunun çevirisi ek alan kutusu gibi tek kutuda görünür (iPhone ile aynı); büyük
            // kutu korumasından geçen balonlar gösterilir.
            val (kept, shown) = guarded(text, box, blocks)
            val balloons = if (kept.isEmpty()) emptyList() else shown ?: emptyList()
            onEvent?.invoke(SubtitleEvent.Region(id, balloons.joinToString("\n") { it.translation },
                balloons.map { it.box }.reduceOrNull { a, b -> a.union(b) }))
            return
        }
        onEvent?.invoke(SubtitleEvent.Region(id, text, box, blocks?.takeIf { text.isNotEmpty() }))
    }

    override fun clearRegions() {
        synchronized(screenStyle) {
            regionShown.clear()
            regionVisible.clear()
        }
        synchronized(lock) {
            liveRegions.clear()
            broadcast(frame("region-clear", emptyMap()), subtitle = true)
        }
        onEvent?.invoke(SubtitleEvent.RegionsCleared)
    }

    /**
     * Ekran yazısı çevirilerinin görünüşü oturum boyunca kilitli ([ScreenStyleLock]); "Ekranı çevir" ve otomatik ekran yazısı
     * aynı kilidi paylaşır (Mac: SubtitleServer.steadied, Windows: SubtitleServer.Steadied).
     */
    private val screenStyle = ScreenStyleLock()

    internal fun steadied(items: List<ScreenTranslation.Item>): List<ScreenTranslation.Item> =
        synchronized(screenStyle) { screenStyle.steady(items, monotonicClock()) }

    /** Ekran yazısının görünüşü yeniden ölçülsün (oturum yeniden başladı). */
    fun resetScreenStyle() = synchronized(screenStyle) {
        screenStyle.reset()
        presence.reset()
    }

    /** Ekrandaki çeviriler ve özgün yazılarının takibi ([ScreenPresence]). */
    private val presence = ScreenPresence()
    /** [ScreenPresence]'ın kaldırma ve geri getirme kararları altyazı günlüğüne ([DropLog]; sınırlı, tekrarsız). */
    private val presenceDrops = DropLog()
    private var screenShown: Pair<List<ScreenTranslation.Item>, Long>? = null
    /**
     * Her [sendScreen] ve [clearScreen] bir üst numara verir. [observe] değişikliği kilidin dışında gönderir; arada
     * çeviri kaldırıldıysa eski öğeler yeniden gönderilmez (kaldırılan çeviri TV'de ve telefonda geri çiziliyordu, #1182).
     */
    private var screenEpoch = 0L
    private var screenVisible: List<Boolean> = emptyList()
    private data class RegionSent(
        val text: String, val box: TextBox?, val lineHeight: Double?, val icons: List<IconPlacement>?,
        val blocks: List<ScreenTranslation.Item>,
    )
    private val regionShown = java.util.TreeMap<String, RegionSent>()
    private val regionVisible = mutableMapOf<String, List<Boolean>>()

    /**
     * Her karede çağrılır: çevirisi gösterilen yazılar hâlâ yerinde mi ([ScreenPresence]). Özgün yazısı kalkan öğe TV'den ve
     * telefon ekranından aynı karede kalkar; geri gelirse yeniden gösterilir (Mac: SubtitleServer.observe, Windows:
     * SubtitleServer.Observe). [patch]: kutunun bu karedeki izi ([ScreenPresence.patch]).
     */
    fun observe(patch: (TextBox) -> List<Int>?) {
        val now = monotonicClock()
        var screenChange: List<ScreenTranslation.Item>? = null
        val regionChanges = mutableListOf<Triple<String, RegionSent, List<ScreenTranslation.Item>>>()
        var until = now
        val flips = mutableListOf<Pair<String, Boolean>>()
        var epoch = 0L
        synchronized(screenStyle) {
            epoch = screenEpoch
            screenShown?.let { if (it.second <= now) screenShown = null }
            val screen = screenShown?.first ?: emptyList()
            val regions = regionShown.entries.map { it.key to it.value }
            val all = screen + regions.flatMap { it.second.blocks }
            if (all.none { ScreenPresence.tracks(it) } && screenVisible.isEmpty() && regionVisible.isEmpty()) return
            val visible = presence.visible(all, patch)
            val flags = visible.take(screen.size)
            val before = if (screenVisible.isEmpty()) screen.map { true } else screenVisible
            if (screen.isNotEmpty() && flags != before) screenChange = screen.filterIndexed { i, _ -> flags[i] }
            // Kaldırma ya da geri getirme kararı günlüğe ([DropLog]): periyodik kopmalarda hangi yazının izinin kaçtığı görünsün.
            for (i in screen.indices) if (i < before.size && before[i] != flags[i]) flips.add(screen[i].source to flags[i])
            screenVisible = if (screen.isEmpty()) emptyList() else flags
            var offset = screen.size
            val previous = regionVisible.toMap()
            regionVisible.clear()
            for ((id, sent) in regions) {
                val part = visible.subList(offset, offset + sent.blocks.size).toList()
                offset += sent.blocks.size
                regionVisible[id] = part
                val was = previous[id] ?: sent.blocks.map { true }
                for (i in sent.blocks.indices) if (i < was.size && was[i] != part[i]) flips.add(sent.blocks[i].source to part[i])
                if (part != was) {
                    regionChanges.add(Triple(id, sent, sent.blocks.filterIndexed { i, _ -> part[i] }))
                }
            }
            until = screenShown?.second ?: now
        }
        for ((source, shown) in flips) {
            presenceDrops.note("ScreenPresence",
                if (shown) "özgün yazı geri geldi, çeviri yeniden gösterildi" else "özgün yazının izi kaçtı, çeviri kaldırıldı", source)
        }
        screenChange?.let { items ->
            if (synchronized(screenStyle) { screenEpoch == epoch }) emitScreen(items, maxOf(1L, until - now).toInt())
        }
        for ((id, sent, kept) in regionChanges) {
            emitRegion(id, if (kept.isEmpty()) "" else sent.text, sent.box, sent.lineHeight, sent.icons, kept.ifEmpty { null })
        }
    }

    /** "Ekranı çevir" sonuçlarını TV'ye (ve telefon ekranına) gönderir. */
    fun sendScreen(items: List<ScreenTranslation.Item>, durationMs: Int) {
        val items = steadied(items.filter { area(it.box) <= MAX_BOX_AREA })
        val shown = synchronized(screenStyle) {
            screenEpoch += 1
            screenShown = items to monotonicClock() + durationMs
            screenVisible = items.map { !presence.hidden(it) }
            items.filter { !presence.hidden(it) }
        }
        emitScreen(shown, durationMs)
    }

    private fun emitScreen(items: List<ScreenTranslation.Item>, durationMs: Int) {
        broadcast(screenFrame(items, durationMs), subtitle = true)
        onEvent?.invoke(SubtitleEvent.Screen(items, durationMs))
    }

    /** TV'deki ve telefondaki "ekranı çevir" çevirilerini kaldırır (altyazıya dokunmaz). */
    fun clearScreen() {
        synchronized(screenStyle) {
            screenEpoch += 1
            screenShown = null
            screenVisible = emptyList()
        }
        broadcast(frame("screen-clear", emptyMap()), subtitle = true)
        onEvent?.invoke(SubtitleEvent.ScreenCleared)
    }

    /** Dublaj sesleri: `/speech/<n>.wav` → WAV; son 16 ses tutulur (Swift SubtitleServer.sendSpeech ile aynı). */
    private val speechFiles = LinkedHashMap<String, ByteArray>()
    private var speechNumber = 0

    /** Dublaj sesini TV'ye gönderir: ses `/speech/<n>.wav` adresinden verilir, `speech` olayı adresi bildirir. */
    fun sendSpeech(wav: ByteArray, durationMs: Int) {
        val path = synchronized(lock) {
            speechNumber += 1
            val path = "/speech/$speechNumber.wav"
            speechFiles[path] = wav
            while (speechFiles.size > 16) speechFiles.remove(speechFiles.keys.first())
            path
        }
        broadcast(frame("speech", mapOf("duration" to durationMs, "url" to path)))
    }

    /** TV'de çalan dublajı durdurur (yeni altyazı, oturum sonu). */
    fun stopSpeech() {
        broadcast(frame("speech-stop", emptyMap()))
    }

    fun sendStyle(style: SubtitleStyle) {
        synchronized(lock) { lastStyle = style }
        // Karakter adı renkleri (Mac SubtitleServer.updateStyle gibi): tek renk ya da kullanıcının seçtiği kişi renkleri.
        SpeakerColors.session.configure(
            fixed = if (style.nameColorMode == NameColorMode.SINGLE) SubtitleStyle.hex(style.nameHex) ?: SubtitlePalette.names[0].hex else null,
            overrides = if (style.nameColorMode == NameColorMode.SPEAKER || style.nameColorMode == NameColorMode.LINE) style.characterColors else emptyMap(),
        )
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
                if (access.status == 403) rejectedOrigins.line(request)?.let { line -> DropLog.sink?.invoke(line) }
                respondAndClose(socket, if (access.status == 403) "403 Forbidden" else "401 Unauthorized", cors = if (access.status == 403) "" else cors)
                return
            }
            val method = request.method
            val path = request.path
            if (path == "/pair") {
                if (method == "POST") {
                    val ticket = pairing.begin(SubtitleAccess.tvHost(socket.inetAddress))
                    if (ticket == null) { respondAndClose(socket, "409 Conflict", cors = cors); return }
                    onPairingRequest?.invoke(ticket)
                    respondAndClose(socket, "200 OK", org.json.JSONObject().put("id", ticket.id).put("code", ticket.code).toString(), cors)
                } else if (method == "GET") {
                    val body = synchronized(lock) {
                        val state = if (request.parameter("validate") == "1") {
                            val check = request.copy(target = "/events?k=" + java.net.URLEncoder.encode(request.parameter("k") ?: "", "UTF-8"))
                            if (SubtitleAccess.authorize(check, accessKey, false).status == 200) "valid" else "expired"
                        } else pairing.poll(request.parameter("id") ?: "")
                        // Eski TV uygulamaları "rejected"ı tanımaz: "expired" görüp durur. Yenisi rejected ile Tamam bekler, yalnız
                        // "expired"da kendisi yeniden ister (GitHub #737).
                        if (state == "rejected") org.json.JSONObject().put("state", "expired").put("rejected", true).toString()
                        else org.json.JSONObject().put("state", state).apply { if (state == "approved") put("key", accessKey) }.toString()
                    }
                    respondAndClose(socket, "200 OK", body, cors)
                } else respondAndClose(socket, "405 Method Not Allowed", cors = cors)
                return
            }
            when {
                method == "OPTIONS" -> respondAndClose(socket, "204 No Content", cors = cors)
                method == "GET" && path == "/events" -> {
                    // OBS katmanı ve ikinci ekran sayfası izleyicidir: TV sayılmaz, altyazı hedefi TV değilken de olayları alır.
                    val obs = request.parameter("viewer").let { it == "obs" || it == SecondScreen.VIEWER }
                    // Anahtarsız OBS sayfası eski bir OBS adresidir; TV uygulamasının eski olduğu anlamına gelmez.
                    val notify = synchronized(lock) { (access.legacy && !obs && !hasLegacyClient).also { if (it) hasLegacyClient = true } }
                    if (notify) onLegacyClient?.invoke()
                    if (!obs) hdmiPort(request.parameter("hdmi"))?.let { consolePort = it }
                    var unreported = false
                    if (!obs) {
                        val version = tvAppVersion(request.parameter("v"))
                        tvAppVersion = version
                        unreported = version.isEmpty()
                        onTvAppVersion?.invoke(version, SubtitleAccess.tvHost(socket.inetAddress))
                    }
                    openStream(socket, obs, cors, checkedKey, unreported)
                }
                // TV uygulaması ağdaki CouchSubs'ı bu yanıtla tanır.
                method == "GET" && path == "/obs" && obsOverlay.isNotEmpty() -> respondAndClose(socket, "200 OK", obsOverlay, cors, "text/html; charset=utf-8")
                // Anahtar authorize'da denetlendi (anahtarsız istek 401 aldı).
                method == "GET" && path == SecondScreen.PATH && secondScreenPage.isNotEmpty() ->
                    respondAndClose(socket, "200 OK", secondScreenPage, cors, "text/html; charset=utf-8")
                method == "GET" && path.startsWith("/speech/") && synchronized(lock) { speechFiles.containsKey(path) } ->
                    respondAndClose(socket, "200 OK", synchronized(lock) { speechFiles[path] } ?: ByteArray(0), cors, "audio/wav")
                // TV'nin alındısı (bkz. onTvStale). Bilinmeyen kimlik: telefonda bu bağlantı yok, TV yeniden bağlanmalı.
                method == "GET" && path == "/ack" -> {
                    val id = request.parameter("c") ?: ""
                    val client = synchronized(lock) { clients.firstOrNull { !it.viewer && it.link.isNotEmpty() && it.link == id } }
                    if (client != null) {
                        synchronized(lock) { client.ackMisses = 0 }
                        respondAndClose(socket, "204 No Content", cors = cors)
                    } else respondAndClose(socket, "404 Not Found", cors = cors)
                }
                // TV uygulamasının olay satırı (TV 0.9.116; bkz. SubtitleAccess.TvEventLog): HDMI'nin yeniden kurulması,
                // sayfanın yenilenmesi, uygulamanın yeniden açılması nedeniyle günlüğe.
                method == "GET" && path == "/tvlog" -> {
                    tvEvents.line(request.parameter("m"), request.parameter("a"), System.currentTimeMillis())?.let { line -> DropLog.sink?.invoke(line) }
                    respondAndClose(socket, "204 No Content", cors = cors)
                }
                method == "GET" && path == "/hello" -> respondAndClose(socket, "200 OK", helloBody(instanceId, connectedClients, sendsToTv && pairing.inSession), cors)
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

    private fun respondAndClose(socket: Socket, status: String, body: String = "", cors: String = "", type: String = "application/json") =
        respondAndClose(socket, status, body.toByteArray(Charsets.UTF_8), cors, type)

    private fun respondAndClose(socket: Socket, status: String, data: ByteArray, cors: String, type: String) {
        val head = "HTTP/1.1 $status\r\n${cors}Content-Type: $type\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: ${data.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().apply { write(head.toByteArray(Charsets.US_ASCII)); write(data); flush() }
        closeQuietly(socket)
    }

    private fun openStream(socket: Socket, viewer: Boolean, cors: String, checkedKey: String, legacy: Boolean = false) {
        val head = StringBuilder()
            .append("HTTP/1.1 200 OK\r\n")
            .append("Content-Type: text/event-stream; charset=utf-8\r\n")
            .append("Cache-Control: no-cache\r\n")
            .append("Connection: keep-alive\r\n")
            .append(cors).append("\r\n")
            .append("retry: 2000\n\n")
        val link = if (viewer) "" else makeLinkId()
        val client = Client(socket, viewer, legacy, link)
        // Başlık, listeye girdikten sonra gelebilecek ilk olaydan önce yazılır (istemci kilidi tutulurken eklenir).
        val count = synchronized(client) {
            val count = synchronized(lock) {
                if (accessKey != checkedKey) { closeQuietly(socket); return }
                lastStyle?.let { head.append(styleFrame(it, setApart)) }
                // Bağlantı kimliği stilden sonra (Mac/iPhone ve Windows ile aynı sıra; bkz. onTvStale).
                if (!viewer) {
                    val latest = tvAppVersion(latestTvAppVersion)
                    val json = if (latest.isEmpty()) mapOf("id" to link) else mapOf("id" to link, "latest" to latest)
                    head.append("event: link\ndata: ").append(Json.write(json)).append("\n\n")
                }
                head.append(regionReplay(tv = viewer || sendsToTv))
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

    /**
     * Bir ping turu (ping gönderilmeden hemen önce): son alındıdan beri [ACK_MISS_LIMIT] turdan fazla geçmiş TV
     * bağlantılarını kapatır; kapattıysa true. #1055 (beta.86): süre saatle ölçülüyordu; zamanlayıcı gecikince (telefon
     * uyudu, uygulama arka planda kısıtlandı) ping gitmediği halde sağlam TV "susmuş" sayılıyordu. Artık alındısız geçen
     * ping turları sayılır. [onTvStale] de yalnız TV'den hiç bağlantı kalmadıysa çağrılır: TV yeni akışını açmışken eski,
     * yarı açık bağlantısının susması bekçiyi yenilemez (yenilenen bekçi LG'de açık uygulamayı yeniden başlatıyor, ekran
     * kararıyordu). Mac/iPhone ve Windows ile aynı.
     */
    internal fun dropSilentTvs(): Boolean {
        val (silent, remaining) = synchronized(lock) {
            val found = mutableListOf<Client>()
            for (client in clients) {
                if (client.viewer || client.ackMisses < 0) continue
                if (client.ackMisses + 1 > ACK_MISS_LIMIT) found.add(client) else client.ackMisses++
            }
            found to clients.count { !it.viewer && it !in found }
        }
        if (silent.isEmpty()) return false
        silent.forEach { remove(it) }
        if (remaining == 0) onTvStale?.invoke()
        return true
    }

    /**
     * Yeni bağlanan TV'ye (ya da OBS'e) gösterilen ek alanlar: önce `region-sync` (listede olmayan alanları TV kaldırır;
     * kopukken kaçan boşaltma olayları), sonra her alanın son `region` olayı `keep` bayrağıyla (TV'de duran aynı alan
     * yeniden çizilmez). [lock] tutulurken çağrılır.
     */
    private fun regionReplay(tv: Boolean): String {
        val live = if (tv && regionsFresh()) liveRegions.entries.sortedBy { it.key } else emptyList()
        val out = StringBuilder(frame("region-sync", mapOf("ids" to live.map { it.key })))
        for ((_, json) in live) out.append(keptFrame(json))
        return out.toString()
    }

    /**
     * Gösterilen ek alanları (telefon kartı hariç) `keep` bayrağıyla yeniden gönderir: sahnede kalan yazının çevirisi TV'deki
     * 15 sn'lik ömrü dolup kalkmasın. Telefon kartı kendi okumasıyla sık güncellenir.
     */
    internal fun refreshRegions() {
        if (!regionsFresh()) return
        synchronized(lock) {
            for ((id, json) in liveRegions.entries.sortedBy { it.key }) {
                if (id != GAME_PHONE_ID) broadcast(keptFrame(json), subtitle = true)
            }
        }
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
    /** [legacy]: null herkes; false sürüm bildirmeyen TV'ler dışındakiler; true yalnız onlar. */
    private fun broadcast(frame: String, subtitle: Boolean = false, legacy: Boolean? = null) {
        val toTvs = !subtitle || sendsToTv
        val targets = synchronized(lock) { clients.filter { (toTvs || it.viewer) && (legacy == null || it.legacy == legacy) } }
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
