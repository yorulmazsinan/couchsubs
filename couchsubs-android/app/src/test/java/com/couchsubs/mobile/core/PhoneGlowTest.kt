// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1443 (beta-108): GTA 6 telefonu karanlık sahnede ~1 sn'de bir kapanıp açılıyor, her kapanışta kutuları siliniyor, görev
 * satırı yolu telefonun mesajlarını okuyordu. Telefon karanlıkta ekranının ışığıyla tutulur ([PhoneGlow]), gerçekten
 * indirilince her zamanki sürede kapanır; telefon açıkken başka yolların telefonun alanındaki satırları bastırılır
 * ([PhoneShield]). Ortak deneme dosyası fixtures/phone-glow.json (core/Tests/CouchSubsCoreTests/Fixtures ile aynı;
 * Mac/iPhone PhoneGlowTests.swift, Windows PhoneGlowTests.cs aynı durumları koşar).
 */
class PhoneGlowTest {
    private val vectors = JSONObject(Fixtures.text("phone-glow.json"))
    private val frames = GamePhoneFirstSightingTest()

    private fun doubles(array: JSONArray) = (0 until array.length()).map { array.getDouble(it) }
    private fun glow(array: JSONArray) = doubles(array).let { PhoneGlow.Glow(it[0], it[1]) }
    private fun region(v: List<Double>) = CropRegion(top = v[1], bottom = v[3], left = v[0], right = v[2])
    private fun box(v: List<Double>) = TextBox(v[0], v[1], v[2], v[3])

    @Test
    fun glowHoldsOnlyALitScreenInTheDark() {
        val items = vectors.getJSONArray("holds")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("name")
            val recorded = glow(item.getJSONArray("recorded"))
            val current = glow(item.getJSONArray("current"))
            assertEquals(name, item.getBoolean("lit"), PhoneGlow.lit(current))
            assertEquals(name, item.getBoolean("holds"), PhoneGlow.holds(recorded, current))
        }
    }

    /** Sentetik kare: her yer [background], ekran kutusu [screen] tonunda (null: ekran yok). */
    private fun scene(width: Int, height: Int, background: Int, screen: Int?, box: List<Double>): GamePhoneFirstSightingTest.Picture {
        val left = Math.round(box[0] * width).toInt()
        val top = Math.round(box[1] * height).toInt()
        val right = Math.round(box[2] * width).toInt()
        val bottom = Math.round(box[3] * height).toInt()
        fun gray(tone: Int) = (tone shl 16) or (tone shl 8) or tone
        val pixels = IntArray(width * height) { i ->
            val x = i % width
            val y = i / width
            gray(if (screen != null && x >= left && x < right && y >= top && y < bottom) screen else background)
        }
        return GamePhoneFirstSightingTest.Picture(width, height, pixels)
    }

    @Test
    fun darkPhoneIsHeldByItsScreenAndClosesWhenLowered() {
        val scene = vectors.getJSONObject("scene")
        val width = scene.getInt("width")
        val height = scene.getInt("height")
        val p = doubles(scene.getJSONArray("pose"))
        val screenBox = doubles(scene.getJSONArray("screenBox"))
        val pose = GamePhoneGeometry.Pose(p[0], p[1], p[2], p[3])
        val sequences = vectors.getJSONArray("sequences")
        for (i in 0 until sequences.length()) {
            val sequence = sequences.getJSONObject(i)
            val name = sequence.getString("name")
            val background = sequence.getInt("background")
            val screen = sequence.getInt("screen")
            val opener = scene(width, height, background, screen, screenBox)
            val tracker = GamePhoneTracker({ image, _ ->
                GamePhoneTracker.Sighting(if (image === opener) pose else null, true, null)
            }, Unit).apply { glows = true }
            val log = mutableListOf<String>()
            tracker.onLog = { log.add(it) }
            var t = 0L
            var open = false
            repeat(sequence.getInt("open")) {
                open = tracker.sample(opener, t).pose != null
                t += GamePhoneTracker.INTERVAL_MS
            }
            assertTrue("$name: telefon açılmadı", open)
            val parts = sequence.getJSONArray("then")
            for (j in 0 until parts.length()) {
                val part = parts.getJSONObject(j)
                val lit = part.getString("frame") == "lit"
                val image = scene(width, height, part.optInt("background", background),
                    if (lit) part.optInt("screen", screen) else null, screenBox)
                for (k in 0 until part.getInt("samples")) {
                    open = tracker.sample(image, t).pose != null
                    t += GamePhoneTracker.INTERVAL_MS
                    if (part.optBoolean("openAll")) assertTrue("$name: ${k + 1}. örnekte kapandı", open)
                }
                if (part.has("openAtEnd")) assertEquals("$name: parçanın sonunda", part.getBoolean("openAtEnd"), open)
            }
            val text = log.joinToString("\n")
            sequence.optJSONArray("log")?.let { needles ->
                for (k in 0 until needles.length()) assertTrue("$name: günlükte yok: ${needles.getString(k)}\n$text", text.contains(needles.getString(k)))
            }
            sequence.optJSONArray("noLog")?.let { needles ->
                for (k in 0 until needles.length()) assertFalse("$name: günlükte var: ${needles.getString(k)}", text.contains(needles.getString(k)))
            }
        }
    }

    /**
     * Gerçek karanlık oda karesinde telefonun ekranı ışıklı sayılır; telefonsuz gerçek karelerin aynı yerinde ışık o kaydı
     * tutmaz (telefon indirilince ışıkla açık kalmaz).
     */
    @Test
    fun realDarkRoomScreenIsLitAndNoPhoneFrameHoldsIt() {
        val spec = vectors.getJSONObject("realFrame")
        val phone = frames.load(spec.getString("frame"), spec.getString("transform"))
        val pose = GamePhoneGeometry.locate(phone)
        assertNotNull(pose)
        val recorded = GamePhoneGeometry.glow(phone, pose!!)
        assertTrue("$recorded", recorded != null && PhoneGlow.lit(recorded))
        val directory = frames.frames!!
        val manifest = JSONObject(java.io.File(directory, "frames.json").readText()).getJSONArray("frames")
        val names = (0 until manifest.length()).map { manifest.getJSONObject(it) }.filter { !it.has("phone") }
            .map { it.getString("file").removeSuffix(".jpg") }.distinct()
        val transforms = spec.getJSONArray("transforms").let { array -> (0 until array.length()).map { array.getString(it) } }
        for (name in names) {
            val source = frames.original(name)
            GamePhoneFirstSightingTest.cache.remove(name)
            for (transform in transforms) {
                val current = GamePhoneGeometry.glow(frames.transformed(source, transform), pose)
                assertNotNull(name, current)
                assertFalse("$name ($transform): $current", PhoneGlow.holds(recorded!!, current!!))
            }
        }
    }

    /**
     * Altyazı hattının kendi telefon takibi de karanlıkta ekran ışığıyla tutulur (izleyiciyle aynı eşikler ve süre): tutulan
     * telefonun satırları altyazı sayılmaz; telefon indirilince her zamanki gibi kalkar.
     */
    @Test
    fun subtitlePipelineHoldsTheDarkPhoneByItsScreen() {
        val p = doubles(vectors.getJSONObject("scene").getJSONArray("pose"))
        val pose = GamePhoneGeometry.Pose(p[0], p[1], p[2], p[3])
        val handset = ScreenPhoneCard.Handset(pose, 16.0 / 9)
        val sequences = vectors.getJSONArray("subtitle")
        for (i in 0 until sequences.length()) {
            val sequence = sequences.getJSONObject(i)
            val name = sequence.getString("name")
            val keeper = PhoneGlowKeeper()
            var shown: ScreenPhoneCard.Handset? = null
            var misses = 0
            var t = 0L
            var step = 0
            val steps = sequence.getJSONArray("steps")
            for (j in 0 until steps.length()) {
                val item = steps.getJSONObject(j)
                val found = item.getBoolean("found")
                val glow = if (item.isNull("glow")) null else glow(item.getJSONArray("glow"))
                repeat(item.optInt("repeat", 1)) {
                    val result = keeper.observe(if (found) pose else null, shown?.pose, t) { glow }
                    val (next, count) = SubtitlePipeline.heldPhone(if (found) handset else null, shown, misses, result.holds)
                    shown = next
                    misses = count
                    step++
                    assertEquals("$name: $step. arama", item.getBoolean("open"), shown != null)
                    t += GamePhoneTracker.INTERVAL_MS
                }
            }
        }
    }

    @Test
    fun shieldDropsOtherRoutesLinesOnThePhone() {
        val items = vectors.getJSONArray("shield")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("name")
            val lineItems = item.getJSONArray("lines")
            val lines = (0 until lineItems.length()).map { lineItems.getJSONObject(it) }.map { line ->
                TextLine(line.getString("text"), if (line.isNull("box")) null else box(doubles(line.getJSONArray("box"))))
            }
            val phone = if (item.isNull("phone")) null else region(doubles(item.getJSONArray("phone")))
            val result = PhoneShield.filter(Reading(lines), region(doubles(item.getJSONArray("region"))), phone)
            val keptItems = item.getJSONArray("kept")
            val kept = (0 until keptItems.length()).map { keptItems.getString(it) }
            assertEquals(name, kept, result.kept.lines.map { it.text })
            assertEquals(name, lines.size - kept.size, result.dropped)
        }
        val covers = vectors.getJSONArray("covers")
        for (i in 0 until covers.length()) {
            val item = covers.getJSONObject(i)
            assertEquals(item.getBoolean("covers"),
                PhoneShield.covers(box(doubles(item.getJSONArray("box"))), region(doubles(item.getJSONArray("phone")))))
        }
    }
}
