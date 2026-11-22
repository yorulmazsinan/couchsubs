// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

/**
 * Gerçek kare gerileme setinin "Ekran yazısı (menü, görev listesi)" ölçütü Android'de (#856, #859, #860): menü ve görev
 * ekranında "Ekranı çevir", otomatik ekran yazısı ve oyunun hazır alanları her yazıyı kendi kutusunda, kendi yerinde ve
 * özgün renginde çizmeli; özel ad çevrilmez, görev fotoğrafı ve tuş simgesi ("RECENTER L3") örtülmez. ML Kit JVM
 * testinde çalışmadığı için karelerin Mac'te Apple Vision ile kaydedilmiş okumaları (testdata/frames/ocr/screen,
 * frame-regression record-screen) Android'in hattından geçer; pikseller karenin kendisinden. Beklenenler frames.json →
 * screen; kurallar Mac'teki koşucunun (tools/frame-regression ScreenCheck.swift) aynısı.
 */
class ScreenFramesTest {
    private val directory: File = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .first { File(it, "frames.json").isFile }

    /** Okunan görüntü: gri düzlem ve (x, y) rengi (0xRRGGBB). */
    private class Picture(val gray: GrayFrame, val color: (Int, Int) -> Int, val rgb: IntArray, val width: Int, val height: Int)

    private fun picture(rgb: IntArray, width: Int, height: Int): Picture {
        val luma = ByteArray(rgb.size) { i ->
            val c = rgb[i]
            ((299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000).toByte()
        }
        return Picture(GrayFrame(luma, width, height), { x, y -> rgb[y * width + x] }, rgb, width, height)
    }

    /** Kareyi masaüstü JDK'nın ImageIO'suyla okur (Android sınıf yolunda yok; test JVM'inde var; RealFramesTest gibi). */
    private fun load(file: File): Picture {
        val buffered = Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java).invoke(null, file)
        val type = buffered.javaClass
        val width = type.getMethod("getWidth").invoke(buffered) as Int
        val height = type.getMethod("getHeight").invoke(buffered) as Int
        val rgb = type.getMethod("getRGB", Int::class.java, Int::class.java, Int::class.java, Int::class.java, IntArray::class.java,
            Int::class.java, Int::class.java).invoke(buffered, 0, 0, width, height, null, 0, width) as IntArray
        for (i in rgb.indices) rgb[i] = rgb[i] and 0xFFFFFF
        return picture(rgb, width, height)
    }

    /** Alanın kesiti (Mac RegionCropper gibi: tam piksele genişletilmiş dikdörtgen). */
    private fun crop(source: Picture, region: CropRegion): Picture {
        val x0 = floor(source.width * region.left).toInt().coerceIn(0, source.width)
        val x1 = ceil(source.width * region.right).toInt().coerceIn(0, source.width)
        val y0 = floor(source.height * region.top).toInt().coerceIn(0, source.height)
        val y1 = ceil(source.height * region.bottom).toInt().coerceIn(0, source.height)
        val width = x1 - x0
        val height = y1 - y0
        return picture(IntArray(width * height) { i -> source.rgb[(y0 + i / width) * source.width + x0 + i % width] }, width, height)
    }

    private fun box(array: JSONArray) = TextBox(array.getDouble(0), array.getDouble(1), array.getDouble(2), array.getDouble(3))

    private fun region(array: JSONArray) = CropRegion(array.getDouble(1), array.getDouble(3), array.getDouble(0), array.getDouble(2))

    private fun reading(lines: JSONArray) = Reading((0 until lines.length()).map { i ->
        val line = lines.getJSONObject(i)
        val words = line.optJSONArray("words")?.let { list ->
            (0 until list.length()).map { k -> TextWord(list.getJSONObject(k).getString("text"), box(list.getJSONObject(k).getJSONArray("box"))) }
        }
        TextLine(line.getString("text"), line.optJSONArray("box")?.let(::box), words = words,
            confidence = if (line.has("confidence")) line.getDouble("confidence").toFloat() else null)
    })

    private fun strings(array: JSONArray?) = array?.let { list -> (0 until list.length()).map { list.getString(it) } } ?: emptyList()

    /** Yazının harf ve rakamları, küçük harfle (Mac koşucusundaki `normalized`). */
    private fun normalized(text: String) = text.lowercase().filter { it.isLetterOrDigit() }

    /** Sabit sözlük: bilinmeyen yazıya kaynağı içermeyen numaralı yer tutucu (Mac DictionaryTranslator). */
    private inner class Dictionary : TextTranslator {
        private val words = JSONObject(File(directory, "sozluk.json").readText()).let { json ->
            json.keys().asSequence().associate { normalized(it) to json.getString(it) }
        }
        val calls = mutableListOf<Pair<String, String>>()

        override fun translate(text: String): String = synchronized(calls) {
            val output = words[normalized(text)] ?: "çeviri №${calls.size + 1}."
            calls.add(text to output)
            output
        }
    }

    /** Çizilen bir çeviri kutusu. */
    private class Unit(val source: String, val box: TextBox, val background: String?)

    /** TV yerine: alan başına son gönderim. */
    private class Recorder(val translator: Dictionary) : RegionSender {
        val current = mutableMapOf<String, List<Unit>>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) = sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?, blocks: List<ScreenTranslation.Item>?,
        ) {
            if (text.isEmpty() || box == null) { current.remove(id); return }
            current[id] = blocks?.map { Unit(it.source, it.box, it.surface?.background) } ?: run {
                val sources = translator.calls.filter { it.second.isNotEmpty() && text.contains(it.second) }.map { it.first }
                listOf(Unit(sources.joinToString("\n"), box, null))
            }
        }
        override fun clearRegions() = current.clear()
    }

    /** Alanları Mac'in okumalarıyla üç tur okur; çizilenler. */
    private fun watch(areas: List<Pair<ExtraArea, JSONObject>>, image: Picture, translator: Dictionary): List<Unit> {
        val recorder = Recorder(translator)
        val readings = areas.associate { (area, fixture) -> area.id to reading(fixture.getJSONArray("lines")) }
        var time = 0L
        val watcher = RegionWatcher({ readings[it.pixels as String] ?: Reading.Empty }, translator, recorder, clock = { time })
        val offered = areas.map { (area, _) ->
            val part = crop(image, area.region)
            area to RegionWatcher.Crop(area.id, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { 1 }, part.gray, part.color)
        }
        repeat(3) {
            watcher.pass(areas.map { it.first.id }.toSet(), offered)
            time += RegionWatcher.DEFAULT_INTERVAL_MS
        }
        return areas.flatMap { recorder.current[it.first.id] ?: emptyList() }
    }

    @Test
    fun menuAndMissionScreensDrawEveryTextInItsOwnPlace() {
        val frames = JSONObject(File(directory, "frames.json").readText()).getJSONArray("frames")
        var checked = 0
        val failures = mutableListOf<String>()
        for (i in 0 until frames.length()) {
            val frame = frames.getJSONObject(i)
            val expected = frame.optJSONObject("screen") ?: continue
            val id = frame.getString("id")
            val fixture = JSONObject(File(directory, "ocr/screen/$id.json").readText())
            val image = load(File(directory, frame.getString("file")))
            val notes = mutableListOf<String>()

            // 1) "Ekranı çevir": bütün kare okunur, gruplar çevrilir.
            val whole = Dictionary()
            val read = reading(fixture.getJSONArray("lines"))
            val items = ScreenTranslation.translate(read, whole, frame = image.gray, color = image.color)
            notes += judge(items.map { Unit(it.source, it.box, it.surface?.background) }, whole, expected, image,
                read = read.lines.map { it.text }).map { "Ekranı çevir: $it" }

            // 2) Otomatik ekran yazısı: bulucunun alanları.
            val auto = Dictionary()
            val areas = fixture.getJSONArray("areas").let { list -> (0 until list.length()).map { list.getJSONObject(it) } }
            if (areas.isEmpty()) notes.add("otomatik ekran yazısı: alan bulunamadı") else {
                val watched = areas.map { area ->
                    ExtraArea(area.getString("id"), ScreenTextDetector.NAME, region(area.getJSONArray("region")), auto = true,
                        menu = area.getBoolean("menu")) to area
                }
                val autoRead = areas.flatMap { area -> reading(area.getJSONArray("lines")).lines.map { it.text } }
                notes += judge(watch(watched, image, auto), auto, expected, image, read = autoRead).map { "otomatik: $it" }
            }

            // 3) Oyunun hazır alanları: alan yazının bir kısmını keser; her bloğun bulunması beklenmez.
            val preset = Dictionary()
            val recorded = fixture.getJSONArray("presets").let { list -> (0 until list.length()).associate { list.getJSONObject(it).let { a -> a.getString("id") to a } } }
            val presets = GameAreaPresets.areas(frame.getString("game")).mapNotNull { area -> recorded[area.id]?.let { area to it } }
            notes += judge(watch(presets, image, preset), preset, expected, image, requireAll = false).map { "hazır alan: $it" }

            if (notes.isNotEmpty()) failures.add("$id: " + notes.joinToString("; "))
            checked++
        }
        assertEquals("ekran yazısı denetimli kare sayısı", 3, checked)
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private fun tokens(text: String, exact: Boolean = false) =
        (if (exact) text else text.lowercase()).split(Regex("[^\\p{L}\\p{N}&]+")).filter { it.isNotEmpty() }

    /**
     * [needle]'ın sözcükleri [haystack]'te art arda geçiyor mu. [exact]: büyük/küçük harf de aynı ("SOUVENIR" ayrıntısı
     * açıklamadaki "souvenir" sözcüğü değildir).
     */
    private fun contains(haystack: String, needle: String, exact: Boolean = false): Boolean {
        val hay = tokens(haystack, exact)
        val want = tokens(needle, exact)
        if (want.isEmpty() || hay.size < want.size) return false
        return (0..hay.size - want.size).any { hay.subList(it, it + want.size) == want }
    }

    /** 0–1 benzerlik (düzenleme uzaklığına göre). */
    private fun similarity(a: String, b: String): Double {
        val x = normalized(a)
        val y = normalized(b)
        if (x.isEmpty() || y.isEmpty()) return if (x.isEmpty() && y.isEmpty()) 1.0 else 0.0
        var previous = IntArray(y.length + 1) { it }
        for (i in 1..x.length) {
            val current = IntArray(y.length + 1)
            current[0] = i
            for (j in 1..y.length) {
                current[j] = minOf(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + if (x[i - 1] == y[j - 1]) 0 else 1)
            }
            previous = current
        }
        return 1 - previous[y.length].toDouble() / maxOf(x.length, y.length)
    }

    private fun area(box: TextBox) = maxOf(0.0, box.right - box.left) * maxOf(0.0, box.bottom - box.top)

    private fun intersection(a: TextBox, b: TextBox) =
        TextBox(maxOf(a.left, b.left), maxOf(a.top, b.top), minOf(a.right, b.right), minOf(a.bottom, b.bottom))

    private fun intersects(a: TextBox, b: TextBox) =
        minOf(a.right, b.right) > maxOf(a.left, b.left) && minOf(a.bottom, b.bottom) > maxOf(a.top, b.top)

    /** TV kutusunun kenar payı (1920×1080'de 8 piksel). */
    private fun drawn(box: TextBox) = TextBox(box.left - 8.0 / 1920, box.top - 8.0 / 1080, box.right + 8.0 / 1920, box.bottom + 8.0 / 1080)

    /** Kutunun hemen çevresindeki (yazının dışı, 8 piksel) en sık renk: özgün zemin. */
    private fun ground(image: Picture, box: TextBox): String? {
        val pad = 8
        val ix0 = (box.left * image.width).toInt()
        val ix1 = (box.right * image.width).toInt()
        val iy0 = (box.top * image.height).toInt()
        val iy1 = (box.bottom * image.height).toInt()
        val x0 = maxOf(0, ix0 - pad)
        val x1 = minOf(image.width, ix1 + pad)
        val y0 = maxOf(0, iy0 - pad)
        val y1 = minOf(image.height, iy1 + pad)
        if (x1 <= x0 || y1 <= y0) return null
        val buckets = mutableMapOf<Int, IntArray>()
        for (y in y0 until y1) for (x in x0 until x1) {
            if (x in ix0 until ix1 && y in iy0 until iy1) continue
            val c = image.rgb[y * image.width + x]
            val r = (c shr 16) and 0xff
            val g = (c shr 8) and 0xff
            val b = c and 0xff
            val bucket = buckets.getOrPut(((r / 24) shl 16) or ((g / 24) shl 8) or (b / 24)) { IntArray(4) }
            bucket[0]++; bucket[1] += r; bucket[2] += g; bucket[3] += b
        }
        val top = buckets.values.maxByOrNull { it[0] } ?: return null
        return String.format(java.util.Locale.ROOT, "#%02X%02X%02X", top[1] / top[0], top[2] / top[0], top[3] / top[0])
    }

    private fun colorDistance(a: String, b: String): Int {
        fun rgb(hex: String) = hex.drop(1).toInt(16).let { listOf((it shr 16) and 255, (it shr 8) and 255, it and 255) }
        return rgb(a).zip(rgb(b)).maxOf { abs(it.first - it.second) }
    }

    private fun short(text: String, length: Int) = text.replace("\n", " / ").take(length)

    private fun judge(
        all: List<Unit>, translator: Dictionary, expected: JSONObject, image: Picture, requireAll: Boolean = true, read: List<String>? = null,
    ): List<String> {
        val notes = mutableListOf<String>()
        // Yalnız ortası `within` alanında olan kutular denetlenir (harita kartı karesinde kartın çevresi).
        val units = expected.optJSONArray("within")?.let { values ->
            val area = box(values)
            all.filter { unit ->
                val x = (unit.box.left + unit.box.right) / 2
                val y = (unit.box.top + unit.box.bottom) / 2
                x >= area.left && x <= area.right && y >= area.top && y <= area.bottom
            }
        } ?: all
        val blocks = strings(expected.optJSONArray("blocks"))
        val keep = strings(expected.optJSONArray("keep"))
        val calls = translator.calls.map { it.first }
        // Birleşen bloklar: bir kutu iki beklenen yazıyı taşıyor.
        for (unit in units) {
            val inside = (blocks + keep).toSet().filter { contains(unit.source, it, exact = it == it.uppercase()) }.sorted()
            if (inside.size >= 2) notes.add("birleşti: " + inside.joinToString(" + ") { "\"$it\"" })
        }
        // Her blok kendi kutusunda çevrilmiş; yazı tanımanın hiç okumadığı blok aranmaz.
        val seen = { block: String -> read?.any { contains(it, block) } ?: true }
        if (requireAll) for (block in blocks) {
            if (block in keep || !seen(block)) continue
            if (units.none { similarity(it.source, block) >= 0.85 }) notes.add("ayrı kutuda yok: \"$block\"")
        }
        // Özel ad çevrilmez.
        for (name in keep) {
            if (calls.any { contains(it, name) } || units.any { contains(it.source, name) }) notes.add("özel ad çevrildi: \"$name\"")
        }
        // Görev fotoğrafı ve tuş simgesi örtülmez: kutu kenar payıyla en çok dörtte birine değebilir.
        expected.optJSONArray("clear")?.let { list ->
            for (k in 0 until list.length()) {
                val keepOut = box(list.getJSONArray(k))
                for (unit in units) if (area(intersection(drawn(unit.box), keepOut)) > 0.25 * area(keepOut)) {
                    notes.add("fotoğrafı örtüyor: \"${short(unit.source, 30)}\"")
                }
            }
        }
        // Kutular birbirine binmez.
        for (a in units.indices) for (b in a + 1 until units.size) {
            if (intersects(units[a].box, units[b].box)) notes.add("üst üste: \"${short(units[a].source, 20)}\" / \"${short(units[b].source, 20)}\"")
        }
        // Zemin özgün yazının zemini (stilsiz kutu TV'de siyah çizilir).
        for (unit in units) {
            val background = unit.background
            val actual = ground(image, unit.box)
            if (background == null || actual == null) { notes.add("stilsiz (siyah) kutu: \"${short(unit.source, 30)}\""); continue }
            if (colorDistance(background, actual) > 48) notes.add("zemin rengi $background ≠ $actual: \"${short(unit.source, 30)}\"")
        }
        return notes
    }
}
