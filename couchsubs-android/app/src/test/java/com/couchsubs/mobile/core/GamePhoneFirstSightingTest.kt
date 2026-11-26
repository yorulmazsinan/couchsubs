// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * GTA 6 telefonunun ilk açılışı (#1251, beta-102): telefon çoğu zaman hiç tanınmıyor, mesajları altyazı gibi çevriliyordu.
 * Ortak deneme dosyası fixtures/phone-first-sighting.json (core/Tests/CouchSubsCoreTests/Fixtures ile aynı; Mac/iPhone
 * GamePhoneFirstSightingTests.swift, Windows GamePhoneFirstSightingTests.cs aynı durumları koşar); gerçek kareler
 * testdata/frames.
 */
class GamePhoneFirstSightingTest {
    private val vectors = JSONObject(Fixtures.text("phone-first-sighting.json"))

    /** Gerçek kare (RGB). */
    internal class Picture(override val width: Int, override val height: Int, val pixels: IntArray) : PhoneImage {
        override fun rgb(x: Int, y: Int): Int = pixels[y * width + x]
        override fun tone(x: Int, y: Int): Int {
            val c = pixels[y * width + x]
            return 77 * ((c shr 16) and 0xff) + 150 * ((c shr 8) and 0xff) + 29 * (c and 0xff)
        }
    }

    /** Boş küçük kare (sıra denemelerinde izleyici kareye bakmaz). */
    private object Blank : PhoneImage {
        override val width = 2
        override val height = 2
        override fun rgb(x: Int, y: Int) = 0
        override fun tone(x: Int, y: Int) = 0
    }

    internal val frames: File? = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .firstOrNull { File(it, "frames.json").isFile }

    internal fun original(name: String): Picture {
        val directory = frames
        assumeTrue("gerçek kare yok", directory != null)
        val file = File(directory, "$name.jpg")
        assumeTrue("gerçek kare yok", file.isFile)
        return cache.getOrPut(name) {
            val buffered = Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java).invoke(null, file)
            val type = buffered.javaClass
            val width = type.getMethod("getWidth").invoke(buffered) as Int
            val height = type.getMethod("getHeight").invoke(buffered) as Int
            val rgb = type.getMethod("getRGB", Int::class.java, Int::class.java, Int::class.java, Int::class.java, IntArray::class.java,
                Int::class.java, Int::class.java).invoke(buffered, 0, 0, width, height, null, 0, width) as IntArray
            for (i in rgb.indices) rgb[i] = rgb[i] and 0xFFFFFF
            Picture(width, height, rgb)
        }
    }

    /**
     * Gerçek kare, ortak dosyadaki dönüşümleriyle ("+" ile birleşir: none, shiftUp, lowContrast, dark, night, gamma,
     * scale1440); [shift] [dx, dy] (0..1) verilirse görüntü sağa ve aşağı kayar (el titredi), [cover] el rengiyle örtülen
     * dikdörtgen.
     */
    internal fun load(name: String, transform: String, cover: List<Double>? = null, shift: List<Double>? = null): Picture {
        var picture = original(name)
        for (part in transform.split("+")) picture = transformed(picture, part)
        if (shift != null) picture = shifted(picture, shift[0], shift[1])
        return if (cover != null) transformed(picture, "none", cover) else picture
    }

    /** Görüntü karenin [dx]'i kadar sağa, [dy]'si kadar aşağı kayar; boşalan yer kenar pikseliyle dolar. */
    private fun shifted(source: Picture, dx: Double, dy: Double): Picture {
        val width = source.width
        val height = source.height
        val sx = (dx * width).toInt()
        val sy = (dy * height).toInt()
        return Picture(width, height, IntArray(width * height) { i ->
            source.pixels[(i / width - sy).coerceIn(0, height - 1) * width + (i % width - sx).coerceIn(0, width - 1)]
        })
    }

    /**
     * Pencereden okunan kare: görüntü 16:10 pencerede siyah şeritli (letterbox), geniş pencerede yanları siyah şeritli
     * (pillarbox) ya da üstünde açık başlık çubuğuyla (titlebar).
     */
    private fun framed(source: Picture, kind: String): Picture {
        val w = source.width
        val h = source.height
        var width = w
        var height = h
        var x = 0
        var top = 0
        when (kind) {
            "letterbox" -> {
                height = w * 10 / 16
                top = (height - h) / 2
            }
            "pillarbox" -> {
                width = w + 2 * (w / 12)
                x = w / 12
            }
            else -> {
                height = h + h / 34
                top = height - h
            }
        }
        val out = IntArray(width * height)
        if (kind == "titlebar") java.util.Arrays.fill(out, 0, top * width, (240 shl 16) or (240 shl 8) or 240)
        for (y in 0 until h) System.arraycopy(source.pixels, y * w, out, (top + y) * width + x, w)
        return Picture(width, height, out)
    }

    /** Çift doğrusal büyütme (piksel ortalarından; 1440p akış). */
    private fun resized(source: Picture, width: Int, height: Int): Picture {
        val scaleX = source.width.toDouble() / width
        val scaleY = source.height.toDouble() / height
        val out = IntArray(width * height)
        for (y in 0 until height) {
            val fy = ((y + 0.5) * scaleY - 0.5).coerceIn(0.0, source.height - 1.0)
            val y0 = fy.toInt()
            val y1 = minOf(source.height - 1, y0 + 1)
            val wy = fy - y0
            for (x in 0 until width) {
                val fx = ((x + 0.5) * scaleX - 0.5).coerceIn(0.0, source.width - 1.0)
                val x0 = fx.toInt()
                val x1 = minOf(source.width - 1, x0 + 1)
                val wx = fx - x0
                var color = 0
                for (shift in intArrayOf(16, 8, 0)) {
                    fun c(px: Int, py: Int) = (source.pixels[py * source.width + px] shr shift) and 0xff
                    val top = c(x0, y0) + (c(x1, y0) - c(x0, y0)) * wx
                    val bottom = c(x0, y1) + (c(x1, y1) - c(x0, y1)) * wx
                    color = color or (Math.round(top + (bottom - top) * wy).toInt().coerceIn(0, 255) shl shift)
                }
                out[y * width + x] = color
            }
        }
        return Picture(width, height, out)
    }

    internal fun transformed(source: Picture, transform: String, cover: List<Double>? = null): Picture {
        if (transform == "scale1440") return resized(source, 2560, 1440)
        if (transform == "scale720") return resized(source, 1280, 720)
        if (transform in setOf("letterbox", "pillarbox", "titlebar")) return framed(source, transform)
        val width = source.width
        val height = source.height
        val out = when (transform) {
            "none" -> source.pixels.copyOf()
            "shiftUp" -> {
                val shift = height / 12
                IntArray(width * height) { i -> source.pixels[minOf(height - 1, i / width + shift) * width + i % width] }
            }
            "lowContrast", "dark", "night", "gamma" -> IntArray(width * height) { i ->
                val c = source.pixels[i]
                fun tone(v: Int) = when (transform) {
                    "dark" -> v * 6 / 10
                    "night" -> v * 35 / 100
                    "gamma" -> (255 * Math.pow(v / 255.0, 2.2)).toInt()
                    else -> 128 + (v - 128) * 6 / 10
                }.coerceIn(0, 255)
                (tone((c shr 16) and 0xff) shl 16) or (tone((c shr 8) and 0xff) shl 8) or tone(c and 0xff)
            }
            else -> error(transform)
        }
        if (cover != null) {
            val left = (cover[0] * width).toInt()
            val top = (cover[1] * height).toInt()
            val right = (cover[2] * width).toInt()
            val bottom = (cover[3] * height).toInt()
            for (y in top until bottom) for (x in left until right) out[y * width + x] = (196 shl 16) or (140 shl 8) or 110
        }
        return Picture(width, height, out)
    }

    private fun doubles(array: JSONArray) = (0 until array.length()).map { array.getDouble(it) }
    private fun pose(array: JSONArray) = doubles(array).let { GamePhoneGeometry.Pose(it[0], it[1], it[2], it[3]) }
    private fun expected(sequence: JSONObject): Int? = if (sequence.isNull("opensAt")) null else sequence.getInt("opensAt")

    @Test
    fun sequencesOpenTheSameWayOnEveryPlatform() {
        val fallback = pose(vectors.getJSONArray("defaultPose"))
        val sequences = vectors.getJSONArray("sequences")
        for (s in 0 until sequences.length()) {
            val sequence = sequences.getJSONObject(s)
            val name = sequence.getString("name")
            var next: Pair<GamePhoneGeometry.Pose, Boolean>? = null
            val tracker = GamePhoneTracker.sighting { next }
            var opened: Int? = null
            val samples = sequence.getJSONArray("samples")
            for (i in 0 until samples.length()) {
                val sample = samples.getJSONObject(i)
                val place = sample.optJSONArray("pose")?.let(::pose) ?: fallback
                next = when (sample.getString("kind")) {
                    "strict" -> place to true
                    "weak" -> place to false
                    else -> null
                }
                val result = tracker.sample(Blank, sample.getLong("t"))
                assertTrue(name, result.sampled)
                if (result.pose != null && opened == null) opened = i
            }
            assertEquals(name, expected(sequence), opened)
        }
    }

    @Test
    fun realFramesFromTheLogOpenThePhone() {
        val sequences = vectors.getJSONArray("frames")
        for (s in 0 until sequences.length()) {
            val sequence = sequences.getJSONObject(s)
            val name = sequence.getString("name")
            val tracker = GamePhoneTracker()
            var opened: Int? = null
            var closedAfterOpening = false
            val samples = sequence.getJSONArray("samples")
            for (i in 0 until samples.length()) {
                val sample = samples.getJSONObject(i)
                val frame = load(sample.getString("frame"), sample.getString("transform"), sample.optJSONArray("cover")?.let(::doubles),
                    sample.optJSONArray("shift")?.let(::doubles))
                val open = tracker.sample(frame, sample.getLong("t")).pose != null
                if (open && opened == null) opened = i
                if (!open && opened != null) closedAfterOpening = true
            }
            assertEquals(name, expected(sequence), opened)
            if (sequence.optBoolean("staysOpen")) assertFalse("$name: telefon kapandı", closedAfterOpening)
        }
    }

    /** Telefonsuz gerçek kareler (frames.json'da telefon işareti olmayanlar) hiçbir dönüşümde telefon açmaz, aday da olmaz. */
    @Test
    fun framesWithoutPhoneNeverOpenOrHoldIt() {
        val directory = frames
        assumeTrue("gerçek kare yok", directory != null)
        val noPhone = vectors.getJSONObject("noPhone")
        val transforms = noPhone.getJSONArray("transforms").let { array -> (0 until array.length()).map { array.getString(it) } }
        val samples = noPhone.getInt("samples")
        val manifest = JSONObject(File(directory, "frames.json").readText()).getJSONArray("frames")
        val names = (0 until manifest.length()).map { manifest.getJSONObject(it) }.filter { !it.has("phone") }
            .map { it.getString("file").removeSuffix(".jpg") }.distinct()
        assertTrue(names.size > 50)
        for (name in names) {
            val source = original(name)
            cache.remove(name)
            for (transform in transforms) {
                val frame = transformed(source, transform)
                val tracker = GamePhoneTracker()
                for (i in 0 until samples) assertNull("$name ($transform): telefon açıldı", tracker.sample(frame, i * 330L).pose)
                val search = ScreenPhoneCard.search(frame)
                assertNull("$name ($transform): telefon", search.phone)
                assertNull("$name ($transform): telefon adayı", search.candidate)
            }
        }
    }

    @Test
    fun subtitleFilterHoldsTheCandidateAndConfirmsItInPlace() {
        val items = vectors.getJSONArray("candidates")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("name")
            val frame = load(item.getString("frame"), item.getString("transform"))
            val search = ScreenPhoneCard.search(frame)
            assertNull(name, search.phone)
            val candidate = search.candidate
            assertNotNull("$name: aday yok", candidate)
            assertNotNull("$name: adayın yerinde telefon doğrulanmadı", ScreenPhoneCard.phone(frame, candidate))
        }
    }

    @Test
    fun missedFirstSightingIsLoggedOncePerWindow() {
        val spec = vectors.getJSONObject("missLog")
        val frame = load(spec.getString("frame"), spec.getString("transform"))
        val interval = spec.getLong("intervalMs")
        val duration = spec.getLong("durationMs")
        val log = mutableListOf<String>()
        var tracker = GamePhoneTracker().apply { onLog = { log.add(it) } }
        var t = 0L
        while (t <= duration) {
            tracker.sample(frame, t)
            t += interval
        }
        val missed = log.filter { "telefon ilk aramada bulunamadı" in it }
        assertEquals(log.toString(), 1, missed.size)
        val contains = spec.getJSONArray("contains")
        for (i in 0 until contains.length()) assertTrue(missed[0], contains.getString(i) in missed[0])

        // Telefonsuz oyunda (aramalar hoparlör yarığında kalır) satır yazılmaz.
        log.clear()
        val empty = load("gta6-01-lucia", "none")
        tracker = GamePhoneTracker().apply { onLog = { log.add(it) } }
        t = 0L
        while (t <= duration) {
            tracker.sample(empty, t)
            t += interval
        }
        assertEquals(emptyList<String>(), log)
    }

    @Test
    fun missedFirstLineNamesTheCriterion() {
        assertEquals("telefon ilk aramada bulunamadı (61 arama): en ileri ölçüt yan kenarlar zayıf, en sık yan kenarlar zayıf (61), " +
            "en iyi aday yan gücü 3/12, doğrulanmayan gözlem 1 (1 sıkı)",
            PhoneTrace.missedFirst(61, PhoneTrace.reason(GamePhoneGeometry.Step.SIDES), PhoneTrace.reason(GamePhoneGeometry.Step.SIDES),
                61, 3, 1, 1))
        assertEquals("telefon ilk aramada bulunamadı (5 arama): en ileri ölçüt ön kamera yok, en sık hoparlör yarığı yok (4), " +
            "doğrulanmayan gözlem 0 (0 sıkı)",
            PhoneTrace.missedFirst(5, PhoneTrace.reason(GamePhoneGeometry.Step.NO_CAMERA), PhoneTrace.reason(GamePhoneGeometry.Step.NO_TOP_SLOT),
                4, -1, 0, 0))
    }

    /** Altyazı hattının adayı: ilk görüldüğü an yakınında korunur, satırlar CANDIDATE_HOLD_MS boyunca bekletilir. */
    @Test
    fun candidateHoldIsShortAndDoesNotExtendItself() {
        val weak = ScreenPhoneCard.search(load("gta6-telefon-sohbet-2", "shiftUp")).candidate
        assertNotNull(weak)
        val (first, since) = SubtitlePipeline.candidate(weak, null, 0L, 1000L)
        assertEquals(weak, first)
        assertEquals(1000L, since)
        assertEquals(1000L, SubtitlePipeline.candidate(weak, first, since, 1330L).second)
        assertTrue(SubtitlePipeline.holdsCandidate(first, since, 1000L + SubtitlePipeline.CANDIDATE_HOLD_MS - 1))
        assertFalse(SubtitlePipeline.holdsCandidate(first, since, 1000L + SubtitlePipeline.CANDIDATE_HOLD_MS))
        assertEquals(null to 0L, SubtitlePipeline.candidate(null, first, since, 1660L))
        assertFalse(SubtitlePipeline.holdsCandidate(null, 0L, 10L))
    }

    private companion object {
        val cache = mutableMapOf<String, Picture>()
    }
}
