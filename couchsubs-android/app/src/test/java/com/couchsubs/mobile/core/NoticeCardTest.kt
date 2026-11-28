// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.io.File
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GitHub #1443 (X'te başkaları da: "sağ alt mesajlar çevrilmiyor"): GTA 6'nın sağ alttaki açık bildirim kartının yalnız
 * başlığı çevriliyor, gövdesi "koyu yazı açık zeminde (kâğıt/tabela)" sayılıp atılıyordu. Örnekler ortak deneme
 * dosyasından (fixtures/notice-card.json, core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac NoticeCardTests.swift ve
 * Windows NoticeCardTests.cs aynı dosyayı okur): gerçek kare gta6-n4-bildirim (kayıtlı okuması, alt şerit alanı kartı
 * kesiyor), kayıtlı okuması olan öteki bütün gerçek kareler (kart yok) ve kullanıcının fotoğrafındaki kartın ölçüleriyle
 * sentetik kare.
 */
class NoticeCardTest {
    private val vectors = JSONObject(Fixtures.text("notice-card.json"))
    private val tolerance = vectors.getDouble("tolerance")
    private val synthetic = vectors.getJSONObject("synthetic")
    private val width = synthetic.getInt("width")
    private val height = synthetic.getInt("height")

    private fun numbers(values: JSONArray) = (0 until values.length()).map { values.getDouble(it) }
    private fun box(values: JSONArray) = numbers(values).let { TextBox(it[0], it[1], it[2], it[3]) }

    private val frames: File = generateSequence(File(System.getProperty("user.dir")!!).absoluteFile) { it.parentFile }
        .map { File(it, "testdata/frames") }
        .first { File(it, "frames.json").isFile }

    /** Kayıtlı okuma ve alanı (testdata/frames/ocr); yoksa null. */
    private fun recorded(id: String): Pair<Reading, TextBox>? {
        val file = File(frames, "ocr/$id.json")
        if (!file.isFile) return null
        val json = JSONObject(file.readText())
        if (!json.has("region")) return null
        val lines = json.getJSONArray("lines")
        return Reading((0 until lines.length()).map {
            val line = lines.getJSONObject(it)
            TextLine(line.getString("text"), box(line.getJSONArray("box")), confidence = 1f)
        }) to box(json.getJSONArray("region"))
    }

    /** Kare, masaüstü JDK'nın ImageIO'suyla (Android sınıf yolunda yok; test JVM'inde var): eni, boyu ve parlaklığı. */
    private fun luma(file: File): Triple<Int, Int, IntArray> {
        val buffered = Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java).invoke(null, file)
        val type = buffered.javaClass
        val w = type.getMethod("getWidth").invoke(buffered) as Int
        val h = type.getMethod("getHeight").invoke(buffered) as Int
        val rgb = type.getMethod("getRGB", Int::class.java, Int::class.java, Int::class.java, Int::class.java, IntArray::class.java,
            Int::class.java, Int::class.java).invoke(buffered, 0, 0, w, h, null, 0, w) as IntArray
        return Triple(w, h, IntArray(rgb.size) {
            val c = rgb[it]
            (299 * ((c shr 16) and 0xFF) + 587 * ((c shr 8) and 0xFF) + 114 * (c and 0xFF)) / 1000
        })
    }

    private fun finder(file: File): (TextBox) -> TextBox? {
        val (w, h, values) = luma(file)
        return { box -> NoticeCard.bounds(box, w, h) { x, y -> values[y * w + x] } }
    }

    private fun assertClose(got: TextBox?, want: JSONArray, name: String) {
        assertNotNull("$name: kart bulunmadı", got)
        val g = listOf(got!!.left, got.top, got.right, got.bottom)
        for ((a, b) in g.zip(numbers(want))) assertEquals("$name: $g", b, a, tolerance)
    }

    @Test
    fun realNotificationCardIsFoundWhole() {
        val real = vectors.getJSONArray("real")
        for (i in 0 until real.length()) {
            val item = real.getJSONObject(i)
            val name = item.getString("frame")
            val (reading, area) = recorded(name)!!
            val split = NoticeCard.split(reading, area, finder(File(frames, "$name.jpg")))
            assertEquals(name, 1, split.cards.size)
            assertClose(split.cards[0].second, item.getJSONArray("card"), name)
            val texts = item.getJSONArray("texts").let { t -> (0 until t.length()).map { t.getString(it) } }
            assertEquals(name, texts, split.cards[0].first.lines.map { it.text })
            assertTrue(name, split.kept.lines.none { it.text in texts })
        }
    }

    /** Kayıtlı okuması olan öteki gerçek karelerde (konuşma, kâğıt ilan, tabela, kitap, tişört, telefon, menü) kart yoktur. */
    @Test
    fun noOtherRealFrameHasACard() {
        val real = vectors.getJSONArray("real")
        val cards = (0 until real.length()).map { real.getJSONObject(it).getString("frame") }.toSet()
        var checked = 0
        for (file in frames.listFiles { f -> f.name.endsWith(".jpg") }!!.sortedBy { it.name }) {
            val name = file.name.removeSuffix(".jpg")
            if (name in cards) continue
            val (reading, area) = recorded(name) ?: continue
            val split = NoticeCard.split(reading, area, finder(file))
            assertTrue("$name: ${split.cards.map { it.first.text }}", split.cards.isEmpty())
            assertSame(name, reading, split.kept)
            checked++
        }
        assertTrue("$checked", checked > 30)
    }

    /** Sentetik parlaklık (ortak dosyadaki formül). */
    private fun luma(x: Int, y: Int, shift: Double, invert: Boolean): Int {
        val fx = (x + 0.5) / width - shift
        val fy = (y + 0.5) / height
        fun inside(r: JSONArray) = numbers(r).let { fx >= it[0] && fx < it[2] && fy >= it[1] && fy < it[3] }
        if (!inside(synthetic.getJSONArray("card"))) return 110 + (x * 37 + y * 91 + (x * y) % 53) % 90
        val ground = if (invert) 40 else 236
        val ink = if (invert) 236 else 40
        if (inside(synthetic.getJSONArray("icon"))) return 130
        val rows = synthetic.getJSONArray("rows")
        if ((0 until rows.length()).any { inside(rows.getJSONArray(it)) } && (x / 3) % 2 == 0) return ink
        return ground
    }

    private fun lumas(shift: Double, invert: Boolean) = IntArray(width * height) { luma(it % width, it / width, shift, invert) }

    private fun lineBoxes() = synthetic.getJSONArray("lines").let { lines -> (0 until lines.length()).map { lines.getJSONObject(it) } }

    @Test
    fun syntheticCases() {
        val body = lineBoxes().take(4).map { box(it.getJSONArray("box")) }.reduce { a, b -> a.union(b) }
        val cases = synthetic.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val item = cases.getJSONObject(i)
            val name = item.getString("name")
            val shift = item.getDouble("shift")
            val values = lumas(shift, item.getBoolean("invert"))
            val shifted = TextBox(body.left + shift, body.top, body.right + shift, body.bottom)
            val found = NoticeCard.bounds(shifted, width, height) { x, y -> values[y * width + x] }
            if (item.isNull("card")) assertNull(name, found) else assertClose(found, item.getJSONArray("card"), name)
        }
    }

    /**
     * Kartın bölgesi kartın kendisidir; kart [ScreenNotices.SETTLE_MS] yerinde durunca gelir, küçük oynamada bölge
     * değişmez, kart görünmeyince [ScreenNotices.FORGET_MS] sonra kalkar.
     */
    @Test
    fun noticesTrackCardsWithTheWholeCardAsRegion() {
        val notices = ScreenNotices()
        val card = TextBox(0.68, 0.63, 0.96, 0.93)
        val settle = ScreenNotices.SETTLE_MS.toLong()
        val forget = ScreenNotices.FORGET_MS.toLong()
        assertFalse(notices.observe(emptyList(), 0, listOf(card)))
        assertTrue(notices.observe(emptyList(), settle, listOf(card)))
        assertEquals(listOf("auto-notice-1"), notices.areas.map { it.id })
        assertEquals(CropRegion(top = 0.63, bottom = 0.93, left = 0.68, right = 0.96), notices.areas[0].region)
        assertFalse(notices.observe(emptyList(), settle + 100, listOf(TextBox(0.682, 0.631, 0.958, 0.93))))
        assertFalse(notices.observe(emptyList(), settle + 100 + forget))
        assertTrue(notices.observe(emptyList(), settle + 101 + forget))
        assertEquals(emptyList<ExtraArea>(), notices.areas)
    }

    private class Sender : SubtitleSender {
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {}
        override fun clear() {}
    }

    /**
     * Kullanıcının durumu (#1443): alt şerit altyazı alanı kartı kesiyor, gövde koyu yazı. Kart açıkken (GTA 6, ekran yazısı
     * ya da telefon çevirisi) gövde altyazıya girmez, kâğıt/tabela diye de atılmaz; kartın tamamı "auto-notice-1" olur.
     * Aynı karedeki konuşma altyazı olarak çevrilir. Kart kapalıyken eski davranış (kart bildirimi yok).
     */
    @Test
    fun pipelineRoutesTheCardToANoticeBeforeTheDarkInkRule() {
        val area = box(synthetic.getJSONArray("area"))
        val aw = area.right - area.left
        val ah = area.bottom - area.top
        val reading = Reading(lineBoxes().map { line ->
            val b = box(line.getJSONArray("box"))
            TextLine(line.getString("text"), TextBox((b.left - area.left) / aw, (b.top - area.top) / ah,
                (b.right - area.left) / aw, (b.bottom - area.top) / ah), confidence = 1f)
        })
        val values = lumas(0.0, false)
        // Video Y düzlemi gibi sınırlı aralık (16–235); sampler geri çevirir.
        val grid = NoticeCard.grid(width, height) { x, y -> 16 + values[y * width + x] * 219 / 255 }
        val cardTexts = synthetic.getJSONArray("cardTexts").let { t -> (0 until t.length()).map { t.getString(it) } }
        for (cards in listOf(true, false)) {
            val requested = Collections.synchronizedList(mutableListOf<String>())
            val log = Collections.synchronizedList(mutableListOf<String>())
            var areas: List<ExtraArea> = emptyList()
            val executor = Executors.newSingleThreadExecutor()
            var now = 1_000_000L
            val pipeline = SubtitlePipeline({ requested.add(it); "TR: $it" }, Sender(), { now }, executor)
            pipeline.lightInkGame = true
            pipeline.onLog = { log.add(it) }
            pipeline.onNoticesChanged = { areas = it }
            repeat(20) {
                pipeline.process(reading, area, noticeCard = if (cards) NoticeCard.sampler(grid) else null)
                now += 100
            }
            executor.shutdown()
            assertTrue(executor.awaitTermination(30, TimeUnit.SECONDS))
            val joined = log.joinToString("\n")
            assertFalse(joined, requested.any { text -> cardTexts.any { text.contains(it) } })
            if (cards) {
                // Kart ayrılınca konuşma kendi başına altyazıdır (önceden kartın satırlarıyla birlikte menü listesi sanılıyordu).
                val subtitle = synthetic.getString("subtitle").removePrefix("Lucia: ")
                assertTrue(joined, requested.any { it.contains(subtitle) })
                assertEquals(joined, listOf("auto-notice-1"), areas.map { it.id })
                val r = areas[0].region
                val want = synthetic.getJSONArray("card")
                assertClose(TextBox(r.left, r.top, r.right, r.bottom), want, "hat")
                assertFalse(joined, log.any { it.contains(InkTone.REASON) && it.contains("from a chop") })
                assertTrue(joined, log.any { it.contains("bildirim kartı:") && it.contains("from a chop") })
            } else {
                assertEquals(joined, emptyList<ExtraArea>(), areas)
            }
        }
    }
}
