// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Okuma kırıntısı ve tek sözcük bozulması (GitHub #854, #882; GTA 6): HUD kırıntısı görev sayılmaz, konuşmanın üstünde
 * beliren kırıntı konuşmayı attırmaz, ilk karede bozuk okunan sözcük doğru okununca yeniden çevrilir. Kurallar ortak deneme
 * dosyasından (fixtures/ocr-crumbs.json, core/Tests/CouchSubsCoreTests/Fixtures kopyası; Mac OcrCrumbsTests.swift ve
 * Windows OcrCrumbsTests.cs aynı dosyayı okur).
 */
class OcrCrumbsTest {
    private val root = JSONObject(Fixtures.text("ocr-crumbs.json"))

    private fun objects(name: String) = root.getJSONArray(name).let { array -> (0 until array.length()).map { array.getJSONObject(it) } }

    private fun strings(array: JSONArray) = (0 until array.length()).map { array.getString(it) }

    @Test fun crumbs() {
        for (vector in objects("crumb")) {
            val text = vector.getString("text")
            assertEquals(text, vector.getBoolean("crumb"), OcrNoise.isCrumb(text))
        }
    }

    @Test fun symbolOnlyTokensAreDropped() {
        for (vector in objects("clean")) assertEquals(vector.getString("out"), OcrNoise.clean(vector.getString("in")))
    }

    @Test fun nonWords() {
        for (vector in objects("nonWord")) {
            val word = vector.getString("word")
            assertEquals(word, vector.getBoolean("nonWord"), OcrNoise.isNonWord(word))
        }
    }

    @Test fun missionCandidates() {
        for (vector in objects("mission")) {
            val text = vector.getString("text")
            val b = vector.getJSONArray("box")
            val box = TextBox(b.getDouble(0), b.getDouble(1), b.getDouble(2), b.getDouble(3))
            assertEquals(text, vector.getBoolean("candidate"), MissionLine.isCandidate(text, box))
        }
    }

    @Test fun stickyRowsKeepDialogueUnderCrumb() {
        for (vector in objects("stickyRows")) {
            val rows = StickyRows()
            var kept = Reading(emptyList())
            val steps = vector.getJSONArray("steps")
            for (i in 0 until steps.length()) {
                val step = steps.getJSONObject(i)
                kept = rows.filter(Reading(strings(step.getJSONArray("lines")).map { TextLine(it) }), step.getLong("time"))
            }
            assertEquals(vector.getString("name"), strings(vector.getJSONArray("kept")), kept.lines.map { it.text })
        }
    }

    @Test fun stabilizerCorrections() {
        for (vector in objects("stabilizer")) {
            val name = vector.getString("name")
            val source = vector.getString("sent")
            var time = 0L
            val stabilizer = SubtitleStabilizer(clock = { time })
            var sent = false
            repeat(vector.getInt("sentReads")) {
                val action = stabilizer.feed(source)
                if (action.kind == StabilizerKind.TRANSLATE) {
                    assertEquals(name, source, action.text)
                    sent = true
                }
                time += 100
            }
            assertTrue(name, sent)
            val translated = mutableListOf<String>()
            for (read in strings(vector.getJSONArray("reads"))) {
                val action = stabilizer.feed(read)
                if (action.kind == StabilizerKind.TRANSLATE) translated.add(action.text!!)
                time += 100
            }
            assertEquals(name, strings(vector.getJSONArray("translated")), translated)
        }
    }
}
