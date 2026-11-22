// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/**
 * X'te iki kişi: diyalogda her altyazı iki kez çıkıyor, önce beyaz (adsız), sonra adıyla renkli. Renkli konuşan adı ilk
 * karelerde okunamıyor, cümle adsız çevrilip gösteriliyor; ad okununca aynı cümle yeni satır sayılıp yeniden çevriliyordu
 * (Mac/iPhone: SpeakerReadLateTests.swift, Windows: SpeakerReadLateTests.cs).
 */
class SpeakerReadLateTest {
    private class Result(val requested: List<String>, val sent: List<String>, val replaces: List<Boolean>)

    private fun replay(frames: List<String>, open: Boolean = true, showNames: Boolean = true): Result {
        val executor = Executors.newSingleThreadExecutor()
        val release = CountDownLatch(if (open) 0 else 1)
        val started = CountDownLatch(1)
        val requested = Collections.synchronizedList(mutableListOf<String>())
        val sent = Collections.synchronizedList(mutableListOf<String>())
        val replaced = Collections.synchronizedList(mutableListOf<Boolean>())
        val translator = object : TextTranslator {
            override fun translate(text: String): String {
                requested.add(text); started.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                return "Çeviri ${requested.size}."
            }
        }
        val sender = object : SubtitleSender {
            override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
                sent.add(text); replaced.add(replaces)
            }
            override fun clear() {}
        }
        var time = 0L
        val pipeline = SubtitlePipeline(translator, sender, { time }, executor).apply { showSpeakerNames = { showNames } }
        try {
            frames.forEachIndexed { index, text ->
                pipeline.process(Reading.fromText(text), CropRegion().box)
                if (open) executor.submit {}.get(5, TimeUnit.SECONDS)
                else if (index == 0) assertTrue(started.await(5, TimeUnit.SECONDS))
                time += 150
            }
            release.countDown(); executor.submit {}.get(5, TimeUnit.SECONDS)
            return Result(requested.toList(), sent.toList(), replaced.toList())
        } finally { release.countDown(); executor.shutdownNow() }
    }

    @Test fun nameReadLaterUpdatesTheShownLineWithoutTranslatingAgain() {
        for (sentence in listOf("We need to go now.", "Come on.", "Jus- Just be quiet. Donnie's up.", "You know what I mean, right?")) {
            val result = replay(listOf(sentence, "JASON: $sentence", "JASON: $sentence"))
            assertEquals(sentence, listOf(sentence), result.requested)
            assertEquals(sentence, listOf("Çeviri 1.", "JASON: Çeviri 1."), result.sent)
            assertEquals(sentence, listOf(false, true), result.replaces)
        }
    }

    @Test fun nameOnItsOwnRowIsTheSameLine() {
        val result = replay(listOf("What the hell was that?", "JASON:\nWhat the hell was that?"))
        assertEquals(listOf("What the hell was that?"), result.requested)
        assertEquals("JASON: Çeviri 1.", result.sent.last())
        assertTrue(result.replaces.last())
    }

    @Test fun nameReadWhileTranslatingShowsOnlyTheNamedLine() {
        val result = replay(listOf("We need to go now.", "JASON: We need to go now.", "JASON: We need to go now."), open = false)
        assertEquals(listOf("We need to go now."), result.requested)
        assertEquals(listOf("JASON: Çeviri 1."), result.sent)
    }

    @Test fun flickeringNameIsOneLine() {
        val result = replay(listOf("Come on.", "JASON: Come on.", "Come on.", "JASON: Come on.", "Come on."))
        assertEquals(listOf("Come on."), result.requested)
        assertEquals(listOf("Çeviri 1.", "JASON: Çeviri 1."), result.sent)

        val first = replay(listOf("JASON: Come on.", "Come on.", "JASON: Come on.", "Come on."))
        assertEquals(listOf("Come on."), first.requested)
        assertEquals(listOf("JASON: Çeviri 1."), first.sent)
    }

    @Test fun namesHiddenSendsNothingNew() {
        val result = replay(listOf("We need to go now.", "JASON: We need to go now."), showNames = false)
        assertEquals(listOf("We need to go now."), result.requested)
        assertEquals(listOf("Çeviri 1."), result.sent)
    }

    @Test fun differentSentenceWithNameIsStillANewLine() {
        val result = replay(listOf("We need to go now.", "JASON: We don't need to go now."))
        assertEquals(listOf("We need to go now.", "We don't need to go now."), result.requested)
        assertEquals(2, result.sent.size)

        val other = replay(listOf("We need to go now.", "LUCIA: Where are we going?"))
        assertEquals(listOf("We need to go now.", "Where are we going?"), other.requested)
    }

    @Test fun stabilizerTreatsUnnamedRereadOfNamedLineAsSame() {
        assertTrue(SubtitleStabilizer.isUnnamedReread("Come on.", "JASON: Come on."))
        assertTrue(SubtitleStabilizer.isUnnamedReread("What the hell was that?", "Jason:\nWhat the hell was that?"))
        assertFalse(SubtitleStabilizer.isUnnamedReread("Come on.", "Come on."))
        assertFalse(SubtitleStabilizer.isUnnamedReread("LUCIA: Come on.", "JASON: Come on."))
        assertFalse(SubtitleStabilizer.isUnnamedReread("Go home.", "JASON: Come on."))
    }
}
