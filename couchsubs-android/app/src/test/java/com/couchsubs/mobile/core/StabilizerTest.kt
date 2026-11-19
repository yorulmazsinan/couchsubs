// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Windows'taki SubtitleStabilizerTests ve OcrNoiseTests'in aynı durumları. */
class StabilizerTest {
    private class TestClock {
        var now = 1_000_000L
        val read: () -> Long = { now }
    }

    private fun tr(text: String) = StabilizerAction.translate(text)
    private fun restore(text: String) = StabilizerAction.restore(text)

    /** Olumsuzluk ya da sayı farkı anlamı tersine çevirir; yeniden okuma sayılmamalı (Windows: TextMatchTests). */
    @Test
    fun meaningChangingRereadIsNotSameSubtitle() {
        for ((reread, sent) in listOf(
            "I can't do that for you right now." to "I can do that for you right now.",
            "I said that I would never help you with this." to "I said that I would help you with this.",
            "He is not coming back tonight." to "He is coming back tonight.",
            "Meet me at the docks at 6." to "Meet me at the docks at 5.",
        )) assertFalse(reread, TextMatch.isSameSubtitle(TextMatch.normalize(reread), TextMatch.normalizeRows(sent)))
    }

    /** Olumsuzluk korunurken yalnız yazımı farklı okunan satır yine aynı altyazıdır. */
    @Test
    fun spellingNoiseKeepsNegatedLineSame() {
        for ((reread, sent) in listOf(
            "I can’t do that for you right now." to "I can't do that for you right now.",
            "I dont know what to do." to "I don't know what to do.",
            "He is n0t coming back tonight." to "He is not coming back tonight.",
        )) assertTrue(reread, TextMatch.isSameSubtitle(TextMatch.normalize(reread), TextMatch.normalizeRows(sent)))
    }

    /** Yalnız eklenen işaret sayılır; kesmenin "t"si yalnız bilinen olumsuz kısaltmayı tamamlar. */
    @Test
    fun addsMeaningCountsOnlyAddedMarks() {
        for ((pair, expected) in listOf(
            ("I can't do that." to "I can do that.") to true,
            ("I can do that." to "I can't do that.") to false,
            ("Meet me at 6." to "Meet me at 5.") to true,
            ("Meet me at" to "Meet me at 5.") to false,
            ("He is n0t here." to "He is here.") to true,
            ("I dont know." to "I don't know.") to false,
            ("Buy a t shirt." to "Buy a shirt.") to false,
            ("Buy a cotton t shirt." to "Buy a cotton shirt.") to false,
            ("I won t go." to "I will go.") to true,
            ("We haven t left." to "We have left.") to true,
            ("Bring 5 and 5." to "Bring 5.") to true,
            ("Bring 5." to "Bring 5 and 5.") to false,
            ("It costs \$500 now." to "It costs \$500.") to false,
            ("1 can do that." to "I can do that.") to false,
        )) assertEquals(pair.first, expected, TextMatch.addsMeaning(pair.first, pair.second))
    }

    /** İlk kare olumsuzluğu ya da sayıyı kaçırıp gönderildiyse doğru okuma yeniden çevrilir (Windows: SubtitleStabilizerTests). */
    @Test
    fun correctedReadThatChangesMeaningIsTranslated() {
        for ((misread, correct) in listOf(
            "I can do that for you right now." to "I can't do that for you right now.",
            "I said that I would help you with this." to "I said that I would never help you with this.",
            "Meet me at the docks at 5." to "Meet me at the docks at 6.",
        )) {
            val s = SubtitleStabilizer()
            assertEquals(misread, tr(misread), s.feed(misread))
            assertEquals(correct, tr(correct), s.feed(correct))
        }
    }

    @Test
    fun unfinishedLineIsSentAfterTwoStableFrames() {
        val s = SubtitleStabilizer()
        assertEquals(StabilizerAction.None, s.feed("We do not have time"))
        assertEquals(tr("We do not have time"), s.feed("We do not have time"))
        assertEquals(StabilizerAction.None, s.feed("We do not have time"))
    }

    @Test
    fun garbledRereadOfSentLineDoesNotReemit() {
        val s = SubtitleStabilizer()
        val first = "Across the deep waters, Pbo went,\nhoping a boat would carry him home."
        assertEquals(tr(first), s.feed(first))
        assertEquals(StabilizerAction.None, s.feed("Across the deep waters O went,"))
        assertEquals(StabilizerAction.None, s.feed("Across the deep waters O went,"))
        assertEquals(tr("We should keep moving."), s.feed("We should keep moving."))
    }

    @Test
    fun finishedSentenceIsSentOnFirstFrame() {
        for (line in listOf("We do not have time.", "Wait!", "Who are you?", "I know…", "\"Run.\"")) {
            val s = SubtitleStabilizer()
            assertEquals(tr(line), s.feed(line))
            assertEquals(StabilizerAction.None, s.feed(line))
        }
    }

    @Test
    fun ocrNoiseDoesNotReemit() {
        val s = SubtitleStabilizer()
        s.feed("The gate will not hold")
        s.feed("The gate will not hold")
        assertEquals(StabilizerAction.None, s.feed("The gale will not hold"))
        assertEquals(StabilizerAction.None, s.feed("The gale will not hold"))
    }

    @Test
    fun flickeringHudDoesNotSpam() {
        val s = SubtitleStabilizer()
        val sent = (0 until 20).count { s.feed(if (it % 2 == 0) "24 / 120" else "").kind == StabilizerKind.TRANSLATE }
        assertEquals(0, sent)
    }

    @Test
    fun typewriterSendsCompletedLine() {
        val s = SubtitleStabilizer()
        s.feed("We do")
        s.feed("We do not have")
        assertEquals(tr("We do not have time for this, boy."), s.feed("We do not have time for this, boy."))
        assertEquals(StabilizerAction.None, s.feed("We do not have time for this, boy."))
    }

    @Test
    fun emptyRegionClearsAfterClearTime() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        s.feed("Hello there")
        s.feed("Hello there")
        assertEquals(StabilizerAction.None, s.feed(""))
        clock.now += SubtitleStabilizer.CLEAR_AFTER_MS - 1
        assertEquals(StabilizerAction.None, s.feed(""))
        clock.now += 1
        assertEquals(StabilizerAction.Clear, s.feed(""))
        assertEquals(StabilizerAction.None, s.feed(""))
    }

    @Test
    fun shortFlickerNeitherClearsNorResends() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        s.feed("Hold the gate")
        assertEquals(tr("Hold the gate"), s.feed("Hold the gate"))
        repeat(3) {
            repeat(10) { clock.now += 50; assertEquals(StabilizerAction.None, s.feed("")) }
            repeat(4) { clock.now += 50; assertEquals(StabilizerAction.None, s.feed("Hold the gate")) }
        }
    }

    @Test
    fun lineReturningSoonAfterClearIsRestored() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        assertEquals(tr("Hold the gate."), s.feed("Hold the gate."))
        s.feed("")
        clock.now += SubtitleStabilizer.CLEAR_AFTER_MS
        assertEquals(StabilizerAction.Clear, s.feed(""))
        clock.now += SubtitleStabilizer.RESTORE_WITHIN_MS
        assertEquals(StabilizerAction.None, s.feed("Hold the gate"))
        assertEquals(restore("Hold the gate."), s.feed("Hold the gate"))
        assertEquals(StabilizerAction.None, s.feed("Hold the gate."))
        s.feed("")
        clock.now += SubtitleStabilizer.CLEAR_AFTER_MS
        assertEquals(StabilizerAction.Clear, s.feed(""))
    }

    @Test
    fun lineReturningLaterIsTranslatedAgain() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        s.feed("Hold the gate.")
        s.feed("")
        clock.now += SubtitleStabilizer.CLEAR_AFTER_MS
        assertEquals(StabilizerAction.Clear, s.feed(""))
        clock.now += SubtitleStabilizer.RESTORE_WITHIN_MS + 1
        assertEquals(tr("Hold the gate."), s.feed("Hold the gate."))
    }

    @Test
    fun replacedLineComingBackIsRestored() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        assertEquals(tr("Hold the gate."), s.feed("Hold the gate."))
        clock.now += 100
        assertEquals(tr("Run!"), s.feed("Run!"))
        clock.now += 100
        assertEquals(restore("Hold the gate."), s.feed("Hold the gate."))
        clock.now += 100
        assertEquals(restore("Run!"), s.feed("Run!"))
    }

    @Test
    fun twoSpeakersWithOverlappingWordsAreBothTranslated() {
        val cases = listOf(
            "Where are you going?" to "Where are you going, boy?",
            "Where are you going, boy?" to "Where are you going?",
            "We need to leave this place before the sun goes down." to "We need to leave this place before the sun goes down, boy.",
        )
        for ((first, second) in cases) {
            val clock = TestClock()
            val s = SubtitleStabilizer(clock = clock.read)
            assertEquals(tr(first), s.feed(first))
            clock.now += 50
            assertEquals(tr(second), s.feed(second))
        }
    }

    @Test
    fun alreadyTranslatedIsSkipped() {
        val s = SubtitleStabilizer()
        assertFalse(s.shouldSend("Kullanıcı Ekle Oturum Açtı", "Kullanıcı Ekle Oturum Açtı"))
        assertTrue(s.shouldSend("Add user", "Kullanıcı ekle"))
    }

    @Test
    fun resetClearsOnlyAfterSomethingWasSent() {
        val s = SubtitleStabilizer()
        assertEquals(StabilizerAction.None, s.reset())
        s.feed("Hello there")
        s.feed("Hello there")
        assertEquals(StabilizerAction.Clear, s.reset())
        assertEquals(StabilizerAction.None, s.reset())
    }

    @Test
    fun forgottenLineIsTranslatedAgainAfterBackoff() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        s.feed("Hold the gate")
        assertEquals(tr("Hold the gate"), s.feed("Hold the gate"))
        s.forgetSent()
        repeat(19) { clock.now += 50; assertEquals(StabilizerAction.None, s.feed("Hold the gate")) }
        clock.now += 50
        assertEquals(tr("Hold the gate"), s.feed("Hold the gate"))
    }

    @Test
    fun backoffDoesNotDelayANewLine() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        s.feed("Hold the gate")
        s.feed("Hold the gate")
        s.forgetSent()
        assertEquals(tr("Run!"), s.feed("Run!"))
    }
}

class OcrNoiseTest {
    @Test
    fun garbledWordsAreRemoved() {
        assertEquals("Across the deep waters, Pbo went, hoping a boat would carry him home.",
            OcrNoise.clean("Across the deep waters, Pbo ou$3e went, hoping a boat would carry him home."))
        assertEquals("Across the deep waters O went, Hoping a boat.", OcrNoise.clean("Across the deep waters2aljd O went, Hoping a boat."))
        assertEquals("He left, at dawn.", OcrNoise.clean("He left 3e, at dawn."))
    }

    @Test
    fun usualTokensAreKept() {
        for (line in listOf(
            "Turn on the PS5 now.", "Hold R2-D2 still.", "It costs $500.", "Meet me at 3:00pm.", "The 2nd gate is 100m away.",
            "Run at 60fps, 4K.", "Score x2!", "Year 1984.", "I can't — wait…", "\"Kratos!\" she said.", "Mk2 rifle, 9.5kg.",
            "L1 + R1 Spartan Rage",
        )) assertEquals(line, OcrNoise.clean(line))
    }

    @Test
    fun strayPunctuationAndBoxEdgesAreRemoved() {
        val cases = mapOf(
            "?! Where do you think you're going?" to "Where do you think you're going?",
            "Where do you think you're going ?!" to "Where do you think you're going?!",
            "Get in the car, Enzo. ?!" to "Get in the car, Enzo.",
            "Wait, ?! Don Salieri wants you." to "Wait, Don Salieri wants you.",
            ". Get in the car." to "Get in the car.",
            "| Get in the car, Enzo." to "Get in the car, Enzo.",
            "Get in the car, Enzo. |" to "Get in the car, Enzo.",
            "Leave it. l" to "Leave it.",
        )
        for ((line, expected) in cases) assertEquals(line, expected, OcrNoise.clean(line))
    }

    @Test
    fun misreadPronounBecomesI() {
        val cases = mapOf(
            "l don't know, Don Salieri." to "I don't know, Don Salieri.",
            "| don't know." to "I don't know.",
            "l'm telling you, l saw him." to "I'm telling you, I saw him.",
            "|'ll be right back." to "I'll be right back.",
            "You and l've been here before." to "You and I've been here before.",
        )
        for ((line, expected) in cases) assertEquals(line, expected, OcrNoise.clean(line))
    }

    @Test
    fun realPunctuationIsKept() {
        for (line in listOf(
            "What?! The door opened by itself!", "- Where? - Home.", "Wait... what?", "I... I don't know.", "\"Run!\" he said.",
            "So, you're Enzo?", "... and then he left.", "Wait ... what?", "I said no!", "Leave it, I said.", "Press L to aim.",
        )) assertEquals(line, OcrNoise.clean(line))
    }

    @Test
    fun readingDropsLinesThatWereOnlyNoise() {
        val reading = Reading(listOf(TextLine("We go now."), TextLine("ou$3e 2aljd"))).withoutOcrNoise()
        assertEquals("We go now.", reading.text)
    }

    @Test
    fun cleanReadingScoresHigherThanGarbled() {
        assertTrue(OcrNoise.score("CESARE: Wait for me!") > OcrNoise.score("- CESAREiVJütt'h!"))
        assertTrue(OcrNoise.score("We go to McDonald's now.") > 0)
        assertTrue(OcrNoise.score("T hats the[lil Should be quiet now.") < OcrNoise.score("That should be quiet now."))
    }

    @Test
    fun buttonPromptsAreNotSubtitles() {
        assertTrue(ButtonPrompts.isPrompt("R2 Swing"))
        assertTrue(ButtonPrompts.isPrompt("△ Pick up"))
        assertTrue(ButtonPrompts.isPrompt("Press ✕ to jump"))
        assertFalse(ButtonPrompts.isPrompt("We go now, boy."))
    }

    /** GTA 6 (#404): etkileşim ve ekipman yazıları tek başına okununca altyazı sayılmaz; kısa konuşma kalır. */
    @Test
    fun actionLabelsAreNotSubtitles() {
        val area = TextBox(0.0, 0.6, 1.0, 1.0)
        fun alone(text: String) = Reading(listOf(TextLine(text, TextBox(0.4, 0.8, 0.6, 0.87))))
        for (label in listOf("TAKE AMMO PACK (0/3)", "SIT", "FRESHEN UP", "• ADD TO TRUNK", "> REMOVE FROM TRUNK",
            "D STASH", "A TURN ON", "BEAST", "BENCH PRESS")) {
            assertTrue(label, ButtonPrompts.isActionLabel(label))
            assertEquals(label, "", alone(label).subtitleBlock(area).text)
            assertEquals(label, "", Reading(listOf(TextLine(label))).subtitleBlock(area).text)
        }
        for (speech in listOf("Yes.", "Okay.", "Why?", "OKAY.", "WHAT?", "Talk to Andy", "はい",
            "EXCLUSIVE: LEONIDA'S TOP SPOTS FOR A DECENT CATCH")) {
            assertFalse(speech, ButtonPrompts.isActionLabel(speech))
            assertEquals(speech, alone(speech).subtitleBlock(area).text)
        }
        val withSubtitle = Reading(listOf(
            TextLine("Hey. Looking for Andy.", TextBox(0.35, 0.7, 0.65, 0.77)),
            TextLine("TAKE AMMO PACK (0/3)", TextBox(0.42, 0.9, 0.58, 0.97)),
        ))
        assertEquals("Hey. Looking for Andy.", withSubtitle.subtitleBlock(area).text)
        val wrapped = Reading(listOf(
            TextLine("I TOLD YOU", TextBox(0.42, 0.7, 0.58, 0.77)),
            TextLine("NOT TO GO THERE.", TextBox(0.4, 0.78, 0.6, 0.85)),
        ))
        assertEquals("I TOLD YOU\nNOT TO GO THERE.", wrapped.subtitleBlock(area).text)
    }
}

/** Okuma hattı: paket satırı beklemeden gösterilir, motor yalnız paketsiz satırda çağrılır. */
class PipelineTest {
    private class Recorder : SubtitleSender {
        val sent = mutableListOf<String>()
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
            sent.add(text)
        }
        override fun clear() {
            sent.add("<clear>")
        }
    }

    private val direct = object : java.util.concurrent.AbstractExecutorService() {
        override fun execute(command: Runnable) = command.run()
        override fun shutdown() {}
        override fun shutdownNow() = mutableListOf<Runnable>()
        override fun isShutdown() = false
        override fun isTerminated() = false
        override fun awaitTermination(timeout: Long, unit: java.util.concurrent.TimeUnit) = true
    }

    @Test
    fun packLineSkipsTheEngineAndMissIsReported() {
        val recorder = Recorder()
        val engine = mutableListOf<String>()
        val missed = mutableListOf<String>()
        var now = 0L
        val pipeline = SubtitlePipeline({ engine.add(it); "çeviri: $it" }, recorder, { now }, direct)
        pipeline.packLookup = { if (it == "Get down!") PackMatch("Yere yat!", "mafia") else null }
        pipeline.onPackMissed = { missed.add(it) }
        val area = CropRegion().box
        pipeline.process(Reading.fromText("Get down!"), area)
        now += 100
        pipeline.process(Reading.fromText("Who goes there?"), area)
        assertEquals(listOf("Yere yat!", "çeviri: Who goes there?"), recorder.sent)
        assertEquals(listOf("Who goes there?"), engine)
        assertEquals(listOf("Who goes there?"), missed)
        assertEquals(1, pipeline.packHits)
    }
}
