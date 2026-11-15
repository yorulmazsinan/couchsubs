// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
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
data class ExtraArea(val id: String = UUID.randomUUID().toString(), val name: String, val region: CropRegion, val enabled: Boolean = true) {
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
) {
    companion object {
        const val DEFAULT_INTERVAL_MS = 1000L

        /** Okumadan çevrilecek parçalar, kutusu (kareye oranla) ve satır yüksekliği. */
        fun candidate(reading: Reading, region: CropRegion): Candidate {
            val lines = reading.withoutButtonPrompts().withoutOcrNoise().lines
                .filter { ScreenText.isWords(it.text) }
                .sortedBy { it.box?.top ?: 0.0 }
            val paragraphs = ScreenText.paragraphs(lines)
            val boxes = lines.mapNotNull { it.box }
            val box = boxes.reduceOrNull { a, b -> a.union(b) }?.placedIn(region.box)
            val heights = boxes.map { (it.bottom - it.top) * (region.bottom - region.top) }.sorted()
            val lineHeight = if (heights.isEmpty()) null else heights[heights.size / 2]
            return Candidate(paragraphs, box, lineHeight, TextMatch.normalize(paragraphs.joinToString(" ")))
        }
    }

    /** Bir alanın karesi: okunacak gri görüntü ve izi. */
    class Crop(val pixels: Any, val signature: ByteArray)

    data class Candidate(val paragraphs: List<String>, val box: TextBox?, val lineHeight: Double?, val key: String)

    private class State {
        var signature: ByteArray? = null
        var lastRead: String? = null
        var candidate: Candidate? = null
        var shown = ""
    }

    private val lock = Any()
    private val states = mutableMapOf<String, State>()
    private var lastPass: Long? = null
    @Volatile private var busy = false
    @Volatile private var session = 0

    @Volatile var packLookup: ((String) -> PackMatch?)? = null

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
        val anyShown = synchronized(lock) { states.values.any { it.shown.isNotEmpty() } }
        if (busy || (areas.isEmpty() && !anyShown)) return false
        val time = clock()
        lastPass?.let { if (time - it < intervalMs) return false }
        lastPass = time
        val crops = areas.mapNotNull { area -> crop(area.region)?.let { area to it } }
        busy = true
        val started = session
        run(Runnable {
            try {
                pass(areas.map { it.id }.toSet(), crops, started)
            } finally {
                if (started == session) busy = false
            }
        })
        return true
    }

    /** Bir tur: kaldırılan alanların kutusu kalkar, her açık alan gerekirse okunur ve kararlı yazısı çevrilir. */
    fun pass(ids: Set<String>, crops: List<Pair<ExtraArea, Crop>>, started: Int = session) {
        passes++
        synchronized(lock) {
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
        val state = synchronized(lock) { states.getOrPut(area.id) { State() } }
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
            Reading.Empty
        }
        if (started != session) return
        reads++
        val candidate = candidate(reading, area.region)
        if (state.lastRead == candidate.key) {
            state.candidate = null
            commit(candidate, area, state, started)
        } else {
            state.lastRead = candidate.key
            state.candidate = candidate
        }
    }

    private fun commit(candidate: Candidate, area: ExtraArea, state: State, started: Int) {
        if (state.shown == candidate.key) return
        state.shown = candidate.key
        if (candidate.key.isEmpty()) {
            sender.sendRegion(area.id, "", null, null)
            return
        }
        val translated = try {
            candidate.paragraphs.map { packLookup?.invoke(it)?.text ?: translator.translate(it) }
        } catch (error: Exception) {
            // Çevrilemedi: sonraki değişiklikte yeniden denenir.
            state.shown = ""
            return
        }
        if (started != session || state.shown != candidate.key) return
        val text = candidate.paragraphs.zip(translated).map { (source, translation) -> translation.trim().ifEmpty { source } }
        // Çevirisi aslıyla aynı (ad, sayı, zaten hedef dilde): kutu gösterilmez.
        val same = candidate.paragraphs.zip(text).all { (a, b) -> TextMatch.isSimilar(TextMatch.normalize(a), TextMatch.normalize(b), 0.90) }
        if (same) sender.sendRegion(area.id, "", null, null)
        else sender.sendRegion(area.id, text.joinToString("\n"), candidate.box, candidate.lineHeight)
    }

    /** Çeviri durdu: süren tur bırakılır, TV'deki ek alan kutuları kalkar. */
    fun reset() {
        session++
        busy = false
        lastPass = null
        val anyShown = synchronized(lock) {
            val shown = states.values.any { it.shown.isNotEmpty() }
            states.clear()
            shown
        }
        if (anyShown) sender.clearRegions()
    }
}
