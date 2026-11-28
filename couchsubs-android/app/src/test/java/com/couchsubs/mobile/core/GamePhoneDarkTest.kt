// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Karanlık sahnede ve koyu ekranlı GTA 6 telefonu (X, beta.104: "telefonda parlaklık varsa çeviri oluyor karanlıksa
 * olmuyor"). Ortak deneme dosyası fixtures/phone-dark.json (core/Tests/CouchSubsCoreTests/Fixtures ile aynı; Mac/iPhone
 * GamePhoneDarkTests.swift, Windows GamePhoneDarkTests.cs aynı durumları koşar); telefonsuz karelerin karanlık hâlleri
 * phone-first-sighting.json'da (noPhone).
 */
class GamePhoneDarkTest {
    private val vectors = JSONObject(Fixtures.text("phone-dark.json"))
    private val frames = GamePhoneFirstSightingTest()

    private fun ints(array: JSONArray) = (0 until array.length()).map { array.getInt(it) }
    private fun step(name: String) = GamePhoneGeometry.Step.entries.first {
        it.name.replace("_", "").equals(name, ignoreCase = true)
    }

    @Test
    fun darkSceneGains() {
        val items = vectors.getJSONArray("gains")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val level = item.getInt("level")
            assertEquals("level $level", ints(item.getJSONArray("gains")), GamePhoneGeometry.darkGains(level))
        }
    }

    @Test
    fun darkFramesFindThePhone() {
        val items = vectors.getJSONArray("frames")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("name")
            val frame = frames.load(item.getString("frame"), item.getString("transform"))
            val search = GamePhoneGeometry.search(frame)
            assertNotNull("$name: ${search.probe}", search.pose)
            if (item.optBoolean("gain")) assertTrue("$name: ${search.probe}", search.probe.gain > 256)
            // İzleyici de iki gözlemde açar.
            val tracker = GamePhoneTracker()
            assertNull(name, tracker.sample(frame, 0).pose)
            assertNotNull(name, tracker.sample(frame, 330).pose)
        }
    }

    @Test
    fun darkScreenPreparation() {
        val items = vectors.getJSONArray("darkScreen")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("name")
            val counts = IntArray(256)
            var total = 0
            val histogram = item.getJSONArray("histogram")
            for (k in 0 until histogram.length()) {
                val pair = ints(histogram.getJSONArray(k))
                counts[pair[0]] += pair[1]
                total += pair[1]
            }
            val map = PhoneDarkScreen.mapping(counts, total)
            assertEquals(name, item.getBoolean("prepared"), map != null)
            val expected = item.optJSONArray("map") ?: continue
            for (k in 0 until expected.length()) {
                val pair = ints(expected.getJSONArray(k))
                assertEquals("$name: ${pair[0]}", pair[1], map!![pair[0]])
            }
            // Gri tonlar yerinde aynı tabloyla hazırlanır.
            val gray = ByteArray(total)
            var at = 0
            for (tone in 0 until 256) repeat(counts[tone]) { gray[at++] = tone.toByte() }
            assertTrue(name, PhoneDarkScreen.prepare(gray, total))
            assertEquals(name, map!![counts.indexOfFirst { it > 0 }], gray[0].toInt() and 0xff)
            assertEquals(name, map[counts.indexOfLast { it > 0 }], gray[total - 1].toInt() and 0xff)
        }
    }

    @Test
    fun darkMissIsLoggedWithBrightness() {
        val spec = vectors.getJSONObject("missLog")
        val frame = frames.load(spec.getString("frame"), spec.getString("transform"))
        val interval = spec.getLong("intervalMs")
        val duration = spec.getLong("durationMs")
        val log = mutableListOf<String>()
        val tracker = GamePhoneTracker()
        tracker.onLog = { log.add(it) }
        var t = 0L
        while (t <= duration) {
            assertNull(tracker.sample(frame, t).pose)
            t += interval
        }
        val missed = log.filter { it.contains("telefon ilk aramada bulunamadı") }
        assertEquals(log.toString(), 1, missed.size)
        val parts = spec.getJSONArray("contains")
        for (k in 0 until parts.length()) assertTrue(missed.toString(), missed[0].contains(parts.getString(k)))
    }

    /** Ton eşitleme eşlemesi ([GamePhoneGeometry.equalization]): her platformda aynı tonlar. */
    @Test
    fun equalizationMap() {
        val items = vectors.getJSONArray("equalization")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("name")
            val counts = IntArray(1021)
            var total = 0
            val pairs = item.getJSONArray("counts")
            for (j in 0 until pairs.length()) {
                val pair = pairs.getJSONArray(j)
                counts[pair.getInt(0)] += pair.getInt(1)
                total += pair.getInt(1)
            }
            val map = GamePhoneGeometry.equalization(counts, total)
            val expected = item.getJSONArray("map")
            for (j in 0 until expected.length()) {
                val pair = expected.getJSONArray(j)
                assertEquals("$name: ${pair.getInt(0)}", pair.getInt(1), map[pair.getInt(0)])
            }
        }
    }

    /** Ton eşitleme simsiyaha yakın karede denenmez ([GamePhoneGeometry.equalizable]): her platformda aynı. */
    @Test
    fun equalizationNeedsABrightEnd() {
        val items = vectors.getJSONArray("equalizable")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val counts = IntArray(1021)
            var total = 0
            val pairs = item.getJSONArray("counts")
            for (j in 0 until pairs.length()) {
                val pair = pairs.getJSONArray(j)
                counts[pair.getInt(0)] += pair.getInt(1)
                total += pair.getInt(1)
            }
            assertEquals(item.getString("name"), item.getBoolean("equalizable"), GamePhoneGeometry.equalizable(counts, total))
        }
    }

    /**
     * Gece, kapalı yer ve karanlık sahne: gerçek telefon karelerinin karartılmış hâlleri (parlaklık × k, gama, gece renk
     * ayarı, kararan kenarlar, koyu arka plan; kare ortalaması ~5–60/255) telefonu açar.
     */
    @Test
    fun darkVariantsOpenThePhone() {
        val items = vectors.getJSONArray("darkVariants")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("frame")
            val transforms = item.getJSONArray("transforms")
            for (j in 0 until transforms.length()) {
                val transform = transforms.getString(j)
                val frame = frames.load(name, transform)
                val tracker = GamePhoneTracker()
                var opened = false
                for (k in 0 until 3) if (tracker.sample(frame, k * 330L).pose != null) opened = true
                assertTrue("$name ($transform): ${GamePhoneGeometry.search(frame).probe}", opened)
            }
        }
    }

    /** İz benzerliği ([PhonePrint.similarity]): parlaklıktan ve karşıtlıktan bağımsız; düz ya da çok sönük iz 0. */
    @Test
    fun printSimilarity() {
        val items = vectors.getJSONArray("printSimilarity")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val a = ints(item.getJSONArray("a")).toIntArray()
            val b = ints(item.getJSONArray("b")).toIntArray()
            assertEquals(item.getString("name"), item.getDouble("similarity"), PhonePrint.similarity(a, b), 1e-6)
        }
    }

    /**
     * Telefon aydınlıkta açılır, sahne kararır (sıkı arama ıskalar): son yerindeki iziyle açık kalır, okuma sürer. Telefon
     * indirilince (telefonsuz kare) iz tutmaz, telefon her zamanki sürede kapanır.
     */
    @Test
    fun openPhoneIsHeldByItsPrint() {
        val items = vectors.getJSONArray("hold")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val name = item.getString("name")
            val open = frames.load(item.getString("frame"), "none")
            val then = frames.load(item.getString("then"), item.getString("transform"))
            val log = mutableListOf<String>()
            val tracker = GamePhoneTracker()
            tracker.onLog = { log.add(it) }
            var t = 0L
            repeat(3) {
                tracker.sample(open, t)
                t += 330
            }
            assertNotNull(name, tracker.sample(open, t).pose)
            t += 330
            val samples = item.getInt("samples")
            var last: GamePhoneGeometry.Pose? = null
            var kept = 0
            repeat(samples) {
                last = tracker.sample(then, t).pose
                if (last != null) kept++
                t += 330
            }
            if (item.getBoolean("held")) assertEquals("$name: $log", samples, kept) else assertNull("$name: $log", last)
            val parts = item.optJSONArray("log")
            if (parts != null) for (j in 0 until parts.length()) {
                val part = parts.getString(j)
                assertTrue("$name: $part yok: $log", log.any { it.contains(part) })
            }
        }
    }

    /**
     * İz telefonsuz karede telefonu tutmaz: telefon açıldıktan sonra telefonsuz gerçek kareler (karanlık hâlleriyle) gelince
     * telefon kapanır.
     */
    @Test
    fun printNeverHoldsPhoneFreeFrames() {
        val directory = frames.frames
        org.junit.Assume.assumeTrue("gerçek kare yok", directory != null)
        val spec = vectors.getJSONObject("holdNoPhone")
        val transforms = spec.getJSONArray("transforms").let { array -> (0 until array.length()).map { array.getString(it) } }
        val openerNames = spec.getJSONArray("openers")
        val openers = (0 until openerNames.length()).map { frames.load(openerNames.getString(it), "none") }
        val samples = spec.getInt("samples")
        val manifest = JSONObject(java.io.File(directory, "frames.json").readText()).getJSONArray("frames")
        val names = (0 until manifest.length()).map { manifest.getJSONObject(it) }.filter { !it.has("phone") }
            .map { it.getString("file").removeSuffix(".jpg") }.distinct()
        for (name in names) {
            val source = frames.original(name)
            GamePhoneFirstSightingTest.cache.remove(name)
            for (transform in transforms) {
                val frame = frames.transformed(source, transform)
                for ((o, opener) in openers.withIndex()) {
                    val tracker = GamePhoneTracker()
                    var t = 0L
                    repeat(3) {
                        tracker.sample(opener, t)
                        t += 330
                    }
                    var last: GamePhoneGeometry.Pose? = null
                    repeat(samples) {
                        last = tracker.sample(frame, t).pose
                        t += 330
                    }
                    assertNull("$name ($transform) telefon $o açık kaldı", last)
                }
            }
        }
    }

    @Test
    fun darkMissLineText() {
        val spec = vectors.getJSONObject("missLine")
        assertEquals(spec.getString("line"), PhoneTrace.missedFirst(
            spec.getInt("samples"), PhoneTrace.reason(step(spec.getString("furthest"))), PhoneTrace.reason(step(spec.getString("common"))),
            spec.getInt("commonCount"), spec.getInt("side"), spec.getInt("unconfirmed"), spec.getInt("strict"),
            spec.getInt("level"), spec.getInt("gain"),
        ))
    }
}
