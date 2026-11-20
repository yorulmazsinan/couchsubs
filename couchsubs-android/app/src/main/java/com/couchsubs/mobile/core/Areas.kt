// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.Executor
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
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

/**
 * Altyazı alanının yanında sürekli okunan ek alan (görev yazısı, telefon mesajı, bildirim; Mac/iPhone ExtraArea.swift).
 * Ek alanlar ana altyazıdan ayrı ve daha seyrek okunur ([RegionWatcher]); çevirileri TV'de kendi yerlerinde küçük kutuda
 * görünür.
 */
data class ExtraArea(
    val id: String = UUID.randomUUID().toString(), val name: String, val region: CropRegion, val enabled: Boolean = true,
    /** Ekran yazısı bulucusunun ([ScreenTextDetector]) geçici alanı; kaydedilmez, gürültüsü elenir, sık okunur. */
    val auto: Boolean = false,
) {
    companion object {
        /** En çok bu kadar ek alan tanımlanır (her biri saniyede bir okunur). */
        const val MAX_COUNT = 3

        fun listToJson(areas: List<ExtraArea>): String = JSONArray().also { array ->
            areas.forEach { array.put(JSONObject().put("id", it.id).put("name", it.name).put("region", it.region.toJson()).put("enabled", it.enabled)) }
        }.toString()

        fun listFromJson(text: String?): List<ExtraArea> = try {
            val array = JSONArray(text ?: "[]")
            (0 until array.length()).map { array.getJSONObject(it) }.map { item ->
                ExtraArea(item.optString("id").ifEmpty { UUID.randomUUID().toString() }, item.optString("name"),
                    cropRegionFrom(item.optJSONObject("region")) ?: ExtraAreaPreset.QUEST.region, item.optBoolean("enabled", true))
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
        text.count { it.isLetter() } >= 2 && text.split(Regex("\\s+")).any { word -> word.count { it.isLetter() } >= 2 }

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
    private val prefetchWork: Executor = Executor { it.run() },
    private val prefetchTranslator: TextTranslator = translator,
) {
    companion object {
        /** İki tur arasındaki en kısa süre; iPhone ve Mac ile aynı (saniyede en çok bir tur, pil ve ısı için). */
        const val DEFAULT_INTERVAL_MS = 1000L

        /** Otomatik ekran yazısı alanı varken iki tur arasındaki en uzun süre. */
        const val AUTO_INTERVAL_MS = 500L

        /**
         * Ekrandakinden yalnız biraz farklı (ya da eksik) kararlı okuma en çok bu kadar tur bekletilir; o hâlde kalırsa
         * gerçekten değişmiş sayılır ve gösterilir (görevin tek sözcüğü değişebilir: "Go to the barn" → "Go to the bank").
         */
        internal const val HOLD_LIMIT = 4

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
         * Okumadan çevrilecek parçalar, kutusu (kareye oranla) ve satır yüksekliği. Yazının içindeki kumanda simgeleri
         * [frame]'den (okunan alan) kesilir; çeviride yerleri korunur.
         */
        fun candidate(reading: Reading, region: CropRegion, frame: GrayFrame? = null): Candidate {
            val lines = reading.withButtonIcons().withoutButtonPrompts().withoutOcrNoise().lines
                .filter { ScreenText.isWords(it.text) }
                .sortedBy { it.box?.top ?: 0.0 }
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
            val groups = if (lines.size > 1 && boxes.size == lines.size) ScreenTranslation.groups(reading) else emptyList()
            if (groups.size > 1 && groups.size < ScreenTranslation.MAX_GROUPS) {
                paragraphs = groups.flatMap { it.paragraphs }
                icons = groups.flatMap { group -> group.icons ?: group.paragraphs.map { emptyList<IconSlot>() } }
                var start = 0
                val list = groups.map { group ->
                    Block(start, group.paragraphs.size, group.box.placedIn(region.box), group.lineHeight * height)
                        .also { start += group.paragraphs.size }
                }
                blocks = list
                key = textKey(paragraphs) + "|" + list.joinToString(",") { it.count.toString() }
            }
            val cut = if (frame == null || icons.all { it.isEmpty() }) null else icons.map { ButtonIcons.withImages(it, frame) }
            return Candidate(paragraphs, box, lineHeight, key, cut, blocks, textKey(paragraphs))
        }

        /**
         * Her grubun çevirisi kendi yeriyle. Çevirisi aslıyla aynı grup (ad, sayı) atlanır; İngilizcesi görünür kalır.
         * [text] simge imlerini bütün alanın sırasıyla taşır; [slots] o sıradaki simgeler.
         */
        /**
         * Otomatik ekran yazısı: her blok (tek grupta bütün yazı tek blok) için özgün görünüş [frame]'den (okunan alan)
         * çıkarılır; çeviri aynı yerde, aynı renk ve biçimde gösterilir.
         */
        internal fun styled(candidate: Candidate, reading: Reading, region: CropRegion, frame: GrayFrame?): Candidate {
            if (frame == null) return candidate
            val blocks = candidate.blocks ?: run {
                val box = candidate.box ?: return candidate
                val line = candidate.lineHeight ?: return candidate
                listOf(Block(0, candidate.paragraphs.size, box, line))
            }
            val width = region.right - region.left
            val height = region.bottom - region.top
            if (width <= 0 || height <= 0) return candidate
            val lines = reading.lines.mapNotNull { line -> line.box?.placedIn(region.box) }
            val styles = blocks.map { block ->
                val box = block.box
                val source = (block.start until block.start + block.count).joinToString("\n") { IconText.plain(candidate.paragraphs[it]) }
                val edges = lines.filter { (it.top + it.bottom) / 2 in box.top..box.bottom && (it.left + it.right) / 2 in box.left..box.right }
                    .map { it.left to it.right }
                TextStyleSampler.sample(
                    frame,
                    ((box.left - region.left) / width * frame.width).toInt(), ((box.top - region.top) / height * frame.height).toInt(),
                    kotlin.math.ceil((box.right - region.left) / width * frame.width).toInt(),
                    kotlin.math.ceil((box.bottom - region.top) / height * frame.height).toInt(),
                    block.lineHeight / height * frame.height, source, edges,
                )
            }
            return candidate.copy(blocks = blocks, styles = styles)
        }

        internal fun renderBlocks(
            candidate: Candidate, layout: List<Block>, text: List<String>, similar: List<Boolean>, slots: List<IconSlot>,
        ): List<Pair<Int, ScreenTranslation.Item>> = layout.mapIndexedNotNull { index, block ->
            val range = block.start until block.start + block.count
            if (range.all { similar[it] }) return@mapIndexedNotNull null
            val rendered = IconText.render(range.joinToString("\n") { text[it] }, slots)
            val source = range.joinToString("\n") { IconText.plain(candidate.paragraphs[it]) }
            val style = candidate.styles?.getOrNull(index)
            // Özgün yazı BÜYÜK HARFse çeviri de (Türkçe kurallarıyla); simge yerleri değişmez.
            val translation = if (style?.look?.upper == true) TextStyleSampler.upper(rendered.text) else rendered.text
            index to ScreenTranslation.Item(source, translation, block.box, block.lineHeight, rendered.icons.takeIf { it.isNotEmpty() },
                style?.surface, style?.look)
        }
    }

    /** Bir alanın karesi: okunacak gri görüntü ve izi; [frame] kumanda simgelerinin kesileceği aynı görüntü. */
    class Crop(val pixels: Any, val signature: ByteArray, val frame: GrayFrame? = null)

    /**
     * Alanda ayrı duran bir yazı grubu: [Candidate.paragraphs] içinde [start]'tan başlayan [count] parça, karedeki yeri ve
     * satır yüksekliği (kareye oranla).
     */
    data class Block(val start: Int, val count: Int, val box: TextBox, val lineHeight: Double)

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
    )

    private class State {
        var signature: ByteArray? = null
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
        var holds = 0
        var renderedKey: String? = null
        var renderedText: String? = null
        var renderedIcons: List<IconPlacement>? = null
        var renderedBox: TextBox? = null
        var renderedLineHeight: Double? = null
        var renderedLayout: List<Block>? = null
        /** Gönderilen bloklar ve her birinin [Candidate.blocks] içindeki sırası. */
        var renderedBlocks: List<Pair<Int, ScreenTranslation.Item>>? = null
    }

    private val lock = Any()
    private val states = mutableMapOf<String, State>()
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

    /** Otomatik alan okundu ama yazı yok ya da gürültü ([ScreenTextNoise]): bulucu o karoları reddeder. */
    @Volatile var onAutoRejected: ((String) -> Unit)? = null

    /** Tamamlanan tur ve okuma sayısı (testler için). */
    var passes = 0
        private set
    var reads = 0
        private set

    /**
     * Her karede çağrılır: tur zamanı geldiyse ve önceki tur bittiyse alanların kareleri [crop] ile alınır ve tur
     * [run] ile (çağıranın iş parçacığında) başlatılır; true döner. Yoksa hemen false.
     */
    fun offer(areas: List<ExtraArea>, crop: (CropRegion) -> Crop?, run: (Runnable) -> Unit): Boolean {
        val started = synchronized(lock) {
            if (busy || (areas.isEmpty() && states.values.none { it.shown.isNotEmpty() })) return false
            val time = clock()
            // Otomatik ekran yazısı varken yazı ~1 sn içinde görünsün: tur aralığı en çok 500 ms.
            val interval = if (areas.any { it.auto }) minOf(intervalMs, AUTO_INTERVAL_MS) else intervalMs
            lastPass?.let { if (time - it < interval) return false }
            lastPass = time
            busy = true
            session
        }
        fun finish(): Unit = synchronized(lock) { if (started == session) busy = false }
        try {
            val crops = areas.mapNotNull { area -> crop(area.region)?.let { area to it } }
            run(Runnable {
                try {
                    pass(areas.map { it.id }.toSet(), crops, started)
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
    fun pass(ids: Set<String>, crops: List<Pair<ExtraArea, Crop>>, started: Int = session) {
        synchronized(lock) {
            if (started != session) return
            passes++
            for (id in states.keys.toList()) if (id !in ids) {
                if (states[id]!!.shown.isNotEmpty()) sender.sendRegion(id, "", null, null)
                states.remove(id)
            }
        }
        for ((area, crop) in crops) {
            if (started != session) return
            visit(area, crop, started)
        }
    }

    private fun visit(area: ExtraArea, crop: Crop, started: Int) {
        val state = synchronized(lock) {
            if (started != session) return
            states.getOrPut(area.id) { State() }
        }
        val changed = state.signature?.let { RegionSignature.changed(it, crop.signature) } ?: true
        state.signature = crop.signature
        if (!changed) {
            // İz bir tur değişmedi: okunan yazı kararlıdır.
            state.candidate?.let {
                state.candidate = null
                commit(it, area, state, started)
            }
            return
        }
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
        var candidate = candidate(reading, area.region, crop.frame)
        if (area.auto) {
            if (candidate.key.isEmpty() || ScreenTextNoise.isNoise(candidate.paragraphs.joinToString(" ") { IconText.plain(it) })) {
                // Sayaç, harita, kısa etiket ya da yazısız kutu: çevrilmez; alan bir sonraki turda listeden çıkar.
                state.candidate = null
                state.lastRead = null
                onAutoRejected?.invoke(area.id)
                return
            }
            candidate = styled(candidate, reading, area.region, crop.frame)
        }
        if (state.lastRead == candidate.key) {
            state.candidate = null
            commit(candidate, area, state, started)
        } else {
            state.lastRead = candidate.key
            state.held = null
            state.holds = 0
            state.candidate = candidate
            // Yazı kararlı mı diye bir tur beklenirken çevirisi şimdiden istenir: doğrulanınca çoğu zaman hazırdır.
            prefetch(candidate, state, started)
        }
    }

    /**
     * Kararlılık beklenirken çeviriyi başlatır. Ekrandaki yazı ve bekletilecek okuma (yarım ya da ekrandakine çok benzer)
     * için istenmez.
     */
    private fun prefetch(candidate: Candidate, state: State, started: Int) {
        if (!prefetchesTranslations || candidate.key.isEmpty() || candidate.key == state.shown || shouldHold(candidate, state)) return
        val task = translation(candidate, started, speculative = true) ?: return
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
                state.renderedLayout == candidate.blocks) return
            // Aynı yazı kaydı: çeviriler korunur, bloklar yeni yerlerine taşınır (anahtar aynıysa grup sayısı da aynıdır).
            val current = candidate.blocks
            val moved = if (current == null) null else state.renderedBlocks?.map { (group, item) ->
                group to item.copy(box = current[group].box, lineHeight = current[group].lineHeight)
            }
            send { sender.sendRegion(area.id, text, candidate.box, candidate.lineHeight, state.renderedIcons, moved?.map { it.second }) }
            state.renderedBox = candidate.box
            state.renderedLineHeight = candidate.lineHeight
            state.renderedLayout = candidate.blocks
            state.renderedBlocks = moved
            return
        }
        if (shouldHold(candidate, state)) {
            if (state.held != candidate.key) {
                state.held = candidate.key
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
            send { sender.sendRegion(area.id, "", null, null) }
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
            task.run()
            task.get()
        } catch (error: Exception) {
            // Çevrilemedi: önceki yazı kutuda kalır, aynı yazı sonraki turda yeniden denenir.
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
            send { sender.sendRegion(area.id, "", null, null) }
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
        }
        state.renderedKey = candidate.key
    }

    /** Parçaların çevirisinin işi; başarısız biterse [failed] çağrılır (saklananlardan çıkarılsın, sonra yeniden denensin). */
    private class Pending(work: Callable<List<String>>, private val failed: (Pending) -> Unit) : FutureTask<List<String>>(work) {
        override fun done() {
            if (isCancelled || runCatching { get() }.isFailure) failed(this)
        }
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
            synchronized(engine) { translateNow(key, engine, started) }
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
            packLookup?.invoke(IconText.plain(paragraph))?.text
                ?: if (skipsTurkish && TurkishText.isSure(paragraph)) paragraph else engine.translate(prepared[i].text)
        }
    }

    /** Çeviri durdu: süren tur bırakılır, TV'deki ek alan kutuları kalkar. */
    fun reset(): Unit = synchronized(lock) {
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
        if (anyShown) sender.clearRegions()
    }
}
