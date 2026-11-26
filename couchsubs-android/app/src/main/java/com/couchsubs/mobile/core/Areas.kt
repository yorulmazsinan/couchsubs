// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.math.abs

/** Altyazı bölgesinin hazır seçimleri (Ayarlar › Altyazı alanı). Mac/iPhone AreaPreset.swift ve Windows AreaPreset.cs ile aynı. */
enum class AreaPreset {
    /** Ekranın altı: oyunların çoğu altyazıyı orada gösterir (varsayılan bölge). */
    BOTTOM,
    TOP,
    FULL,
    /** Kullanıcının ayarladığı bölge. */
    CUSTOM;

    /** Hazır seçimin bölgesi; [CUSTOM] için null (kayıtlı bölge kullanılır). */
    val region: CropRegion?
        get() = when (this) {
            BOTTOM -> CropRegion()
            TOP -> CropRegion(top = 0.03, bottom = 0.38, left = 0.14, right = 0.86)
            FULL -> CropRegion(top = 0.0, bottom = 1.0, left = 0.0, right = 1.0)
            CUSTOM -> null
        }

    companion object {
        /** Bölge bir hazır seçimle aynıysa o, değilse [CUSTOM]. */
        fun matching(region: CropRegion): AreaPreset = entries.firstOrNull { it.region?.isClose(region) == true } ?: CUSTOM
    }
}

/** Bölgenin en küçük yüksekliği ve genişliği (kenara oranla). */
const val MINIMUM_REGION_SIZE = 0.05

/** Üst kenarı [position], yüksekliği [height] yüzde olan bölge; sol ve sağa dokunulmaz, kare dışına taşmaz. */
fun CropRegion.withVertical(position: Double, height: Double): CropRegion {
    val h = (height / 100).coerceIn(MINIMUM_REGION_SIZE, 1.0)
    val t = (position / 100).coerceIn(0.0, 1 - h)
    return copy(top = t, bottom = t + h)
}

/** Bölge yatayda [dx], dikeyde [dy] kadar kaydırılır; boyutu değişmez, kare dışına taşmaz. */
fun CropRegion.moved(dx: Double, dy: Double): CropRegion {
    val width = right - left
    val height = bottom - top
    val l = (left + dx).coerceIn(0.0, 1 - width)
    val t = (top + dy).coerceIn(0.0, 1 - height)
    return CropRegion(top = t, bottom = t + height, left = l, right = l + width)
}

/** Sağ alt köşe ([right], [bottom]) noktasına taşınır; bölge en az [MINIMUM_REGION_SIZE] kalır. */
fun CropRegion.resized(right: Double, bottom: Double): CropRegion = CropRegion(
    top = top, bottom = bottom.coerceIn(top + MINIMUM_REGION_SIZE, 1.0),
    left = left, right = right.coerceIn(left + MINIMUM_REGION_SIZE, 1.0),
)

fun CropRegion.isClose(other: CropRegion, tolerance: Double = 0.001) =
    abs(top - other.top) <= tolerance && abs(bottom - other.bottom) <= tolerance &&
        abs(left - other.left) <= tolerance && abs(right - other.right) <= tolerance

fun CropRegion.toJson(): JSONObject = JSONObject().put("top", top).put("bottom", bottom).put("left", left).put("right", right)

fun cropRegionFrom(json: JSONObject?): CropRegion? = json?.let {
    try {
        CropRegion(it.getDouble("top"), it.getDouble("bottom"), it.getDouble("left"), it.getDouble("right"))
    } catch (error: Exception) {
        null
    }
}

/** Kısayolla bir kez okunan alanın sonucunun gösterildiği yer (Mac/iPhone ResultTarget, Windows ResultTarget). */
enum class ResultTarget(val json: String) {
    TV("tv"), PC("pc"), BOTH("both");

    companion object {
        /** Eski kayıtta yoktur; bilinmeyen değer de TV sayılır. */
        fun fromJson(value: String?): ResultTarget = entries.firstOrNull { it.json == value } ?: TV
    }
}

/**
 * Altyazı alanının yanındaki ek alan (görev yazısı, telefon mesajı, bildirim). Dört platformda aynı model: adlı liste, en
 * çok [ExtraArea.MAX_COUNT] (Mac/iPhone ExtraArea.swift, Windows Contracts.cs ExtraArea). Sürekli okunan alanlar ana
 * altyazıdan ayrı ve daha seyrek okunur ([RegionWatcher]); çevirileri TV'de kendi yerlerinde küçük kutuda görünür.
 * [enabled]: "Bu alanı sürekli oku". [target]: masaüstünde kısayolla okununca sonucun yeri; telefonda sonuç her zaman
 * TV'dedir, alan aynı modelle saklanır.
 */
data class ExtraArea(
    val id: String = UUID.randomUUID().toString(), val name: String, val region: CropRegion, val enabled: Boolean = true,
    val target: ResultTarget = ResultTarget.TV,
    /** Ekran yazısı bulucusunun ([ScreenTextDetector]) geçici alanı; kaydedilmez, gürültüsü elenir, sık okunur. */
    val auto: Boolean = false,
    /** Otomatik alan menü durumunda bulundu: kısa etiketler de çevrilir ([ScreenTextNoise]). */
    val menu: Boolean = false,
) {
    companion object {
        /** En çok bu kadar ek alan tanımlanır (her biri saniyede bir okunur). */
        const val MAX_COUNT = 50

        fun listToJson(areas: List<ExtraArea>): String = JSONArray().also { array ->
            areas.forEach {
                array.put(JSONObject().put("id", it.id).put("name", it.name).put("region", it.region.toJson()).put("enabled", it.enabled)
                    .put("target", it.target.json))
            }
        }.toString()

        fun listFromJson(text: String?): List<ExtraArea> = try {
            val array = JSONArray(text ?: "[]")
            (0 until array.length()).map { array.getJSONObject(it) }.map { item ->
                ExtraArea(item.optString("id").ifEmpty { UUID.randomUUID().toString() }, item.optString("name"),
                    cropRegionFrom(item.optJSONObject("region")) ?: ExtraAreaPreset.QUEST.region, item.optBoolean("enabled", true),
                    ResultTarget.fromJson(item.optString("target").ifEmpty { null }))
            }.take(MAX_COUNT)
        } catch (error: Exception) {
            emptyList()
        }
    }
}

/** Ek alanın hazır seçimleri: oyunların çoğu bu yazıları ekranın köşelerinde gösterir. */
enum class ExtraAreaPreset(val region: CropRegion) {
    /** Sağ üstteki görev yazısı. */
    QUEST(CropRegion(top = 0.03, bottom = 0.30, left = 0.66, right = 0.98)),
    /** Sol alttaki bildirim. */
    NOTIFICATION(CropRegion(top = 0.58, bottom = 0.88, left = 0.02, right = 0.30)),
    /** Sağ alttaki telefon mesajı ya da e-posta. */
    PHONE(CropRegion(top = 0.50, bottom = 0.95, left = 0.72, right = 0.98));

    companion object {
        fun matching(region: CropRegion): ExtraAreaPreset? = entries.firstOrNull { it.region.isClose(region) }
    }
}

/** Açık ek alanlar (en çok [ExtraArea.MAX_COUNT]). */
fun List<ExtraArea>.active(): List<ExtraArea> = filter { it.enabled }.take(ExtraArea.MAX_COUNT)

/**
 * Okunacak ek alanlar: altyazı alanı Tam ekranken hiçbiri (ekranın tamamı zaten okunuyor, ek alanlar aynı yazıyı ikinci
 * kez çevirirdi). Alanların açık/kapalı ayarı değişmez; başka bir alan seçilince eskisi gibi okunurlar (Mac/iPhone
 * activeExtraAreas, Windows WatchedAreas).
 */
fun List<ExtraArea>.watched(preset: AreaPreset): List<ExtraArea> = if (preset == AreaPreset.FULL) emptyList() else active()

/** "Ekranı çevir" ve ek alanların satır kuralları (Mac/iPhone ScreenTranslation.swift). */
object ScreenText {
    /** En az iki harfi ve iki harfli bir sözcüğü olan satır yazıdır; geri kalanı sayı ve simgedir. */
    fun isWords(text: String): Boolean =
        text.count { it.isLetter() } >= 2 && text.split(Regex("\\s+")).any { word -> word.count { it.isLetter() } >= 2 } &&
            !isDistance(text)

    private val distance = Regex("""^\s*\d[\d.,]*\s?(ft|m|mi|km|yd|yds)\s*$""", RegexOption.IGNORE_CASE)

    /**
     * Yalnız sayı ve uzaklık birimi: "124 ft", "4 ft", "2.4 mi", "300m", "1,2 km", "50 yd". Haritada kartın yanındaki
     * uzaklık göstergedir, çevrilmez (Mac/iPhone ve Windows ile aynı).
     */
    fun isDistance(text: String): Boolean = distance.matches(text)

    /**
     * Önceki parça cümleyi bitirdiyse ya da kısa bir başlık/menü satırıysa (en çok üç sözcük, virgülsüz) ve yeni satır
     * büyük harfle başlıyorsa yeni parça başlar; yoksa satır öncekinin devamıdır.
     */
    fun paragraphs(lines: List<TextLine>): List<String> {
        val result = mutableListOf<String>()
        for (line in lines.map { it.text.trim() }) {
            val previous = result.lastOrNull()
            if (previous != null && !startsNew(previous, line)) result[result.size - 1] = "$previous $line"
            else result.add(line)
        }
        return result
    }

    /** [paragraphs] ile aynı bölmede her parçanın kumanda simgeleri, metindeki sırasıyla (Windows: ScreenTranslation.ParagraphIcons). */
    fun paragraphIcons(lines: List<TextLine>): List<List<IconSlot>> {
        val texts = mutableListOf<String>()
        val result = mutableListOf<MutableList<IconSlot>>()
        for (line in lines) {
            val text = line.text.trim()
            val icons = line.icons ?: emptyList()
            val previous = texts.lastOrNull()
            if (previous != null && !startsNew(previous, text)) {
                texts[texts.size - 1] = "$previous $text"
                result[result.size - 1].addAll(icons)
            } else {
                texts.add(text)
                result.add(icons.toMutableList())
            }
        }
        return result
    }

    private fun startsNew(previous: String, line: String): Boolean {
        if (SubtitleStabilizer.endsSentence(previous)) return true
        return line.firstOrNull()?.isUpperCase() == true && previous.split(Regex("\\s+")).count { it.isNotEmpty() } <= 3 && !previous.endsWith(",")
    }
}

/** Bölgenin küçültülmüş gri izi (64×12) ve iki izin karşılaştırılması (Mac/iPhone ReadScheduler.changed ile aynı). */
object RegionSignature {
    const val WIDTH = 64
    const val HEIGHT = 12
    const val CHANGE_THRESHOLD = 16

    /** Gri (Y) düzleminden [WIDTH]×[HEIGHT] örnek: her hücrenin ortasındaki piksel. */
    fun of(luma: ByteArray, width: Int, height: Int): ByteArray {
        val out = ByteArray(WIDTH * HEIGHT)
        if (width <= 0 || height <= 0) return out
        for (y in 0 until HEIGHT) {
            val sy = ((y + 0.5) * height / HEIGHT).toInt().coerceIn(0, height - 1)
            for (x in 0 until WIDTH) {
                val sx = ((x + 0.5) * width / WIDTH).toInt().coerceIn(0, width - 1)
                out[y * WIDTH + x] = luma[sy * width + sx]
            }
        }
        return out
    }

    /**
     * İki iz farklı mı: bir örnek [threshold]'dan çok değiştiyse. [within] verilirse yalnız o kutunun (bölgenin kenarlarına
     * oranla) örttüğü örneklere bakılır; bölgenin başka yerindeki kıpırtı sayılmaz (Mac/iPhone: ReadScheduler.changed).
     */
    fun changed(a: ByteArray, b: ByteArray, threshold: Int = CHANGE_THRESHOLD, within: TextBox? = null): Boolean {
        if (a.size != b.size) return true
        val rows = a.size / WIDTH
        if (within == null || rows <= 0 || a.size % WIDTH != 0) {
            for (i in a.indices) if (abs((a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)) > threshold) return true
            return false
        }
        val left = kotlin.math.floor(within.left * WIDTH).toInt().coerceIn(0, WIDTH - 1)
        val right = kotlin.math.ceil(within.right * WIDTH).toInt().coerceAtMost(WIDTH).coerceAtLeast(left + 1)
        val top = kotlin.math.floor(within.top * rows).toInt().coerceIn(0, rows - 1)
        val bottom = kotlin.math.ceil(within.bottom * rows).toInt().coerceAtMost(rows).coerceAtLeast(top + 1)
        for (y in top until bottom) for (x in left until right) {
            val i = y * WIDTH + x
            if (abs((a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)) > threshold) return true
        }
        return false
    }

    /** İzdeki örneklerin [CHANGE_THRESHOLD]'dan çok değişen payı (boyları farklıysa 1). */
    fun changedShare(a: ByteArray, b: ByteArray): Double {
        if (a.size != b.size || a.isEmpty()) return 1.0
        var changed = 0
        for (i in a.indices) if (abs((a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)) > CHANGE_THRESHOLD) changed++
        return changed.toDouble() / a.size
    }
}

/** Ek alanların çevirisini TV'ye ileten taraf (gerçekte [SubtitleServer]). */
interface RegionSender {
    /** [text] boşsa alanın kutusu kalkar. */
    fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?)

    /** Çevirinin içinde kumanda simgeleri varsa ([ButtonIcons]); simgeyi bilmeyen gönderici düz metni yollar. */
    fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?) =
        sendRegion(id, text, box, lineHeight)

    /**
     * Alanda birbirinden ayrı duran yazı grupları varsa (görev başlığı ve ayrı sütundaki hedef) [blocks] her grubun
     * çevirisini kendi yeriyle taşır; TV her birini kendi İngilizce yazısının üstüne koyar. Blokları bilmeyen gönderici
     * birleşik metni yollar.
     */
    fun sendRegion(
        id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?,
        blocks: List<ScreenTranslation.Item>?,
    ) = sendRegion(id, text, box, lineHeight, icons)

    fun clearRegions()

    /**
     * Okuma turu sürüyor (her tur başında ve her alandan sonra): gösterilen alanlar yalnız tur dönerken TV'de yenilenir
     * ([SubtitleServer.REGION_ALIVE_MS]). Turu bilmeyen gönderici yok sayar.
     */
    fun regionsAlive() {}
}

/**
 * Ek alanları (görev yazısı, telefon mesajı, bildirim) ana altyazıdan ayrı ve seyrek okur, çevirip TV'ye kendi
 * yerleriyle gönderir (Mac/iPhone RegionWatcher.swift ve Windows RegionWatcher.cs ile aynı kurallar):
 * - En çok [intervalMs]'te bir tur; önceki tur bitmediyse kare atlanır. Tur çağıranın verdiği iş parçacığında sürer.
 * - Bölge izi değişmeyen alan yeniden okunmaz; okunan yazı ancak kararlıysa (iz bir tur değişmedi ya da iki okuma aynı
 *   yazıyı verdi) çevrilir. Yazı değişmedikçe yeniden çevrilmez; boşalan alanın kutusu kalkar.
 * - Paket eşleşmesi ve çeviri motoru ana altyazıyla aynıdır; ek alan satırları ortak havuza önerilmez.
 */
class RegionWatcher(
    private val read: (Crop) -> Reading,
    private val translator: TextTranslator,
    private val sender: RegionSender,
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
    private val clock: () -> Long = monotonicClock,
    /**
     * Önceden istenen çevirilerin ([prefetchesTranslations]) sürdüğü yer; verilmezse turun iş parçacığında (testler).
     * Henüz başlamamış önceden çeviri, yazı gösterilirken turun iş parçacığında çalıştırılır; beklemede kalmaz.
     */
    private val prefetchWork: Executor = INLINE,
    private val prefetchTranslator: TextTranslator = translator,
    /** Oyun telefonunun düzleştirilmiş ekranını okuyan ([GamePhoneReader]); verilmezse telefon okunmaz. */
    private val readPhone: ((GamePhoneReader.Flat) -> Reading)? = null,
) {
    /** Tur aralığının çarpanı ([ReadPressure.slowdown]): altyazı okuması yavaşken ek alanlar seyrek okunur. */
    @Volatile var slowdown: () -> Int = { 1 }

    companion object {
        /** İki tur arasındaki en kısa süre; iPhone ve Mac ile aynı (saniyede en çok bir tur, pil ve ısı için). */
        const val DEFAULT_INTERVAL_MS = 1000L

        /** Otomatik ekran yazısı alanı varken iki tur arasındaki en uzun süre. */
        const val AUTO_INTERVAL_MS = 500L

        /** Dünya yazısı sayılan yazı bu kadar süre bir daha çevrilmez (10 dk). */
        const val WORLD_TEXT_MS = 10 * 60 * 1000L

        /** Oturum terim sözlüğünde en çok bu kadar etiket tutulur. */
        private const val SESSION_TERMS = 2000

        /**
         * Ekrandakinden yalnız biraz farklı (ya da eksik) kararlı okuma en çok bu kadar tur bekletilir; o hâlde kalırsa
         * gerçekten değişmiş sayılır ve gösterilir (görevin tek sözcüğü değişebilir: "Go to the barn" → "Go to the bank").
         */
        internal const val HOLD_LIMIT = 4
        /**
         * Hazır alanda arayüz kutusu ([UiPanel.hasText]) art arda bu kadar turda bulunamazsa çeviri silinir (Mac/iPhone
         * panelMissTurns, Windows PanelMissTurns). Tek karelik ıska çeviriyi siliyordu; metin aynı kaldığı için bir daha
         * gelmiyordu (#1202).
         */
        const val PANEL_MISS_TURNS = 3

        /**
         * Çevirisi gösterilen alanda okuma en az bu kadar tur ve en az [UNSTEADY_MS] boyunca art arda değişip doğrulanamazsa
         * (yazı gitti, yerinde sahne oynuyor) çeviri kaldırılır: menü, tabela ve ipucu kutusunun çevirisi yazı oyundan
         * kalktıktan sonra TV'de kalıyordu (#1198). Yalnız tur sayısı (3 tur, 500 ms'lik turlarda 1,5 sn) arkası oynayan sabit
         * yazının çevirisini kaldırıp önbellekten geri getiriyordu: koyu kutu 2-3 sn'de bir yanıp sönüyordu (Samsung'da
         * parlaklık sıçraması). Mac/iPhone ve Windows ile aynı.
         */
        internal const val UNSTEADY_TURNS = 4
        internal const val UNSTEADY_MS = 3000L

        /** Kaldırılan yazı bu süre içinde yeniden gösterilirse yerindeydi: alanın kaldırma eşiği uzar ([MAX_PATIENCE]). */
        internal const val REBOUND_MS = 10_000L

        /** Kaldırma eşiği en çok (1 + bu) katına uzar. */
        internal const val MAX_PATIENCE = 2

        /** Ekrandaki yazının en az bu kadar harfli bir sözcüğü okumada geçiyorsa yazı hâlâ (kısmen) görünür ([partlyVisible]). */
        internal const val VISIBLE_WORD_LENGTH = 4

        /**
         * Okumada ekrandaki yazının bir parçası görünüyor: benzer ya da eksik okuma, ya da ekrandakinin en az bir uzun sözcüğü
         * ([VISIBLE_WORD_LENGTH]) okumada geçiyor (arkası oynayan yazı yarım okunur).
         */
        internal fun partlyVisible(reading: String, shown: String): Boolean {
            if (reading.isEmpty() || shown.isEmpty()) return false
            if (matches(reading, shown) || isPartOf(reading, shown)) return true
            val have = words(reading)
            return words(shown).any { word -> word.count { it.isLetter() } >= VISIBLE_WORD_LENGTH && have.any { matches(it, word) } }
        }

        /**
         * Kararsız okuma kaldırmaya yetecek kadar sürdü mü: en az [UNSTEADY_TURNS] tur ve [UNSTEADY_MS]; alanın kaldırılan
         * yazısı daha önce geri geldiyse ikisi de (1 + [patience]) katı.
         */
        internal fun unsteadyLong(turns: Int, elapsedMs: Long, patience: Int): Boolean {
            val scale = 1 + patience.coerceIn(0, MAX_PATIENCE)
            return turns >= UNSTEADY_TURNS * scale && elapsedMs >= UNSTEADY_MS * scale
        }

        /**
         * Çevirinin gönderildiği turdaki alan izi ([trace]) bu turdakine benzemiyor: özgün yazı yerinde değil
         * ([ScreenPresence.GONE_CORRELATION]; izlerden biri düzse de yok sayılır).
         */
        internal fun traceGone(trace: ByteArray?, signature: ByteArray): Boolean {
            if (trace == null) return true
            val score = ScreenPresence.correlation(trace.map { it.toInt() and 0xFF }, signature.map { it.toInt() and 0xFF })
                ?: return true
            return score < ScreenPresence.GONE_CORRELATION
        }

        /** Alanın izindeki örneklerin bu kadarı bir turda değiştiyse görüntü bütünüyle değişmiştir: beklemeden kaldırılır. */
        internal const val BIG_CHANGE_SHARE = 0.5

        /** Önceden çevirinin turun iş parçacığında sürdüğü varsayılan (testler): çeviri yine süre sınırıyla beklenir. */
        private val INLINE = Executor { it.run() }

        /**
         * Çevirinin çalıştığı iş parçacıkları: tur çeviriyi en çok [translationTimeoutMs] bekler. Kesilmeyi dinlemeyen çevirmen
         * asılı kalsa da tur biter, sonraki tur başlayabilir.
         */
        private val deadlineWork = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "CouchSubs region translate").apply { isDaemon = true }
        }

        /** Çevirisi saklanan en çok yazı sayısı (oyun görev yazısını arada silip yeniden gösteriyor). */
        private const val TRANSLATION_LIMIT = 64

        /**
         * Sadeleştirilmiş yazı; tuş simgeleri [ButtonIcons.MARKER] olarak kalır. Simgesi sonradan bulunan okuma
         * ("SET DESTINATION ✕") eskisinden ayrılsın.
         */
        internal fun textKey(paragraphs: List<String>): String =
            paragraphs.joinToString(" ").split(ButtonIcons.MARKER)
                .map { TextMatch.normalize(it) }
                .flatMapIndexed { index, part -> if (index == 0) listOf(part) else listOf(ButtonIcons.MARKER.toString(), part) }
                .filter { it.isNotEmpty() }
                .joinToString(" ")

        private fun matches(a: String, b: String) = a == b || TextMatch.isSimilar(a, b, 0.75)

        private fun words(text: String): List<String> =
            text.split(' ').filter { token -> token.isNotEmpty() && token.any { it.isLetterOrDigit() } }

        /** Okuma ekrandakinin eksik hâli mi: sözcükleri (biri tanınmayabilir) ekrandakinde sırasıyla geçiyor. */
        internal fun isPartOf(reading: String, shown: String): Boolean {
            val part = reading.split(' ').filter { it.isNotEmpty() }
            val whole = shown.split(' ').filter { it.isNotEmpty() }
            if (part.isEmpty() || part.size >= whole.size) return false
            var at = 0
            var misses = 0
            for (word in part) {
                val found = (at until whole.size).firstOrNull { matches(whole[it], word) }
                if (found == null) {
                    if (++misses > 1) return false
                    continue
                }
                at = found + 1
            }
            return at > 0
        }

        /**
         * Okumanın bütün sözcükleri ekrandakinde geçiyor ama ekrandakinin bir sözcüğü kayıp (simge onun yerine okunmuş).
         */
        internal fun losesWords(reading: String, shown: String): Boolean {
            val have = words(reading)
            val whole = words(shown)
            return have.isNotEmpty() && whole.any { word -> have.none { matches(it, word) } } &&
                have.all { word -> whole.any { matches(it, word) } }
        }

        private fun iconCount(candidate: Candidate): Int =
            candidate.paragraphs.sumOf { paragraph -> paragraph.count { it == ButtonIcons.MARKER } }

        /**
         * Otomatik alandaki yazının türü: haritanın görev kartı (menüde de) görevdir; yoksa alanın yerinden (hazır alan,
         * görev satırı, menü) ya da okunan yazıdan çıkar. Kullanıcının kendi alanı null (her zaman çevrilir).
         */
        /**
         * Okunan yazı arayüz etiketi mi: bütün parçaları arayüz sözlüğünde ([UiCommands]) ya da parçalarından birinde
         * kareden kesilmiş tuş simgesi var (ipucu: "EXIT ○"). Mac RegionWatcher.isUiLabel ile aynı.
         */
        internal fun isUiLabel(candidate: Candidate): Boolean {
            if (candidate.icons?.any { it.isNotEmpty() } == true) return true
            if (candidate.paragraphs.isEmpty()) return false
            return candidate.paragraphs.all { UiCommands.translateLabelLoosely(IconText.plain(it)) != null }
        }

        fun kind(area: ExtraArea, candidate: Candidate): ScreenTextKind? {
            if (area.auto && candidate.missionCard) return ScreenTextKind.MISSION
            ScreenTextKind.of(area)?.let { return it }
            return if (area.auto) ScreenTextKind.ofParagraphs(candidate.paragraphs) else null
        }

        /**
         * Okumadan çevrilecek parçalar, kutusu (kareye oranla) ve satır yüksekliği. Yazının içindeki kumanda simgeleri
         * [frame]'den (okunan alan) kesilir; çeviride yerleri korunur.
         */
        /**
         * [styled]: otomatik alan ya da oyunun hazır alanı ([GameAreaPresets]): saat ve sayaç ("12:00 pm") çevrilmez.
         * Önceden hazır alanın çevirisi tek siyah kutuda görev resminin de üstünü örtüyordu (#856).
         */
        fun candidate(
            reading: Reading, region: CropRegion, frame: GrayFrame? = null, keepPrompts: Boolean = false, auto: Boolean = false,
            styled: Boolean = false, color: ((Int, Int) -> Int)? = null,
        ): Candidate {
            // Fiilsiz yerlerdeki simgeler (tuş çubuğu, satır ucu) karede doğrulanır; otomatik alanda yalnız renksiz simgeler
            // ([color]), satır ucundaki simge çeviriye girmez (Mac ve Windows ile aynı).
            val marked = if (frame == null) reading.withButtonIcons() else reading.withButtonIcons(frame, color, monochrome = auto)
            val stylish = auto || styled
            // Menü şeridinin sekmeleri tek satır okunsa da ayrı satırlardır (#859); kutular alana oranlı.
            val aspect = (region.right - region.left) * 16 / maxOf(1e-6, (region.bottom - region.top) * 9)
            // Menüdeki tuş etiketleri ("HOLSTER (L1)", "SELECT ✕") menü durumunda çevrilir; başka yerde kısa ipucu atılır.
            // Aynı yazının iki okunuşu tek satır kalır; satırın başındaki/sonundaki simge kutunun dışında kalır (#827;
            // "Ekranı çevir" ile aynı). Kenardaki kumanda simgesi ("RECENTER L3") çeviriye girmez, görünür kalır (#860).
            val lines = ScreenTranslation.withoutDuplicateLines((if (keepPrompts) marked else marked.withoutButtonPrompts()).withoutOcrNoise().lines
                .flatMap { ScreenTranslation.menuPieces(it, aspect, frame) }
                .map(ScreenTranslation::withoutEdgeMarks)
                .map(ScreenTranslation::withoutEdgeIcons)
                .filter { ScreenText.isWords(it.text) }
                .filter { !stylish || !ScreenTranslation.isClock(it.text) }
                .sortedBy { it.box?.top ?: 0.0 })
            var paragraphs = ScreenText.paragraphs(lines)
            val boxes = lines.mapNotNull { it.box }
            val box = boxes.reduceOrNull { a, b -> a.union(b) }?.placedIn(region.box)
            val height = region.bottom - region.top
            val heights = boxes.map { (it.bottom - it.top) * height }.sorted()
            val lineHeight = if (heights.isEmpty()) null else heights[heights.size / 2]
            var icons = ScreenText.paragraphIcons(lines)
            var key = textKey(paragraphs)
            // Alanda birbirinden ayrı duran yazılar (başlık ile ayrı sütundaki hedef, alt alta iki bildirim) "Ekranı
            // çevir"deki gibi gruplanır; her grubun çevirisi TV'de kendi yerine konur. Tek grupta (ya da yeri bilinmeyen
            // satır varsa) eskisi gibi tek kutu. Anahtar grup yapısını da içerir: aynı yazı farklı gruplanırsa bloklar
            // yeniden kurulur.
            var blocks: List<Block>? = null
            // Haritanın görev kartı her alanda kendi parçalarına ayrılır (başlık, alt başlık, açıklama, ayrıntı;
            // [MissionCard]); kalan satırlar her zamanki gibi. Hazır ya da kullanıcının alanında da başlık açıklamaya
            // katılıp ikisi tek kutuda, görev resminin üstünde çiziliyordu (#856).
            val cards = if (lines.isNotEmpty() && boxes.size == lines.size) MissionCard.find(lines, region.box) else emptyList()
            val groups = when {
                // Otomatik ve hazır alan: kısa etiketler kendi bloğu, uzun yazı paragraf ([autoGroups]; Mac ve Windows gibi).
                stylish && lines.isNotEmpty() && boxes.size == lines.size -> autoGroups(lines, keepPrompts, cards)
                cards.isNotEmpty() -> {
                    val taken = cards.flatMap { it.all }.toSet()
                    val rest = lines.indices.filter { it !in taken }.map { lines[it] }
                    (ScreenTranslation.groupLines(rest) + cards.flatMap { MissionCard.groups(it, lines) }).sortedBy { it.box.top }
                }
                lines.size > 1 && boxes.size == lines.size -> ScreenTranslation.groupLines(lines)
                else -> emptyList()
            }
            if ((stylish && groups.isNotEmpty()) || (groups.size > 1 && groups.size < ScreenTranslation.MAX_GROUPS)) {
                paragraphs = groups.flatMap { it.paragraphs }
                icons = groups.flatMap { group -> group.icons ?: group.paragraphs.map { emptyList<IconSlot>() } }
                var start = 0
                // Haritanın görev kartının parçası olan grup: çizim kipi seçiminde görev/hedef ([paintKind]).
                fun onCard(group: ScreenTranslation.Group) = cards.any { card ->
                    card.all.any { i ->
                        val b = lines[i].box!!
                        val x = (b.left + b.right) / 2
                        val y = (b.top + b.bottom) / 2
                        x >= group.box.left - 1e-6 && x <= group.box.right + 1e-6 && y >= group.box.top - 1e-6 && y <= group.box.bottom + 1e-6
                    }
                }
                val list = groups.map { group ->
                    Block(start, group.paragraphs.size, group.box.placedIn(region.box), group.lineHeight * height, group.rows,
                        card = onCard(group))
                        .also { start += group.paragraphs.size }
                }
                blocks = list
                key = textKey(paragraphs) + "|" + list.joinToString(",") { it.count.toString() }
            }
            val cut = if (frame == null || icons.all { it.isEmpty() }) null else icons.map { ButtonIcons.withImages(it, frame) }
            val missionCard = cards.any { card ->
                !MissionCard.inHelpCorner(card.all.map { lines[it].box!! }.reduce { a, b -> a.union(b) }.placedIn(region.box))
            }
            return Candidate(paragraphs, box, lineHeight, key, cut, blocks, textKey(paragraphs), missionCard = missionCard)
        }

        /** Kısa etiket satırı: en çok bu kadar sözcük. */
        private const val LABEL_WORDS = 5

        /**
         * Otomatik ve hazır alanın grupları (Mac RegionWatcher.autoGroups, Windows AutoGroups ile aynı): gruplar önce
         * birlikte kurulur; bütün satırları kısa etiket olan grup (menü sütunu, tuş etiketleri) satır satır bloktur, uzun
         * satırı olan grup paragraftır, başındaki BÜYÜK HARF başlık ise kendi bloğudur. Önceden hazır alanda alt alta tuş
         * etiketleri ("RECENTER", "2D VIEW") tek kutuda tek cümle gibi çevriliyordu. [menu] dışında satır yükseklikleri
         * ±%15'ten çok farklı paragraf (eğik ya da ölçekli dünya yazısı: poster, tabela) çevrilmez.
         */
        internal fun autoGroups(lines: List<TextLine>, menu: Boolean = false, cards: List<MissionCard.Card> = emptyList()): List<ScreenTranslation.Group> {
            fun isLabel(line: TextLine) = line.text.split(Regex("\\s+")).count { it.isNotEmpty() } <= LABEL_WORDS
            fun isTitle(line: TextLine) = line.text.any { it.isLetter() } && line.text.none { it.isLowerCase() }
            fun inside(line: TextBox, group: TextBox): Boolean {
                val x = (line.left + line.right) / 2
                val y = (line.top + line.bottom) / 2
                return x >= group.left - 1e-6 && x <= group.right + 1e-6 && y >= group.top - 1e-6 && y <= group.bottom + 1e-6
            }
            fun single(line: TextLine): ScreenTranslation.Group {
                val icons = ScreenText.paragraphIcons(listOf(line))
                val box = line.box!!
                return ScreenTranslation.Group(ScreenText.paragraphs(listOf(line)), box, box.bottom - box.top,
                    if (icons.any { it.isNotEmpty() }) icons else null)
            }
            val groups = cards.flatMap { MissionCard.groups(it, lines) }.toMutableList()
            val taken = cards.flatMap { it.all }.toSet()
            val rest = lines.indices.filter { it !in taken }.map { lines[it] }
            for (group in ScreenTranslation.groupLines(rest)) {
                val own = rest.filter { inside(it.box!!, group.box) }
                if (own.all(::isLabel)) {
                    groups += own.map(::single)
                    continue
                }
                val heights = own.filter { !isLabel(it) }.map { it.box!!.bottom - it.box!!.top }
                if (!menu && heights.size >= 2 && heights.max() > heights.min() * (1.15 / 0.85)) continue
                val titles = own.takeWhile { isTitle(it) && isLabel(it) }
                groups += titles.map(::single)
                if (titles.isEmpty()) groups += group else groups += ScreenTranslation.groupLines(own.drop(titles.size))
            }
            return groups.withIndex().sortedWith(compareBy({ it.value.box.top }, { it.value.box.left }, { it.index })).map { it.value }
        }

        /**
         * Her grubun çevirisi kendi yeriyle. Çevirisi aslıyla aynı grup (ad, sayı) atlanır; İngilizcesi görünür kalır.
         * [text] simge imlerini bütün alanın sırasıyla taşır; [slots] o sıradaki simgeler.
         */
        /**
         * Otomatik ekran yazısı: her blok (tek grupta bütün yazı tek blok) için özgün görünüş [frame]'den (okunan alan)
         * çıkarılır; çeviri aynı yerde, aynı renk ve biçimde gösterilir.
         */
        internal fun styled(
            candidate: Candidate, reading: Reading, region: CropRegion, frame: GrayFrame?, color: ((Int, Int) -> Int)? = null,
            modes: Boolean = false, kind: ScreenTextKind? = null,
            screen: GrayFrame? = null, screenColor: ((Int, Int) -> Int)? = null,
        ): Candidate {
            if (frame == null) return candidate
            val groups = candidate.blocks ?: run {
                val box = candidate.box ?: return candidate
                val line = candidate.lineHeight ?: return candidate
                listOf(Block(0, candidate.paragraphs.size, box, line))
            }
            val width = region.right - region.left
            val height = region.bottom - region.top
            if (width <= 0 || height <= 0) return candidate
            val lines = reading.lines.mapNotNull { line -> line.box?.placedIn(region.box) }.sortedBy { it.top }
            fun inside(line: TextBox, box: TextBox) =
                (line.top + line.bottom) / 2 in box.top..box.bottom && (line.left + line.right) / 2 in box.left..box.right
            val blocks = mutableListOf<Block>()
            val aligns = mutableListOf<String?>()
            for (group in groups) {
                val own = lines.filter { inside(it, group.box) }
                // Hizalama grubun satırlarından (sağa yaslı kontrol etiketleri, ortalı başlık).
                val align = if (own.size >= 2) TextStyleSampler.align(own.map { it.left to it.right })
                    else own.singleOrNull()?.let { columnAlign(it, lines) ?: ScreenFit.loneAlign(it, 1) }
                val parts = if (group.count > 1) paragraphLines(candidate.paragraphs.subList(group.start, group.start + group.count),
                    lines.filter { inside(it, group.box) }.let { boxes -> reading.lines.filter { it.box != null }
                        .map { it.text to it.box!!.placedIn(region.box) }.filter { (_, box) -> box in boxes }.sortedBy { it.second.top } }) else null
                if (parts != null) {
                    // Her parça (başlık, gövde; menü listesinde her satır) kendi bloğu: stil parça başına çıkarılır (seçili
                    // satır ters renkli, başlık kalın), çeviri parçanın kendi yerine konur.
                    parts.forEachIndexed { i, boxes ->
                        val box = boxes.reduce { a, b -> a.union(b) }
                        val heights = boxes.map { it.bottom - it.top }.sorted()
                        blocks.add(Block(group.start + i, 1, box, heights[heights.size / 2], boxes.size, card = group.card))
                        aligns.add(align)
                    }
                } else {
                    blocks.add(group)
                    aligns.add(align)
                }
            }
            val styles = blocks.mapIndexed { index, block ->
                val box = block.box
                val source = (block.start until block.start + block.count).joinToString("\n") { IconText.plain(candidate.paragraphs[it]) }
                val edges = lines.filter { inside(it, box) }.map { it.left to it.right }
                TextStyleSampler.sample(
                    frame,
                    ((box.left - region.left) / width * frame.width).toInt(), ((box.top - region.top) / height * frame.height).toInt(),
                    kotlin.math.ceil((box.right - region.left) / width * frame.width).toInt(),
                    kotlin.math.ceil((box.bottom - region.top) / height * frame.height).toInt(),
                    block.lineHeight / height * frame.height, source, edges, color,
                )?.let { style -> aligns[index]?.let { style.copy(look = style.look.copy(align = it)) } ?: style }
            }
            // Yerinde birebir çizim: örtü kutusu, zemin/degrade, satır aralığı, boş alan ve grup bütün karede ölçülür
            // ([screen]; yoksa okunan alanın karesinde, alan koordinatında, sonra karedeki yere taşınır). Okuma turunda bir
            // kez (her karede değil). Okunan alan yazının karolarından yalnız bir karo geniştir: yanına yazmanın boş alanı
            // alanın kenarında bitiyordu; GTA 6 duraklatma menüsünde en uzun satır ("Photo Studio") sağa sığmayıp örtülüyor,
            // ayrı alana düşen "Settings" altına yazılıyordu (#1339). Ortak deneme kareleri de bütün karede ölçer. Mac
            // RegionWatcher ve Windows ile aynı.
            val whole = screen?.takeIf { it.isValid }
            val painted = blocks.indices.filter { styles[it] != null }
            val targets = painted.map { i ->
                val block = blocks[i]
                val style = styles[i]!!
                val box = block.box
                TextPainter.Target(
                    if (whole != null) box else TextBox((box.left - region.left) / width, (box.top - region.top) / height,
                        (box.right - region.left) / width, (box.bottom - region.top) / height),
                    if (whole != null) block.lineHeight else block.lineHeight / height,
                    if (block.count > 1) maxOf(2, block.rows) else block.rows,
                    style.surface.background, style.surface.foreground, style.look.upper, style.look.align,
                    TextPainter.words((block.start until block.start + block.count).joinToString(" ") { candidate.paragraphs[it] }),
                    if (modes) paintKind(candidate.paragraphs.subList(block.start, block.start + block.count), block.card, kind) else null,
                    (block.start until block.start + block.count).joinToString(" ") { candidate.paragraphs[it] }.let {
                        it.contains(ButtonIcons.MARKER) || ButtonPrompts.isPrompt(IconText.plain(it))
                    })
            }
            val measured = whole ?: frame
            val measuredColor = if (whole != null) screenColor else color
            val paints = (if (targets.isEmpty()) emptyList() else TextPainter.paints(targets, measured, measuredColor)).map { paint ->
                // Kişi resmi (ikiz panelde gösterilir) ölçülen kareden, karedeki yere taşınmadan önce kesilir.
                val face = paint.portrait ?: return@map paint
                paint.copy(portraitImage = TextPainter.portraitImage(face, measured.width, measured.height,
                    measuredColor ?: { x, y -> measured.at(x, y).let { (it shl 16) or (it shl 8) or it } }))
            }
            val aligned = styles.toMutableList()
            for ((k, i) in painted.withIndex()) {
                if (k >= paints.size) continue
                blocks[i] = blocks[i].copy(paint = if (whole != null) paints[k] else paints[k].placedIn(region.box))
                // Kutunun ucunda simge varsa yazı simgeye yaslanır (#1266: "SEÇ" tuş simgesinin yanında).
                val side = paints[k].iconSide
                val style = aligned[i]
                if (side != null && style != null) aligned[i] = style.copy(look = style.look.copy(align = side))
            }
            // Görev/hedef satırı altyazıdan ve öbür ekran yazılarından ayrı görünür: koyu kehribar kutu, başında hedef imi
            // ([MissionLine.STYLE], [MissionLine.MARKER]). Yerinde birebir çizim (örtü/yanına yazma) uygulanmaz; kutu görevin
            // kendi yerindedir (#1273). TV ve dört platformun önizlemesi bunu öğenin zemininden çizer (Mac/Windows aynı).
            if (kind == ScreenTextKind.MISSION) {
                for (i in blocks.indices) blocks[i] = blocks[i].copy(paint = null, mission = true)
                for (i in aligned.indices) aligned[i] = aligned[i]?.let { it.copy(surface = MissionLine.STYLE) }
            }
            return candidate.copy(blocks = blocks, styles = aligned)
        }

        /**
         * Otomatik alandaki grubun çizim kipini seçen türü ([TextPainter.Target.kind]): alanın yerinden belli türü (menü,
         * telefon, yardım köşesi, görev satırı), haritanın görev kartının parçası görev/hedef, kalanı okunan yazıdan
         * ([ScreenTextKind.ofParagraphs]). Mac/iPhone (RegionWatcher.paintKind) ve Windows aynı.
         */
        internal fun paintKind(paragraphs: List<String>, card: Boolean, area: ScreenTextKind?): ScreenTextKind =
            area ?: if (card) ScreenTextKind.MISSION else ScreenTextKind.ofParagraphs(paragraphs)

        /**
         * Parçaların satırları: satırlar yukarıdan aşağı sözcük sayısıyla parçalara dağıtılır (ScreenText.paragraphs
         * satırları birleştirir). Dağıtım tutmazsa null.
         */
        private fun paragraphLines(paragraphs: List<String>, lines: List<Pair<String, TextBox>>): List<List<TextBox>>? {
            fun words(text: String) = text.split(' ').count { it.isNotBlank() }
            val result = mutableListOf<List<TextBox>>()
            var at = 0
            for (paragraph in paragraphs) {
                val need = words(IconText.plain(paragraph))
                var have = 0
                val boxes = mutableListOf<TextBox>()
                while (at < lines.size && have < need) {
                    have += words(lines[at].first)
                    boxes.add(lines[at].second)
                    at++
                }
                if (boxes.isEmpty()) return null
                result.add(boxes)
            }
            return if (at == lines.size) result else null
        }

        /**
         * Tek satırlık etiketin hizası, aynı sütundaki komşularından: sağ kenarları aynı olan etiketler sağa yaslıdır
         * (kontrol şemasında kol resminin solu), sol kenarları aynı olanlar sola, ortaları aynı olanlar ortalıdır.
         */
        private fun columnAlign(line: TextBox, lines: List<TextBox>): String? {
            val tolerance = 0.005
            val others = lines.filter { it != line }
            fun count(edge: (TextBox) -> Double) = others.count { abs(edge(it) - edge(line)) <= tolerance }
            val lefts = count { it.left }
            val rights = count { it.right }
            val centers = count { (it.left + it.right) / 2 }
            return when {
                lefts == 0 && rights == 0 && centers == 0 -> null
                rights > lefts && rights >= centers -> "right"
                centers > lefts -> "center"
                else -> "left"
            }
        }

        /**
         * Seçim kaydı (#1267): gösterilen bir kutunun (yeri, zemini) yerindeki (satırının en az yarısı örtüşen) yeni bloğun
         * zemini öbür tonda (biri açık, öbürü koyu: seçili menü satırının ters rengi). Mac ve Windows aynı kuralı uygular.
         */
        internal fun selectionMoved(rendered: List<Pair<TextBox, String>>, current: List<Pair<TextBox, String>>): Boolean {
            fun light(hex: String): Boolean {
                val c = TextPainter.rgb(hex)
                return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 127.5
            }
            return rendered.any { (a, before) ->
                current.any { (b, now) ->
                    if (light(now) == light(before)) return@any false
                    val rows = maxOf(0.0, minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)) /
                        maxOf(1e-9, minOf(a.bottom - a.top, b.bottom - b.top))
                    rows >= 0.5 && minOf(a.right, b.right) > maxOf(a.left, b.left)
                }
            }
        }

        /**
         * Liste kaydı (Sinan Bey beta.100 3381, 3383): gösterilen bir kutunun yazısı yeni okumada satır yüksekliğinin en az
         * yarısı kadar başka yerde, ya da kutunun yerinde (satırının en az yarısı örtüşen) başka bir yazı var. Okuma
         * oynamaları (benzer okuma, eksik okuma) aynı yazı sayılır. Mac/iPhone ve Windows aynı kuralı uygular.
         */
        internal fun listMoved(rendered: List<ScreenTranslation.Item>, current: List<Pair<TextBox, String>>): Boolean {
            fun same(a: String, b: String): Boolean {
                val x = IconText.plain(a).replace('\n', ' ')
                val y = IconText.plain(b).replace('\n', ' ')
                return matches(textKey(listOf(x)), textKey(listOf(y))) || isPartOf(x, y) || isPartOf(y, x)
            }
            fun rows(a: TextBox, b: TextBox) =
                maxOf(0.0, minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)) / maxOf(1e-9, minOf(a.bottom - a.top, b.bottom - b.top))
            return rendered.any { item ->
                val source = item.source
                if (source.none { it.isLetter() }) return@any false
                val height = item.box.bottom - item.box.top
                val found = current.filter {
                    same(it.second, source) && minOf(it.first.right, item.box.right) > maxOf(it.first.left, item.box.left)
                }
                val nearest = found.minByOrNull { kotlin.math.abs(it.first.top - item.box.top) }
                if (nearest != null) {
                    val line = minOf(height, nearest.first.bottom - nearest.first.top) / maxOf(1, item.rows)
                    return@any kotlin.math.abs(nearest.first.top - item.box.top) >= 0.5 * line
                }
                current.any { (box, text) ->
                    rows(box, item.box) >= 0.5 && minOf(box.right, item.box.right) > maxOf(box.left, item.box.left) &&
                        !same(text, source)
                }
            }
        }

        /** Adayın blokları: karedeki yeri ve yazısı (bloğun parçaları birleşik). */
        internal fun blockTexts(candidate: Candidate): List<Pair<TextBox, String>> =
            candidate.blocks.orEmpty().map { block ->
                val end = minOf(candidate.paragraphs.size, block.start + block.count)
                block.box to (if (block.start < end) candidate.paragraphs.subList(block.start, end).joinToString(" ") else "")
            }

        /** [cutAtAreaEdge] payı (karo genişliği cinsinden). */
        const val AREA_EDGE_TILES = 0.25

        /**
         * Menüdeki otomatik alanın sol ya da sağ kenarına (karenin kenarı değilse) [AREA_EDGE_TILES] karodan yakın değen
         * satır alanın dışına taşıyor: uzun satırın bir parçasıdır. Sinan Bey beta.100 (3381-3383): yarım okunan satırın
         * kalan parçası ayrı blok sanılıp yanına küçük kutuyla çevriliyordu ("Delik", "bunun bedelini ödemek!"). Kesik
         * satır çevrilmez; bütün okunduğu alanda çevrilir (Mac/iPhone, Windows ile aynı).
         */
        internal fun cutAtAreaEdge(line: TextLine, region: CropRegion): Boolean {
            val box = line.box ?: return false
            val width = region.right - region.left
            if (width <= 0) return false
            val margin = AREA_EDGE_TILES / ScreenTextDetector.COLUMNS / width
            return (region.left > 0.001 && box.left <= margin) || (region.right < 0.999 && box.right >= 1 - margin)
        }

        /** [joinedPieces]: parçalar arası boşluk (satır yüksekliğine oranla); satır içi simge ve iki yanındaki boşluklar sığar. */
        const val PIECE_GAP = 2.5

        /**
         * Aynı satırda yan yana okunan parçalar (dikeyde küçüğün %60'ı örtüşür, yazı boyları 1,3 kattan az farklı, aradaki
         * boşluk satır yüksekliğinin en çok [PIECE_GAP] katı) soldan sağa tek satır olur; en az birinde küçük harf olmalı
         * (BÜYÜK HARFLİ sekmeler ve tuş etiketleri ayrı kalır). Yazı tanıma uzun satırı satır içi simgeden ya da renkli konuşan
         * adından bölüyor, parçalar ayrı blok olup ayrı ayrı çevriliyordu (Sinan Bey beta.100 3380). [aspect]: alanın
         * genişlik/yükseklik oranı (Mac/iPhone, Windows ile aynı).
         */
        internal fun joinedPieces(lines: List<TextLine>, aspect: Double): List<TextLine> {
            if (lines.size < 2 || lines.any { it.box == null }) return lines
            val rows = mutableListOf<TextLine>()
            for (line in lines.sortedBy { it.box!!.left }) {
                val box = line.box!!
                val index = rows.indexOfFirst { pieceOf(box, line.text, it, aspect) }
                if (index < 0) {
                    rows.add(line)
                    continue
                }
                val row = rows[index]
                val words = if (row.words != null && line.words != null) row.words + line.words else null
                val icons = (row.icons.orEmpty() + line.icons.orEmpty()).ifEmpty { null }
                val confidence = listOfNotNull(row.confidence, line.confidence).minOrNull()
                rows[index] = row.copy(text = row.text + " " + line.text, box = row.box!!.union(box), words = words, icons = icons,
                    confidence = confidence)
            }
            return if (rows.size == lines.size) lines else rows.sortedWith(compareBy({ it.box!!.top }, { it.box!!.left }))
        }

        private fun pieceOf(next: TextBox, text: String, row: TextLine, aspect: Double): Boolean {
            val box = row.box!!
            val a = next.bottom - next.top
            val b = box.bottom - box.top
            if (minOf(a, b) <= 0 || maxOf(a, b) > 1.3 * minOf(a, b)) return false
            if (minOf(next.bottom, box.bottom) - maxOf(next.top, box.top) < 0.6 * minOf(a, b)) return false
            if (text.none { it.isLowerCase() } && row.text.none { it.isLowerCase() }) return false
            val gap = (next.left - box.right) * aspect
            return gap >= -0.5 * maxOf(a, b) && gap <= PIECE_GAP * maxOf(a, b)
        }

        /**
         * Etiketin başında çevrilmeyecek kısım (ardındaki boşluk dahil): konuşan adı ("Staff Member: ", ardı cümleyse) ya
         * da BÜYÜK HARFLİ yazıda yalnız özel adlardan oluşan baş ("JASON & LUCIA " + "MAP"; [ScreenTranslation.keepsNames]).
         * Ardında harfli yazı kalmalı. Ayar satırı ("Subtitles: On") bütün çevrilir (Mac/iPhone, Windows ile aynı).
         */
        internal fun keptHead(text: String): String? {
            SpeakerPrefix.split(text)?.let { speaker ->
                val sentence = SubtitleStabilizer.endsSentence(speaker.body) ||
                    speaker.body.split(' ', '\t').filter { it.isNotEmpty() }.size >= 3
                val at = text.lastIndexOf(speaker.body)
                if (sentence && at > 0 && text.substring(at + speaker.body.length).isBlank()) return text.substring(0, at)
            }
            if (!text.contains(" & ") || !TextStyleSampler.isUpper(text)) return null
            val words = text.split(" ")
            if (words.size < 4) return null
            for (end in words.size - 1 downTo 3) {
                val head = words.subList(0, end).joinToString(" ")
                val tail = words.subList(end, words.size).joinToString(" ")
                if (tail.any { it.isLetter() } && ScreenTranslation.keepsNames(head)) return "$head "
            }
            return null
        }

        /** Gösterilen ya da okunan blokların yeri ve zemini ([selectionMoved] için). */
        private fun grounds(blocks: List<Block>?, styles: List<TextStyleSampler.Style?>?): List<Pair<TextBox, String>> =
            blocks.orEmpty().mapIndexedNotNull { i, block -> styles?.getOrNull(i)?.let { block.box to it.surface.background } }

        internal fun renderBlocks(
            candidate: Candidate, layout: List<Block>, text: List<String>, similar: List<Boolean>, slots: List<IconSlot>,
        ): List<Pair<Int, ScreenTranslation.Item>> = layout.mapIndexedNotNull { index, block ->
            val range = block.start until block.start + block.count
            // İkiz panelde çevrilmeyen yazı (kişi adı) da özgün hâliyle yazılır: ikiz özgünün eksiksiz kopyası olsun.
            if (range.all { similar[it] } && block.paint?.mode != TextPaint.MODE_TWIN) return@mapIndexedNotNull null
            val joined = range.joinToString("\n") { text[it] }
            val rendered = IconText.render(if (block.mission) MissionLine.MARKER + joined else joined, slots)
            val source = range.joinToString("\n") { IconText.plain(candidate.paragraphs[it]) }
            val style = candidate.styles?.getOrNull(index)
            // Özgün yazı BÜYÜK HARFse çeviri de (Türkçe kurallarıyla); simge yerleri değişmez.
            val translation = if (style?.look?.upper == true) TextStyleSampler.upper(rendered.text) else rendered.text
            index to ScreenTranslation.Item(source, translation, block.box, block.lineHeight, rendered.icons.takeIf { it.isNotEmpty() },
                style?.surface, style?.look, rows = maxOf(1, block.rows), paint = block.paint)
        }

        /**
         * Menüdeki otomatik alanla kesişen hazır alan o turda okunmaz: haritanın tuş listesi iki alana bölünüp bölünme
         * yerindeki satır ("ADD MARKER") çevrilmiyordu (beta.100; Mac/Windows ile aynı).
         */
        internal fun yieldingPresets(areas: List<ExtraArea>): List<ExtraArea> {
            val menus = areas.filter { it.auto && it.menu }.map { it.region }
            if (menus.isEmpty()) return areas
            return areas.filter { area ->
                !GameAreaPresets.isPreset(area.id) || menus.none { m ->
                    minOf(area.region.right, m.right) > maxOf(area.region.left, m.left) &&
                        minOf(area.region.bottom, m.bottom) > maxOf(area.region.top, m.top)
                }
            }
        }
    }

    /** Bir alanın karesi: okunacak gri görüntü ve izi; [frame] kumanda simgelerinin kesileceği aynı görüntü. */
    class Crop(
        val pixels: Any, val signature: ByteArray, val frame: GrayFrame? = null,
        /** Okunan alanın (x, y) noktasının rengi (0xRRGGBB); kare renk taşımıyorsa null (stil gri tonda). */
        val color: ((Int, Int) -> Int)? = null,
        /** Bütün kare ve rengi: çizim kipi ve yanına yazmanın boş alanı onda ölçülür (#1339); null: okunan alanda. */
        val screen: GrayFrame? = null,
        val screenColor: ((Int, Int) -> Int)? = null,
    )

    /**
     * Alanda ayrı duran bir yazı grubu: [Candidate.paragraphs] içinde [start]'tan başlayan [count] parça, karedeki yeri ve
     * satır yüksekliği (kareye oranla).
     */
    data class Block(
        val start: Int, val count: Int, val box: TextBox, val lineHeight: Double,
        /** Özgün yazının satır sayısı ([ScreenTranslation.Group.rows]); TV çeviriyi bu satır aralığıyla dizer. */
        val rows: Int = 1,
        /** Yerinde birebir çizim ölçüleri ([TextPainter]), karedeki yeriyle; otomatik ekran yazısında. */
        val paint: TextPaint? = null,
        /** Haritanın görev kartının parçası ([MissionCard]): çizim kipi hep örtme. */
        val card: Boolean = false,
        /**
         * Görev/hedef satırının bloğu ([MissionLine.AREA_ID]): çevirisi altyazıdan ayrı görünüşte ([MissionLine.STYLE],
         * başında [MissionLine.MARKER]).
         */
        val mission: Boolean = false,
    )

    /**
     * [icons]: her parçadaki kumanda simgeleri (kareden kesilmiş), parçadaki sırasıyla. [blocks]: alanda birden çok ayrı
     * yazı grubu varsa grupları; tek grupta null (tek kutu). [text]: yazının sadeleştirilmiş hâli (simgeler dahil,
     * yerleşim hariç; [textKey]); okumaları karşılaştırmak için.
     */
    data class Candidate(
        val paragraphs: List<String>, val box: TextBox?, val lineHeight: Double?, val key: String,
        val icons: List<List<IconSlot>>? = null, val blocks: List<Block>? = null, val text: String = "",
        /** Otomatik ekran yazısında her bloğun özgün görünüşü ([styled]); diğer alanlarda null. */
        val styles: List<TextStyleSampler.Style?>? = null,
        /** Otomatik ekran yazısı: kısa etiketler sözlük, oturum terimleri ve toplu istekle çevrilir ([translateAuto]). */
        val auto: Boolean = false,
        /** Otomatik alanda haritanın görev kartı var (yardım köşesinde değil): türü "Görev ve hedef yazısı". */
        val missionCard: Boolean = false,
    )

    private class State {
        var signature: ByteArray? = null
        /** Bir önceki turun izi ([BIG_CHANGE_SHARE] için; [signature] okuma hatasında silinir). */
        var passSignature: ByteArray? = null
        /** Çevirisi gösterilirken art arda kaç turdur okuma değişip doğrulanamadı ([UNSTEADY_TURNS]) ve ilkinin zamanı ([UNSTEADY_MS]). */
        var unsteady = 0
        var unsteadySince: Long? = null
        /** Çevirinin gönderildiği turdaki alan izi: özgün yazının izi ([traceGone]). */
        var shownTrace: ByteArray? = null
        /**
         * Çevirisi gösterilen otomatik alanın son okuması boş ya da gürültüydü (bulucuya bildirilmedi): görüntü değişmeden bir
         * tur daha geçerse bildirilir (Mac/iPhone ve Windows'ta aynı okumanın kararlı sayılıp reddedilmesi).
         */
        var rejectPending = false
        var lastRead: String? = null
        var candidate: Candidate? = null
        var shown = ""
        /** Gösterilen yazının [Candidate.text]'i. */
        var shownText = ""
        /** Gösterilen yazıdaki tuş simgesi sayısı. */
        var shownIcons = 0
        /** Son gösterilen (boş olmayan) yazı; alan boşalınca da hatırlanır (yarım okumayı tanımak için). */
        var remembered = ""
        /** Bekletilen okuma ve kaç turdur bekletildiği ([HOLD_LIMIT]). */
        var held: String? = null
        /** Bekletilen okumanın yazısı (günlük için). */
        var heldText: String? = null
        var holds = 0
        /** Hazır alanda arayüz kutusunun art arda bulunamadığı tur sayısı ([PANEL_MISS_TURNS]). */
        var panelMisses = 0
        var renderedKey: String? = null
        var renderedText: String? = null
        var renderedIcons: List<IconPlacement>? = null
        var renderedBox: TextBox? = null
        var renderedLineHeight: Double? = null
        var renderedLayout: List<Block>? = null
        /** Gönderilen bloklar ve her birinin [Candidate.blocks] içindeki sırası. */
        var renderedBlocks: List<Pair<Int, ScreenTranslation.Item>>? = null
        /** Gönderilen blokların özgün görünüşü; seçim gezince yalnız renkler yeniden gönderilir. */
        var renderedStyles: List<TextStyleSampler.Style?>? = null
    }

    /** Alanın kaldırma geçmişi; alanın durumu silinse de (otomatik alan listeden çıkıp dönünce) kalır. */
    private class Steadiness {
        /** Kaldırma eşiğinin çarpanı eksi bir ([MAX_PATIENCE]); kaldırılan yazı hemen geri geldikçe artar. */
        var patience = 0
        /** Son kaldırılan yazı ve zamanı ([REBOUND_MS]). */
        var clearedText = ""
        var clearedAt: Long? = null
    }

    private val lock = Any()
    private val states = mutableMapOf<String, State>()
    private val steadiness = HashMap<String, Steadiness>()
    private var lastPass: Long? = null
    private var busy = false
    @Volatile private var session = 0

    @Volatile var packLookup: ((String) -> PackMatch?)? = null
    /** Hedef dil Türkçe: yüksek güvenle Türkçe olan parça çevrilmez, aslı sayılır (#289). */
    @Volatile var skipsTurkish = true
    /**
     * Yazı kararlı mı diye bir tur beklenirken çevirisi şimdiden istensin ([prefetchWork]'te): doğrulanınca çoğu zaman
     * hazırdır (gecikme çevirmenin süresi kadar kısalır; yazı belirirken okunan ara hâller de çevrilebildiği için biraz
     * fazla karakter harcar).
     */
    @Volatile var prefetchesTranslations = false

    /** Çeviri bu süreyi aşarsa çevrilemedi sayılır (aday sonraki turda yeniden denenir): asılı istek turu kilitliyordu. */
    @Volatile var translationTimeoutMs = 8000L

    /**
     * Dünya yazısı listesi (yazı anahtarı → ne zamana dek): kamera hareket ederken başka bir yerde ya da boyda yeniden
     * okunan yazı (poster, plaka) oyun dünyasındadır; oturumda 10 dakika bir daha çevrilmez. Son görülen yerler de burada.
     */
    private val worldText = HashMap<String, Long>()
    private val lastPlace = LinkedHashMap<String, TextBox>()

    private fun isWorldText(candidate: Candidate): Boolean = synchronized(worldText) {
        val now = clock()
        val key = candidate.text
        if ((worldText[key] ?: 0L) > now) return true
        val box = candidate.box ?: return false
        val last = lastPlace[key]
        lastPlace[key] = box
        if (lastPlace.size > 256) lastPlace.remove(lastPlace.keys.first())
        if (last == null) return false
        val height = box.bottom - box.top
        val lastHeight = last.bottom - last.top
        val moved = kotlin.math.abs((box.top + box.bottom) / 2 - (last.top + last.bottom) / 2) > lastHeight * 0.5 ||
            kotlin.math.abs((box.left + box.right) / 2 - (last.left + last.right) / 2) > lastHeight
        val scaled = lastHeight > 0 && (height / lastHeight > 1.2 || height / lastHeight < 1 / 1.2)
        if (!moved && !scaled) return false
        worldText[key] = now + WORLD_TEXT_MS
        return true
    }

    /** Altyazı günlüğü (Mac/iPhone `onLog`, Windows `Log`): ek alanda okunup çevrilmeyen yazının nedeni. */
    @Volatile var onLog: ((String) -> Unit)? = null
    /** Düşürülen ya da bekletilen okumanın nedeni, sınırlı ve tekrarsız ([DropLog]). */
    private val drops = DropLog(clock)
    /** Telefonun sessiz yolları ([PhoneTrace]): ayrı sınır, telefon her açılışta yeniden başlamaz. */
    private val phoneTrace = DropLog(clock)

    /** Açık oyun telefonunun oturumu ("GTA 6'daki telefonu otomatik çevir"); telefon kapalıyken null. */
    private var phoneSession: PhoneRegionSession? = null
    /** Telefonun açılışları arasında kalan çeviriler ve panelin yazı boyu ([PhoneMemory]); [reset] unutturur. */
    private val phoneMemory = PhoneMemory()
    /** Telefon mesajları İngilizce: kısaltmalar çevirmene açık yazılır ([GamePhoneText.englishModelInput]). */
    @Volatile var englishPhoneMessages = true
    /** "GTA 6 Telefon Mesajları: Yanda Panel / Balonların Üstünde" ve panelin yazı boyu; her gönderide okunur (Mac ile aynı). */
    @Volatile var phonePanel: () -> PhonePanelOptions = { PhonePanelOptions() }

    /** Telefon açık: izleyicinin telefonu gördüğü son kare. Okuma sonraki [offer] turunda, 450 ms'de bir yapılır. */
    fun observePhone(capture: PhoneCapture) {
        val read = readPhone ?: return
        synchronized(lock) {
            (phoneSession ?: PhoneRegionSession(read, translator, sender, { phonePanel() }, phoneMemory)
                .also {
                    it.onLog = { line -> onLog?.invoke(line) }
                    it.trace = phoneTrace
                    phoneSession = it
                    clearScreenText()
                }).observe(capture)
        }
    }

    /**
     * Telefon açıldı: otomatik ekran yazısının ve kenar bildirimlerinin gösterilen kutuları (görev satırı dışında) aynı
     * karede kalkar. Önceden sonraki turu bekliyordu; telefonun ekranına çizilmiş eski kutu (Sinan Bey, beta.100 3422:
     * önceki haberin "Vali karşılaştırıyor" kutusu hava uygulamasında) bir süre duruyordu. Telefon açıkken bu alanlar
     * zaten önerilmez (Mac/iPhone ve Windows ile aynı).
     */
    fun clearScreenText(): Unit = synchronized(lock) {
        for (id in states.keys.toList()) {
            if (!id.startsWith("auto-") || id == MissionLine.AREA_ID) continue
            if (states[id]!!.shown.isNotEmpty()) sender.sendRegion(id, "", null, null)
            states.remove(id)
        }
    }

    /** Telefon kapandı: kutusu kalkar, bekleyen çevirisi gösterilmez. */
    fun closePhone() {
        val phone = synchronized(lock) { phoneSession.also { phoneSession = null } }
        phone?.close()
    }

    /** Altyazı hattının son satırları ve alanı (bkz. [SubtitleEcho]); uygulama [SubtitleEcho.shared] verir. */
    @Volatile var subtitleEcho: SubtitleEcho? = null

    /** Bu tür ekran yazısı çevrilir mi (Ayarlar'daki türler, [ScreenTextKinds]); varsayılan hepsi. */
    @Volatile var allows: (ScreenTextKind) -> Boolean = { true }

    /** Ayarlar'da kapalı türün alanı (menü, hazır yardım/mesaj alanı, görev satırı) okunmaz; kutusu kalkar. */
    private fun wanted(area: ExtraArea): Boolean = ScreenTextKind.reads(area, allows)


    /** Otomatik alan okundu ama yazı yok ya da gürültü ([ScreenTextNoise]): bulucu o karoları reddeder. */
    @Volatile var onAutoRejected: ((String) -> Unit)? = null
    /**
     * Menü durumundaki otomatik alanın yazısı tuş ipucu ya da görev/HUD yazısı ([ScreenTextKind.isHud]): alanın kimliği.
     * Bulucu bu alanı menü bileşeni saymaz ([ScreenTextDetector.markHud], #1240).
     */
    @Volatile var onAutoHud: ((String) -> Unit)? = null

    /** Bir tur sürüyor mu. */
    val isBusy: Boolean get() = synchronized(lock) { busy }

    /** Tamamlanan tur ve okuma sayısı (testler için). */
    var passes = 0
        private set
    var reads = 0
        private set

    /**
     * Her karede çağrılır: tur zamanı geldiyse ve önceki tur bittiyse alanların kareleri [crop] ile alınır ve tur
     * [run] ile (çağıranın iş parçacığında) başlatılır; true döner. Yoksa hemen false.
     */
    fun offer(offered: List<ExtraArea>, crop: (CropRegion) -> Crop?, run: (Runnable) -> Unit): Boolean {
        val areas = offered.filter(::wanted)
        var manualDue = false
        var phone: PhoneRegionSession? = null
        val started = synchronized(lock) {
            if (busy) return false
            val time = clock()
            // Otomatik ekran yazısı varken yazı ~1 sn içinde görünsün: tur aralığı en çok 500 ms.
            // Altyazı okuması yavaşladıysa ek alanlar seyrek okunur: altyazı her zaman önce.
            val interval = (if (areas.any { it.auto }) minOf(intervalMs, AUTO_INTERVAL_MS) else intervalMs) * maxOf(1, slowdown())
            manualDue = (areas.isNotEmpty() || states.values.any { it.shown.isNotEmpty() }) &&
                (lastPass?.let { time - it >= interval } ?: true)
            // Telefon kendi saatinde okunur; ek alanların turunu beklemez.
            phone = phoneSession?.takeIf { it.beginIfDue(time) }
            if (!manualDue && phone == null) return false
            if (manualDue) lastPass = time
            busy = true
            session
        }
        fun finish(): Unit = synchronized(lock) { if (started == session) busy = false }
        try {
            val crops = if (manualDue) areas.mapNotNull { area -> crop(area.region)?.let { area to it } } else emptyList()
            val due = phone
            run(Runnable {
                try {
                    if (manualDue) pass(areas.map { it.id }.toSet(), crops, started)
                    if (due != null && started == session && synchronized(lock) { phoneSession === due }) {
                        due.visit(packLookup, skipsTurkish, englishPhoneMessages)
                    }
                } finally {
                    finish()
                }
            })
        } catch (error: RejectedExecutionException) {
            finish()
            return false
        } catch (error: Exception) {
            finish()
            throw error
        }
        return true
    }

    /** Bir tur: kaldırılan alanların kutusu kalkar, her açık alan gerekirse okunur ve kararlı yazısı çevrilir. */
    fun pass(offeredIds: Set<String>, offered: List<Pair<ExtraArea, Crop>>, started: Int = session) {
        val kept = yieldingPresets(offered.map { it.first }.filter { wanted(it) }).map { it.id }.toSet()
        val crops = offered.filter { it.first.id in kept }
        val ids = offeredIds - offered.filterNot { it.first.id in kept }.map { it.first.id }.toSet()
        synchronized(lock) {
            if (started != session) return
            passes++
            for (id in states.keys.toList()) if (id !in ids) {
                if (states[id]!!.shown.isNotEmpty()) sender.sendRegion(id, "", null, null)
                states.remove(id)
            }
        }
        // Tur dönüyor: TV'deki alanlar yenilenebilir (#1271). Tur takılırsa (donma) yenileme durur, TV alanları kendisi kaldırır.
        sender.regionsAlive()
        try {
            for ((area, crop) in crops) {
                if (started != session) return
                visit(area, crop, started)
                sender.regionsAlive()
            }
        } finally {
            sender.regionsAlive()
        }
    }

    private fun visit(area: ExtraArea, crop: Crop, started: Int) {
        val state = synchronized(lock) {
            if (started != session) return
            states.getOrPut(area.id) { State() }
        }
        val changed = state.signature?.let { RegionSignature.changed(it, crop.signature) } ?: true
        state.signature = crop.signature
        val before = state.passSignature
        state.passSignature = crop.signature
        if (!changed) {
            // İz bir tur değişmedi: okunan yazı kararlıdır.
            state.unsteady = 0
            state.unsteadySince = null
            if (state.rejectPending) {
                // Çevirisi gösterilen otomatik alanda boş ya da gürültü okuma, görüntü değişmeden kaldı: bulucuya bildirilir
                // (alan listeden çıkar, kutusu kalkar; Mac/iPhone ve Windows'ta kararlı okumanın reddi).
                state.rejectPending = false
                state.lastRead = null
                onAutoRejected?.invoke(area.id)
                return
            }
            state.candidate?.let {
                state.candidate = null
                commit(it, area, state, started)
            }
            return
        }
        val frame = crop.frame
        if (GameAreaPresets.isPreset(area.id) && frame != null && !UiPanel.hasText(frame)) {
            // Hazır alanda arayüz kutusu yok (PS5 ana ekranı, başka oyun, oyun dünyası): OCR çalışmaz. İz unutulur: kare
            // değişmese de sonraki tur kutuyu yeniden arar; panel aynı yazıyla geri gelince yeniden okunup gösterilir.
            state.signature = null
            state.panelMisses++
            // Tek karelik ıska çeviriyi silmez: kutu [PANEL_MISS_TURNS] tur art arda yoksa gösterilen kutu kalkar.
            if (state.shown.isNotEmpty() && state.panelMisses < PANEL_MISS_TURNS) return
            state.candidate = null
            state.lastRead = null
            state.held = null
            state.holds = 0
            if (state.shown.isNotEmpty()) {
                state.shown = ""
                state.shownText = ""
                state.shownIcons = 0
                state.renderedKey = null
                state.renderedText = null
                state.renderedIcons = null
                state.renderedBox = null
                state.renderedLineHeight = null
                state.renderedLayout = null
                state.renderedBlocks = null
                state.renderedStyles = null
                synchronized(lock) { if (started == session) sender.sendRegion(area.id, "", null, null) }
            }
            return
        }
        state.panelMisses = 0
        val reading = try {
            read(crop)
        } catch (error: Exception) {
            // OCR hatası boş alan değildir. Eski kutuyu koru; aynı kareyi sonraki normal turda yeniden oku.
            // Başarısız kare, önceki adayın kararlılığını da doğrulayamaz.
            state.signature = null
            state.lastRead = null
            state.candidate = null
            return
        }
        if (started != session) return
        reads++
        // Altyazı alanındaki ya da altyazı hattının okuduğu satırlar ekran yazısı değildir; altyazı iki yerde çizilmesin
        // (bkz. [SubtitleEcho]). Menüde ve görev satırının kendi alanında yalnız metin eşleşmesi uygulanır.
        val geometry = (area.auto || GameAreaPresets.isPreset(area.id)) && !area.menu && area.id != MissionLine.AREA_ID &&
            !ScreenNotices.isNotice(area.id)
        val own = subtitleEcho?.filter(reading, area.region.box, geometry) ?: reading
        // Otomatik alanda aynı satırın yan yana okunan parçaları tek satırdır; menüde alanın kenarında kesik satır çevrilmez
        // ([joinedPieces], [cutAtAreaEdge]; Sinan Bey beta.100 3380-3383).
        val pieced = if (!area.auto) own else {
            val aspect = (area.region.right - area.region.left) * 16 / maxOf(1e-6, (area.region.bottom - area.region.top) * 9)
            Reading(joinedPieces(own.lines, aspect).filter { !area.menu || !cutAtAreaEdge(it, area.region) })
        }
        // Otomatik alanda ürün/ambalaj yazısı (bira kutusu, süt kartonu; sahnede, desenli zeminde) ekran yazısı değildir
        // ([PackageText], Sinan Bey beta.101: buzdolabındaki ambalajların yazıları ürünlerin üstüne çiziliyordu).
        val unpacked = if (area.auto && area.id != GameAreaPresets.PHONE_ID)
            PackageText.filter(pieced, area.region.box, PackageText.sampler(crop.frame, crop.color)).first else pieced
        val text = if (area.auto) AutoText.clean(unpacked, area.menu) else own
        // Kullanıcının kendi ek alanı da (#1324: "Telefon (sağ alt)" alanındaki tuş ipuçları) hazır ve otomatik alan gibi
        // özgün stilinde, grup grup ve çizim kipiyle (yanına yazma, ikiz kutu) çizilir: önceden tek kutu tuş simgelerinin
        // üstünü örtüyor, yazı boyu her okumada alanın kutusuna göre değişiyordu. Mac ve Windows aynı.
        var candidate = candidate(text, area.region, crop.frame, keepPrompts = area.menu, auto = area.auto, styled = true,
            color = crop.color)
        if (area.auto) {
            if (area.menu && !candidate.missionCard && ScreenTextKind.isHud(candidate.paragraphs)) onAutoHud?.invoke(area.id)
            // Menü dışındaki otomatik alanın türü okunan yazıdan çıkar (yardım/eylem ya da diğer); kapalı tür gürültü gibi
            // çizilmez, bulucuya bildirilir.
            val unwanted = kind(area, candidate)?.let { !allows(it) } ?: false
            // Arayüz sözlüğündeki tek sözcüklük menü/ipucu etiketi ("Map", "Settings", "EXIT") ve tuş simgeli ipucu kısa
            // olsa da menü etiketi gibi çevrilir: kısa metin filtresi (en az 8 harf, iki sözcük) menü durumu kısa süre
            // kaçınca onları atıyordu (Sinan Bey, beta.93: "Map", "Settings", "EXIT" İngilizce kaldı; Mac ve Windows aynı).
            val labelLike = area.menu || isUiLabel(candidate)
            if (candidate.key.isEmpty() || ScreenTextNoise.isNoise(candidate.paragraphs.joinToString(" ") { IconText.plain(it) }, labelLike) ||
                (!area.menu && isWorldText(candidate)) || unwanted) {
                val repeated = candidate.key.isNotEmpty() && state.lastRead == candidate.key
                if (!state.renderedText.isNullOrEmpty() && !repeated) {
                    // Çevirisi gösterilen alanda tek boş ya da gürültü okuma yazının gittiğini kanıtlamaz: alan hemen
                    // düşürülmez, kaldırma kararı [clearIfUnsteady]'de (Mac/iPhone ve Windows ile aynı). Önceden tek boş
                    // okuma alanı listeden çıkarıp çeviriyi kaldırıyordu; yazı yeniden okununca geri geliyordu.
                    state.lastRead = candidate.key
                    state.held = null
                    state.holds = 0
                    state.candidate = null
                    state.rejectPending = true
                    clearIfUnsteady(candidate, area, state, before, crop.signature, started)
                    return
                }
                // Sayaç, harita, kısa etiket ya da yazısız kutu: çevrilmez; alan bir sonraki turda listeden çıkar.
                state.candidate = null
                state.lastRead = null
                state.rejectPending = false
                onAutoRejected?.invoke(area.id)
                return
            }
            candidate = styled(candidate, text, area.region, crop.frame, crop.color, modes = true,
                kind = ScreenTextKind.of(area), screen = crop.screen, screenColor = crop.screenColor).copy(auto = true)
        } else {
            // Oyunun hazır alanı ve kullanıcının alanı otomatik alan gibi özgün stilinde, her grup kendi bloğunda, çizim
            // kipiyle çizilir (siyah kutu değil, #856; tuş simgesini örtmez, yazı boyu sabit, #1324).
            candidate = styled(candidate, text, area.region, crop.frame, crop.color, modes = true, kind = ScreenTextKind.of(area),
                screen = crop.screen, screenColor = crop.screenColor)
        }
        state.rejectPending = false
        // Çevirisi gösterilen alanda art arda boş okuma (görüntü değişirken) yazının gittiğini tek başına kanıtlamaz: kaldırma
        // kararı [clearIfUnsteady]'de (özgün yazının izi ya da süre).
        val emptyWhileShown = candidate.key.isEmpty() && !state.renderedText.isNullOrEmpty()
        if (state.lastRead == candidate.key && !emptyWhileShown) {
            state.unsteady = 0
            state.unsteadySince = null
            state.candidate = null
            commit(candidate, area, state, started)
        } else {
            // Seçim kaydı (#1267): gösterilen bir satırın zemini açıktan koyuya (ya da tersine) döndüyse eski kutular o
            // satırın eski renginde kalıyor, yeni okuma doğrulanana dek bozuk çeviri görünüyordu. Eski kutular hemen kalkar;
            // yeni okuma her zamanki gibi çizilir (Mac ve Windows ile aynı).
            // Liste kaydı (Sinan Bey beta.100 3381, 3383): menüde liste kayınca eski kutular eski yerinde başka satırın
            // üstünde kalıyordu; yazının bir kısmı hâlâ göründüğü için kararsız okuma da kaldırmıyordu. Gösterilen bir satır
            // başka yerde okunuyor ya da yerinde başka yazı var: eski kutular hemen kalkar.
            if (!state.renderedText.isNullOrEmpty() &&
                (selectionMoved(grounds(state.renderedLayout, state.renderedStyles), grounds(candidate.blocks, candidate.styles)) ||
                    (area.menu && listMoved(state.renderedBlocks.orEmpty().map { it.second }, blockTexts(candidate))))
            ) {
                state.shown = ""
                state.shownText = ""
                state.shownIcons = 0
                state.renderedKey = null
                state.renderedText = null
                state.renderedIcons = null
                state.renderedBox = null
                state.renderedLineHeight = null
                state.renderedLayout = null
                state.renderedBlocks = null
                state.renderedStyles = null
                synchronized(lock) { if (started == session) sender.sendRegion(area.id, "", null, null) }
                onLog?.invoke("ek alan ${area.name}: seçim kaydı, eski kutular kaldırıldı")
            }
            state.lastRead = candidate.key
            state.held = null
            state.holds = 0
            state.candidate = candidate
            if (!state.renderedText.isNullOrEmpty()) clearIfUnsteady(candidate, area, state, before, crop.signature, started)
            // Yazı kararlı mı diye bir tur beklenirken çevirisi şimdiden istenir: doğrulanınca çoğu zaman hazırdır.
            prefetch(candidate, state, started)
        }
    }

    /**
     * Çevirisi gösterilen alanda okuma doğrulanamadı. Çeviri iki durumda kaldırılır (#1198; Mac/iPhone ve Windows ile aynı):
     * - Yazı gitti: okuma boş ve özgün yazının izi yok ([traceGone]); görüntü de bütünüyle değiştiyse ([BIG_CHANGE_SHARE]) ilk
     *   turda, değilse ikinci turda. Gerçekten kalkan yazının çevirisi beklemez.
     * - Okuma en az [UNSTEADY_TURNS] tur ve [UNSTEADY_MS] boyunca gösterilen yazıya benzemedi ([unsteadyLong]).
     * Okumada gösterilen yazının bir parçası hâlâ görünüyorsa ([partlyVisible]) tur kararsız sayılmaz: arkası oynayan sabit
     * yazının çevirisi kalkıp geri gelmez.
     */
    private fun clearIfUnsteady(candidate: Candidate, area: ExtraArea, state: State, before: ByteArray?, signature: ByteArray, started: Int) {
        if (partlyVisible(candidate.text, state.shownText)) {
            state.unsteady = 0
            state.unsteadySince = null
            return
        }
        val time = clock()
        val turns = ++state.unsteady
        val since = state.unsteadySince ?: time
        state.unsteadySince = since
        val patience = synchronized(steadiness) { steadiness[area.id]?.patience ?: 0 }
        val bigChange = before != null && RegionSignature.changedShare(before, signature) >= BIG_CHANGE_SHARE
        // Kaldırılan yazı daha önce geri geldiyse (patience) boş okuma da art arda o kadar tur daha görülmeli.
        val gone = candidate.key.isEmpty() && traceGone(state.shownTrace, signature) && (bigChange || turns >= 2) && turns > patience
        if (!gone && !unsteadyLong(turns, time - since, patience)) return
        val shownText = state.shownText
        synchronized(lock) { if (started == session) sender.sendRegion(area.id, "", null, null) }
        state.shown = ""
        state.shownText = ""
        state.shownIcons = 0
        state.held = null
        state.holds = 0
        state.renderedKey = null
        state.renderedText = null
        state.renderedIcons = null
        state.renderedBox = null
        state.renderedLineHeight = null
        state.renderedLayout = null
        state.renderedBlocks = null
        state.renderedStyles = null
        state.unsteady = 0
        state.unsteadySince = null
        state.shownTrace = null
        synchronized(steadiness) {
            if (steadiness.size >= TRANSLATION_LIMIT && area.id !in steadiness) steadiness.clear()
            val memory = steadiness.getOrPut(area.id) { Steadiness() }
            memory.clearedText = shownText
            memory.clearedAt = time
        }
        drops.note("RegionWatcher", if (gone) "${area.name}: yazı kalktı (boş okuma, iz yok), çevirisi kaldırıldı"
            else "${area.name}: ${UNSTEADY_MS * (1 + patience) / 1000} sn kararlı okunmadı, çevirisi kaldırıldı", shownText, onLog)
    }

    /** Kaldırılan yazı [REBOUND_MS] içinde yeniden gösterildi: yazı yerindeydi; alanın kaldırma eşiği uzar, günlüğe yazılır. */
    private fun noteRebound(candidate: Candidate, area: ExtraArea) {
        val patience = synchronized(steadiness) {
            val memory = steadiness[area.id] ?: return
            val at = memory.clearedAt ?: return
            memory.clearedAt = null
            if (clock() - at > REBOUND_MS || !partlyVisible(candidate.text, memory.clearedText)) return
            memory.patience = minOf(MAX_PATIENCE, memory.patience + 1)
            memory.patience
        }
        drops.note("RegionWatcher", "${area.name}: kaldırılan yazı geri geldi, kaldırma eşiği ${1 + patience} katına uzadı",
            candidate.paragraphs.joinToString(" ") { IconText.plain(it) }, onLog)
    }

    /**
     * Kararlılık beklenirken çeviriyi başlatır. Ekrandaki yazı ve bekletilecek okuma (yarım ya da ekrandakine çok benzer)
     * için istenmez.
     */
    private fun prefetch(candidate: Candidate, state: State, started: Int) {
        if (!prefetchesTranslations || candidate.key.isEmpty() || candidate.key == state.shown || shouldHold(candidate, state)) return
        val task = translation(candidate, started, speculative = true) ?: return
        if (prefetchWork === INLINE) {
            // Turun iş parçacığında: süre sınırıyla beklenir; hata ya da süre aşımı doğrulanınca yeniden denenir.
            try { await(task) } catch (error: Exception) {}
            return
        }
        try {
            prefetchWork.execute(task)
        } catch (error: RejectedExecutionException) {
            // Hizmet kapanıyor. Kararlı okuma hâlâ gerekirse kendi işini başlatabilir.
            task.cancel(false)
        }
    }

    /**
     * Okuma bekletilmeli mi (gösterilmeden önce bir iki tur daha okunur):
     * - Az önce gösterilen yazının başı: yazı belirirken renkli sözcük geç geliyor ("Fly to a" ← "Fly to a drop");
     *   görev her belirişinde iki kez çevrilip değişiyordu.
     * - Ekrandakiyle neredeyse aynı ya da onun eksik hâli, ve daha çok simge bulmamış: harita arkada oynarken tuş çubuğu
     *   "SET DESTINATION ✕ EXIT ○" / "SET DESTINATIPN EXIT ○" diye okunup kutu sürekli değişiyordu.
     * - Daha çok simge bulmuş ama ekrandakinin bir sözcüğünü simgeyle değiştirmiş ("Find □" ← "Find Donnie").
     */
    private fun shouldHold(candidate: Candidate, state: State): Boolean {
        val text = candidate.text
        if (text.isEmpty()) return false
        if (state.remembered.length > text.length && state.remembered.startsWith("$text ")) return true
        if (state.shownText.isEmpty() || state.shownText == text) return false
        if (TextMatch.addsMeaning(text, state.shownText)) return false
        return if (iconCount(candidate) <= state.shownIcons) {
            TextMatch.isSimilar(state.shownText, text, 0.85) || isPartOf(text, state.shownText)
        } else {
            losesWords(text, state.shownText)
        }
    }

    private fun commit(candidate: Candidate, area: ExtraArea, state: State, started: Int) {
        // reset() ve TV'ye gönderim sıralı kalmalı: eski tur yeni oyunun üstüne yazmasın.
        fun send(action: () -> Unit): Unit = synchronized(lock) { if (started == session) action() }
        if (state.shown == candidate.key) {
            val text = state.renderedText
            if (state.renderedKey != candidate.key || text.isNullOrEmpty()) return
            if (state.renderedBox == candidate.box && state.renderedLineHeight == candidate.lineHeight &&
                state.renderedLayout == candidate.blocks && state.renderedStyles == candidate.styles) return
            // Aynı yazı kaydı: çeviriler korunur, bloklar yeni yerlerine taşınır (anahtar aynıysa grup sayısı da aynıdır).
            // Menüde seçim gezince (satırın zemini ve yazı rengi değişti) çeviri yeniden istenmez, yalnız renkler gider.
            val current = candidate.blocks
            val moved = if (current == null) null else state.renderedBlocks?.map { (group, item) ->
                val style = candidate.styles?.getOrNull(group)
                group to item.copy(box = current[group].box, lineHeight = current[group].lineHeight,
                    surface = style?.surface ?: item.surface, look = style?.look ?: item.look,
                    paint = current[group].paint ?: item.paint)
            }
            send { sender.sendRegion(area.id, text, candidate.box, candidate.lineHeight, state.renderedIcons, moved?.map { it.second }) }
            state.renderedBox = candidate.box
            state.renderedLineHeight = candidate.lineHeight
            state.renderedLayout = candidate.blocks
            state.renderedBlocks = moved
            state.renderedStyles = candidate.styles
            return
        }
        // Bekletilen okuma gösterilmeden yerine başka okuma geldi: o okuma hiç çevrilmedi (günlüğe bir kez).
        state.held?.let { held ->
            if (held != candidate.key) {
                drops.note("RegionWatcher", "${area.name}: bekletilen okuma gösterilmeden yerine yenisi geldi, çevrilmedi", state.heldText ?: "", onLog)
                state.held = null
            }
        }
        if (shouldHold(candidate, state)) {
            if (state.held != candidate.key) {
                state.held = candidate.key
                state.heldText = IconText.plain(candidate.paragraphs.joinToString(" "))
                state.holds = 0
            }
            if (++state.holds <= HOLD_LIMIT) {
                // Sonraki tur (iz değişmese de) bu okumayı yeniden dener; o hâlde kalırsa sınırda gösterilir.
                state.candidate = candidate
                return
            }
        }
        state.held = null
        state.holds = 0
        val previousShown = state.shown
        val previousText = state.shownText
        val previousIcons = state.shownIcons
        state.shown = candidate.key
        state.shownText = candidate.text
        state.shownIcons = iconCount(candidate)
        if (candidate.key.isEmpty()) {
            // Kutu hiç gösterilmediyse boşaltma olayı gönderilmez.
            if (!state.renderedText.isNullOrEmpty()) send { sender.sendRegion(area.id, "", null, null) }
            state.renderedKey = candidate.key
            state.renderedText = ""
            state.renderedIcons = null
            state.renderedBox = null
            state.renderedLineHeight = null
            return
        }
        val translated = try {
            // Önceden istenmiş ya da daha önce gösterilmiş yazı: çevirmene yeniden gidilmez. Önceden istenen çeviri
            // henüz başlamadıysa burada çalışır (run), sürüyorsa beklenir (get).
            val task = translation(candidate, started) ?: return
            await(task)
        } catch (error: Exception) {
            // Çevrilemedi: önceki yazı kutuda kalır, aynı yazı sonraki turda yeniden denenir.
            if (started == session) {
                onLog?.invoke("ek alan ${area.name}: ${logExcerpt(IconText.plain(candidate.paragraphs.joinToString(" ")), 120)} çevrilemedi (${error.message})")
            }
            if (started == session && state.shown == candidate.key) {
                state.shown = previousShown
                state.shownText = previousText
                state.shownIcons = previousIcons
                state.candidate = candidate
            }
            return
        }
        if (started != session || state.shown != candidate.key) return
        state.remembered = candidate.text
        val prepared = candidate.paragraphs.map { IconText.protect(it) }
        val slots = mutableListOf<IconSlot>()
        val text = mutableListOf<String>()
        for ((i, source) in candidate.paragraphs.withIndex()) {
            val translation = translated[i].trim()
            text.add(if (translation.isEmpty()) IconText.indexed(source, slots.size) else IconText.restore(translation, prepared[i].names, slots.size))
            candidate.icons?.getOrNull(i)?.let { slots.addAll(it) }
        }
        // Çevirisi aslıyla aynı (ad, sayı, zaten hedef dilde): kutu gösterilmez.
        val similar = candidate.paragraphs.zip(text).map { (a, b) ->
            TextMatch.isSimilar(TextMatch.normalize(IconText.plain(a)), TextMatch.normalize(IconText.plain(b)), 0.90)
        }
        if (similar.all { it }) {
            drops.note("RegionWatcher", "${area.name}: çevirisi aslıyla aynı, gösterilmedi", IconText.plain(candidate.paragraphs.joinToString(" ")), onLog)
            // Kutu hiç gösterilmediyse boşaltma olayı gönderilmez.
            if (!state.renderedText.isNullOrEmpty()) send { sender.sendRegion(area.id, "", null, null) }
            state.renderedText = ""
            state.renderedIcons = null
            state.renderedBox = null
            state.renderedLineHeight = null
            state.renderedLayout = null
            state.renderedBlocks = null
        } else {
            val rendered = IconText.render(text.joinToString("\n"), slots)
            val icons = rendered.icons.takeIf { it.isNotEmpty() }
            val blocks = candidate.blocks?.let { renderBlocks(candidate, it, text, similar, slots) }
            send { sender.sendRegion(area.id, rendered.text, candidate.box, candidate.lineHeight, icons, blocks?.map { it.second }) }
            state.renderedText = rendered.text
            state.renderedIcons = icons
            state.renderedBox = candidate.box
            state.renderedLineHeight = candidate.lineHeight
            state.renderedLayout = candidate.blocks
            state.renderedBlocks = blocks
            state.renderedStyles = candidate.styles
            state.shownTrace = state.passSignature
            state.unsteady = 0
            state.unsteadySince = null
            noteRebound(candidate, area)
        }
        state.renderedKey = candidate.key
    }

    /**
     * Çeviriyi en çok [translationTimeoutMs] bekler. Başlamamış iş [deadlineWork]'te başlatılır (başka yerde sürüyorsa
     * `run` bir şey yapmaz). Süre dolunca iş iptal edilir (saklananlardan çıkar) ve [TimeoutException] atılır.
     */
    private fun await(task: Pending): List<String> {
        if (!task.isDone) {
            try {
                deadlineWork.execute(task)
            } catch (error: RejectedExecutionException) {
                task.run()
            }
        }
        return try {
            task.get(translationTimeoutMs, TimeUnit.MILLISECONDS)
        } catch (error: TimeoutException) {
            task.cancel(true)
            task.forget()
            throw TimeoutException("çeviri ${translationTimeoutMs / 1000.0} sn'de bitmedi")
        } catch (error: Exception) {
            // [Pending.done] işin kendi iş parçacığında, bekleyen uyandıktan sonra çalışır: sonraki tur başarısız işi
            // saklananlarda bulmasın, yeniden denesin.
            task.forget()
            throw error
        }
    }

    /** Parçaların çevirisinin işi; başarısız biterse [failed] çağrılır (saklananlardan çıkarılsın, sonra yeniden denensin). */
    private class Pending(work: Callable<List<String>>, private val failed: (Pending) -> Unit) : FutureTask<List<String>>(work) {
        override fun done() {
            if (isCancelled || runCatching { get() }.isFailure) failed(this)
        }

        /** Saklananlardan hemen çıkar (başarısız ya da süresi dolmuş iş). */
        fun forget() = failed(this)
    }

    /**
     * Süren ya da bitmiş çeviriler (anahtar → parçaların çevirisi). Oyun görev yazısını arada silip yeniden gösteriyor;
     * aynı yazı gelince çevirmene yeniden gidilmez, anında gösterilir. Önceden istenen çeviri de buradan alınır.
     */
    private val translations = HashMap<List<String>, Pending>()

    /**
     * Aynı paragraflar aynı işi paylaşır. Doğrulanmamış okumalar için en çok bir iş başlatılır.
     */
    private fun translation(candidate: Candidate, started: Int, speculative: Boolean = false): Pending? = synchronized(translations) {
        if (started != session) return null
        val key = candidate.paragraphs
        translations[key]?.let { return if (speculative) null else it }
        if (speculative && translations.values.any { !it.isDone }) return null
        if (translations.size >= TRANSLATION_LIMIT) translations.values.removeAll { it.isDone }
        // Aynı çevirmen örneğinin bağlamına iki iş parçacığı birden yazmasın.
        val engine = if (speculative) prefetchTranslator else translator
        val task = Pending(Callable {
            synchronized(engine) { if (candidate.auto) translateAuto(key, engine, started) else translateNow(key, engine, started) }
        }) { failed ->
            synchronized(translations) { if (translations[key] === failed) translations.remove(key) }
        }
        translations[key] = task
        task
    }

    private fun translateNow(paragraphs: List<String>, engine: TextTranslator, started: Int): List<String> {
        // Simgeler paket aramasında yok sayılır, çeviride uydurma adlarla korunur (IconText).
        val prepared = paragraphs.map { IconText.protect(it) }
        // Zaten Türkçe olan parça çevrilmez: aslı kalır, tümü öyleyse kutu gösterilmez.
        return paragraphs.mapIndexed { i, paragraph ->
            if (started != session) throw CancellationException()
            // Yalnız özel adlardan oluşan yazı ("JASON & LUCIA") çevrilmez (#859).
            if (ScreenTranslation.keepsNames(paragraph)) paragraph
            else packLookup?.invoke(IconText.plain(paragraph))?.text
                ?: if (skipsTurkish && TurkishText.isSure(paragraph)) paragraph else engine.translate(prepared[i].text)
        }
    }

    /**
     * Oturum terim sözlüğü (korunmuş kaynak → çeviri): aynı kısa etiket hep aynı çeviriyle gösterilir ("MAP" iki yerde
     * de "HARİTA"), aynı menüye dönüşte çevirmene gidilmez. Oyun değişince de korunur (aynı çeviri oturumu).
     */
    private val sessionTerms = LinkedHashMap<String, String>()

    /** Sayaç ("1 / 3", "5 / 9", "100%") ya da tuş adı (L1, R3, △): çevrilmez, olduğu gibi kalır. */
    private val untouched = Regex("^(?:[LR][123]?|[△□○✕×]|[\\p{N}\\p{P}\\p{S}\\s]+)$")

    /**
     * Otomatik ekran yazısının çevirisi (yoğun menüler: kontrol şeması, duraklatma menüsü). " / " ile ayrılan etiket
     * parça parça çevrilir; sayaçlar ve tuş adları dokunulmaz kalır. Her parça önce arayüz sözlüğü ([UiCommands]),
     * oturum terimleri ve oyun paketinde aranır; kalanların hepsi TEK toplu istekle ([TextTranslator.translateAll])
     * çevrilir.
     */
    private fun translateAuto(paragraphs: List<String>, engine: TextTranslator, started: Int): List<String> {
        val prepared = paragraphs.map { IconText.protect(it) }
        class Piece(val text: String, val names: List<String>, var result: String? = null)
        // Baştaki konuşan adı ("Staff Member: 'Sup?") ve özel ad ("JASON & LUCIA MAP", sekmeler tek parça okununca)
        // çevrilmez, olduğu gibi kalır; yalnız ardındaki yazı çevrilir ([keptHead]; Sinan Bey beta.100 3380).
        val heads = mutableMapOf<Piece, String>()
        val pieces = prepared.map { protected ->
            protected.text.split(" / ").map { part ->
                val head = keptHead(part)
                val rest = if (head != null) part.substring(head.length) else part
                Piece(rest, protected.names.filter { rest.contains(it) }.sortedBy { rest.indexOf(it) }).also { piece ->
                    if (head != null) heads[piece] = head
                }
            }
        }
        val missing = mutableListOf<Piece>()
        for (piece in pieces.flatten()) {
            val marked = piece.names.fold(piece.text) { text, name -> text.replace(name, ButtonIcons.MARKER.toString()) }
            val plain = IconText.plain(marked).trim()
            piece.result = when {
                plain.isEmpty() || untouched.matches(plain) -> piece.text
                // Yalnız özel adlardan oluşan sekme ("JASON & LUCIA") çevrilmez (#859).
                ScreenTranslation.keepsNames(plain) -> piece.text
                else -> UiCommands.translateLabelLoosely(marked)?.let { ui ->
                    // Sözlük çevirisindeki simge imleri yeniden adlara döner (çevirinin simge yerleri korunur).
                    var k = 0
                    buildString { for (c in ui) if (c == ButtonIcons.MARKER && k < piece.names.size) append(piece.names[k++]) else append(c) }
                } ?: synchronized(sessionTerms) { sessionTerms[piece.text] }
                    ?: packLookup?.invoke(plain)?.text
                    ?: if (skipsTurkish && TurkishText.isSure(plain)) piece.text else null
            }
            if (piece.result == null) missing.add(piece)
        }
        if (missing.isNotEmpty()) {
            if (started != session) throw CancellationException()
            val unique = missing.map { it.text }.distinct()
            val translated = if (unique.size == 1) listOf(engine.translate(unique[0])) else engine.translateAll(unique)
            val found = unique.zip(translated).toMap()
            synchronized(sessionTerms) {
                for ((source, target) in found) {
                    sessionTerms[source] = target
                    if (sessionTerms.size > SESSION_TERMS) sessionTerms.remove(sessionTerms.keys.first())
                }
            }
            missing.forEach { it.result = found[it.text] ?: it.text }
        }
        return pieces.map { parts -> parts.joinToString(" / ") { (heads[it] ?: "") + it.result!! } }
    }

    /** Çeviri durdu: süren tur bırakılır, TV'deki ek alan kutuları kalkar. */
    fun reset(): Unit = synchronized(lock) {
        phoneSession?.close()
        phoneSession = null
        phoneMemory.clear()
        session++
        busy = false
        lastPass = null
        synchronized(translations) {
            val pending = translations.values.toList()
            translations.clear()
            pending.forEach { it.cancel(false) }
        }
        val anyShown = states.values.any { it.shown.isNotEmpty() || !it.renderedText.isNullOrEmpty() }
        states.clear()
        synchronized(steadiness) { steadiness.clear() }
        if (anyShown) sender.clearRegions()
    }
}
