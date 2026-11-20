// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [RegionWatcher]'ın otomatik ekran yazısı alanları: gürültü elemesi, red geri bildirimi, stil ve tur aralığı. */
class AutoAreaWatcherTest {
    private class Recorder : RegionSender {
        val sent = mutableListOf<Pair<String, String>>()
        val blocks = mutableListOf<List<ScreenTranslation.Item>?>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) =
            sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?,
            blocks: List<ScreenTranslation.Item>?,
        ) {
            sent.add(id to text)
            this.blocks.add(blocks)
        }
        override fun clearRegions() {}
    }

    private val auto = ExtraArea("auto-1", ScreenTextDetector.NAME, CropRegion(top = 0.0, bottom = 0.3, left = 0.0, right = 0.4), auto = true)

    /** Koyu kutuda beyaz yazı çizgileri: alanın okunan karesi. */
    private val crop: GrayFrame = run {
        val width = 256
        val height = 108
        GrayFrame(ByteArray(width * height) { index ->
            val x = index % width
            val y = index / width
            (if (y in 20..60 && y % 10 < 2 && x in 20..230 && x % 4 != 0) 230 else 25).toByte()
        }, width, height)
    }

    private fun signature(value: Int) = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { value.toByte() }

    @Test
    fun noiseIsRejectedAndNotTranslated() {
        val recorder = Recorder()
        val rejected = mutableListOf<String>()
        val calls = mutableListOf<String>()
        val watcher = RegionWatcher({ Reading(listOf(TextLine("$1,250", TextBox(0.1, 0.2, 0.5, 0.4)))) }, { calls.add(it); it }, recorder)
        watcher.onAutoRejected = { rejected.add(it) }
        watcher.pass(setOf(auto.id), listOf(auto to RegionWatcher.Crop(Unit, signature(1), crop)))
        assertEquals(listOf("auto-1"), rejected)
        assertTrue(calls.isEmpty())
        assertTrue(recorder.sent.isEmpty())
    }

    @Test
    fun emptyReadingIsRejected() {
        val rejected = mutableListOf<String>()
        val watcher = RegionWatcher({ Reading.Empty }, { it }, Recorder())
        watcher.onAutoRejected = { rejected.add(it) }
        watcher.pass(setOf(auto.id), listOf(auto to RegionWatcher.Crop(Unit, signature(1), crop)))
        assertEquals(listOf("auto-1"), rejected)
    }

    @Test
    fun textIsTranslatedInPlaceWithTheOriginalStyle() {
        val recorder = Recorder()
        val rejected = mutableListOf<String>()
        val lines = listOf(TextLine("Lamar has sent you a message.", TextBox(0.08, 0.18, 0.9, 0.57)))
        val watcher = RegionWatcher({ Reading(lines) }, { "Lamar sana bir mesaj gönderdi." }, recorder)
        watcher.onAutoRejected = { rejected.add(it) }
        repeat(2) { watcher.pass(setOf(auto.id), listOf(auto to RegionWatcher.Crop(Unit, signature(1), crop))) }
        assertTrue(rejected.isEmpty())
        assertEquals(listOf("auto-1" to "Lamar sana bir mesaj gönderdi."), recorder.sent)
        val block = recorder.blocks.single()!!.single()
        assertEquals("#E6E6E6", block.surface!!.foreground)
        assertEquals("#191919", block.surface!!.background)
        assertFalse(block.look!!.upper)
        // TV'ye giden olayda geriye uyumlu alanlar.
        val json = SubtitleServer.regionFrame("auto-1", "x", null, null, null, listOf(block))
        assertTrue(json, json.contains("\"surface\":{\"background\":\"#191919\",\"flat\":true,\"foreground\":\"#E6E6E6\"}"))
        assertTrue(json, json.contains("\"style\":{\"align\":\"left\",\"bold\":false,"))
    }

    @Test
    fun upperCaseOriginalGivesTurkishUpperCase() {
        val recorder = Recorder()
        val lines = listOf(TextLine("ROB VICKI'S BOSS NOW", TextBox(0.08, 0.18, 0.9, 0.57)))
        val watcher = RegionWatcher({ Reading(lines) }, { "Vicki'nin patronunu şimdi soy" }, recorder)
        repeat(2) { watcher.pass(setOf(auto.id), listOf(auto to RegionWatcher.Crop(Unit, signature(1), crop))) }
        assertEquals("VİCKİ'NİN PATRONUNU ŞİMDİ SOY", recorder.blocks.single()!!.single().translation)
    }

    @Test
    fun autoAreasAreReadEvery500ms() {
        var time = 0L
        val watcher = RegionWatcher({ Reading.Empty }, { it }, Recorder(), clock = { time })
        val run: (Runnable) -> Unit = { it.run() }
        val crop: (CropRegion) -> RegionWatcher.Crop? = { RegionWatcher.Crop(Unit, signature(1), null) }
        assertTrue(watcher.offer(listOf(auto), crop, run))
        time = 500
        assertTrue(watcher.offer(listOf(auto), crop, run))
        val user = ExtraArea("q", "Quest", ExtraAreaPreset.QUEST.region)
        // Yalnız kullanıcının alanı kalınca aralık yine saniyedir.
        time = 1500
        assertTrue(watcher.offer(listOf(user), crop, run))
        time = 2000
        assertFalse(watcher.offer(listOf(user), crop, run))
    }
}
