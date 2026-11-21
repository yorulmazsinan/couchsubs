// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ekranda zaten Türkçe olan satır çevrilmez (#289; Windows: TurkishTextTests.cs, Mac/iPhone: TurkishTextTests.swift). */
class TurkishTextTest {
    private class Sender : SubtitleSender {
        val sent: MutableList<String> = Collections.synchronizedList(mutableListOf())
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) { sent.add(text) }
        override fun clear() {}
    }

    private class Regions : RegionSender {
        val sent = mutableListOf<String>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) { sent.add(text) }
        override fun clearRegions() {}
    }

    @Test fun turkishLinesAreSure() {
        for (text in listOf("Daha Sonra Güncelle", "Sistem Yazillml Güncellem€", "Lütfen bekleyin.", "Ekran görüntüsü kaydedildi",
            "Yardımcı\nolabilir miyim, efendim?", "Merchant: Yardımcı olabilir miyim, efendim?")) {
            assertTrue(text, TurkishText.isSure(text))
        }
    }

    @Test fun otherLinesAreNotSure() {
        for (text in listOf("Atatürk said we must defend the city.", "Herr Müller wants the system back online.",
            "Play Grand Theft Auto V's Story Mode.", "Kurulum sirasmda PS5 sisteminizi kapatmayn.")) {
            assertFalse(text, TurkishText.isSure(text))
        }
    }

    /** Satırı üç kare okutur, çeviriler bitene kadar bekler; motora gidenleri ve TV'ye gidenleri döndürür. */
    private fun run(line: String, skipsTurkish: Boolean = true): Pair<List<String>, List<String>> {
        val requested = Collections.synchronizedList(mutableListOf<String>())
        val sender = Sender()
        val executor = Executors.newSingleThreadExecutor()
        var now = 0L
        val pipeline = SubtitlePipeline({ requested.add(it); "TR: $it" }, sender, { now }, executor)
        pipeline.skipsTurkish = skipsTurkish
        repeat(3) {
            pipeline.process(Reading.fromText(line), CropRegion().box)
            now += 100
        }
        executor.shutdown()
        assertTrue(executor.awaitTermination(30, TimeUnit.SECONDS))
        return requested.toList() to sender.sent.toList()
    }

    @Test fun turkishLineIsNotSentToTheEngine() {
        val (requested, sent) = run("Daha Sonra Güncelle")
        assertEquals(emptyList<String>(), requested)
        assertEquals(emptyList<String>(), sent)
    }

    @Test fun englishLineWithTurkishNameIsTranslated() {
        val (requested, sent) = run("Atatürk said no.")
        assertEquals(listOf("Atatürk said no."), requested)
        assertEquals(listOf("TR: Atatürk said no."), sent)
    }

    @Test fun otherTargetLanguageTranslatesTurkish() {
        val (requested, _) = run("Daha Sonra Güncelle", skipsTurkish = false)
        assertEquals(listOf("Daha Sonra Güncelle"), requested)
    }

    private fun area(text: String): Pair<List<String>, List<String>> {
        val calls = mutableListOf<String>()
        val regions = Regions()
        var now = 0L
        val watcher = RegionWatcher({ Reading.fromText(text) }, { calls.add(it); "TR: $it" }, regions, clock = { now })
        val area = ExtraArea(id = "q", name = "Görev", region = ExtraAreaPreset.QUEST.region)
        repeat(3) {
            watcher.offer(listOf(area), { RegionWatcher.Crop(Unit, ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { 10 }) }) { it.run() }
            now += 1000
        }
        return calls to regions.sent
    }

    @Test fun turkishAreaTextIsNotTranslated() {
        val (calls, sent) = area("Sistem Yazillml Güncellem€")
        assertEquals(emptyList<String>(), calls)
        assertTrue(sent.all { it.isEmpty() })
    }

    @Test fun englishAreaTextWithTurkishNameIsTranslated() {
        val (calls, sent) = area("Atatürk said no.")
        assertEquals(listOf("Atatürk said no."), calls)
        assertEquals(listOf("TR: Atatürk said no."), sent)
    }
}
