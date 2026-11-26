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
