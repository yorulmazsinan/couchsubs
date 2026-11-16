// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import com.couchsubs.mobile.remoteplay.DisconnectKind
import com.couchsubs.mobile.remoteplay.SessionState
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.translation.GameEnglish
import com.couchsubs.mobile.translation.TurkishPostEdit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * iPhone ve Mac'teki (CouchSubsCore) kuralların Android karşılıkları: aynı örnekler TextMatchTests,
 * OcrNoiseTests, SubtitleStabilizerTests, LinePoolTests, FreeTranslationTests, GameEnglishTests ve
 * StreamSessionTests'ten alındı.
 */
class ParityTest {
    private class TestClock {
        var now = 1_000_000L
        val read: () -> Long = { now }
    }

    @Test
    fun revisionsOfTheSameSentence() {
        val pairs = listOf(
            "We do not have time for this." to "We do not have",
            "We do not have" to "We do not have time for this.",
            "have time for this, boy." to "We do not have time for this, boy.",
            "The gate will not hold!" to "The gale will not hold",
            "Across the deep waters he went, hoping a boat would carry him home." to
                "Across the deep waters O went, Hoping a boal would carry him home",
        )
        for ((new, old) in pairs) assertTrue("$new / $old", TextMatch.isRevision(new, old))
    }

    @Test
    fun differentSentencesAreNotRevisions() {
        val pairs = listOf(
            "Run to the boat!" to "We do not have time for this.",
            "Where is the ship?" to "Where is the boy?",
            "No." to "Yes.",
            "I told you to stay with your mother." to "You should not be here.",
        )
        for ((new, old) in pairs) assertFalse("$new / $old", TextMatch.isRevision(new, old))
    }

    @Test
    fun growthOnlyCountsAddedWords() {
        assertTrue(TextMatch.isGrowth("We do not have time.", "We do not"))
        assertFalse(TextMatch.isGrowth("We do not", "We do not have time."))
        assertFalse(TextMatch.isGrowth("We do not have time.", "We do not have time."))
        assertTrue(TextMatch.isGrowth("Then we go home.", "Then"))
        assertFalse(TextMatch.isGrowth("Then we go home.", "home"))
        assertTrue(TextMatch.isGrowth("Then we go home.", "go home"))
    }

    @Test
    fun garbledReadingsAreRecognised() {
        for (text in listOf("Gtt solkolfege.", "- CESAREiVJütt'h!", "Wrrk thng.")) assertTrue(text, OcrNoise.looksGarbled(text))
        for (text in listOf("Hold the gate.", "The FBI and the NPC agents.", "Hmm, I don't know about that, boy.", "Go to college."))
            assertFalse(text, OcrNoise.looksGarbled(text))
    }

    @Test
    fun finalMisreadPronounKeepsQuestionAndExclamationMarks() {
        assertEquals("Who am I?", OcrNoise.clean("Who am l?"))
        assertEquals("Where are you, I?", OcrNoise.clean("Where are you, |?"))
        assertEquals("I don't know, I!", OcrNoise.clean("I don't know, l!"))
        assertEquals("Leave it.", OcrNoise.clean("Leave it. l."))
    }

    @Test
    fun cleanVowelReadingScoresHigherThanVowellessOcrWord() {
        assertTrue(OcrNoise.score("Get to the gate now.") > OcrNoise.score("Gtt to the gate now."))
        for (word in listOf("Hmm", "Shh", "Brr", "Psst", "Mmm")) assertTrue(word, OcrNoise.score("$word!") > 0)
    }

    @Test
    fun garbledSentenceIsNotSentOnFirstFrame() {
        val s = SubtitleStabilizer()
        assertEquals(StabilizerAction.None, s.feed("Gtt solkolfege."))
        assertEquals(StabilizerAction.translate("Go to college."), s.feed("Go to college."))
    }

    @Test
    fun garbledLineIsSentOnlyAfterStayingLongerThanACrossfade() {
        val clock = TestClock()
        val s = SubtitleStabilizer(clock = clock.read)
        val garbled = "- Nat) but, you knpw. shit, I m"
        repeat(5) {
            assertEquals(StabilizerAction.None, s.feed(garbled))
            clock.now += 100
        }
        clock.now += SubtitleStabilizer.GARBLED_STABLE_MS
        assertEquals(StabilizerAction.translate(garbled), s.feed(garbled))
    }

    @Test
    fun worseRereadOfSentLineIsNotTranslatedAgain() {
        val s = SubtitleStabilizer()
        val full = "Shit, I just came by to see if there's somethin' I can help you with."
        val worse = "Shit, I came by to see if there somethinl I can help ya."
        assertEquals(StabilizerAction.translate(full), s.feed(full))
        assertEquals(StabilizerAction.None, s.feed(worse))
        assertEquals(StabilizerAction.None, s.feed(full))
        assertEquals(StabilizerAction.None, s.feed(worse))
    }

    @Test
    fun betterRereadOfSentLineIsTranslated() {
        val s = SubtitleStabilizer()
        val full = "Shit, I just came by to see if there's somethin' I can help you with."
        val worse = "Shit, I came by to see if there somethinl I can help ya."
        assertEquals(StabilizerAction.translate(worse), s.feed(worse))
        assertEquals(StabilizerAction.translate(full), s.feed(full))
        assertEquals(StabilizerAction.None, s.feed(worse))
    }

    @Test
    fun serverMarksRevisionsAsReplace() {
        val frame = SubtitleServer.subtitleFrame("Merhaba", 1000, null, 5, replaces = true)
        assertTrue(frame, frame.contains("\"replace\":true"))
        assertFalse(SubtitleServer.subtitleFrame("Merhaba", 1000, null, 5).contains("replace"))
    }

    @Test
    fun poolRejectsTurkishAndSystemText() {
        for (line in listOf("Oturum Açtı", "Oturum Aqtl", "Sifirlama Seqenekleri", "PS5 Sistemini Yeniden Baslat", "Oyunu Kapat",
            "Ana Ekranda Tut", "Lütfen bekleyin..", "Ekran ve Video", "ilerlemenizi takip edin Kupalar",
            "Keşfet PS5 ile ilgili Öne Çıkanlar", "Ekran görüntüsü kaydedildi.", "Kupa kazandınız!",
            "Oturum Aqtl.", "Sifirlama Seqenekleri.", "PS5 Sistemini Yeniden Baslat.",
            "John signed in.", "You've earned a trophy!",
            "Please do not quit or turn off your console while the Rockstar cloud save icon is showing."))
            assertFalse(line, LinePool.accepts(line))
        for (line in listOf("Herr Müller will see you now.", "This place was designed in a hurry.", "Tell Sam I signed the deal.",
            "I lie to you, you lie to me.", "Don Torrisi wants you.", "DON TORRISI WANTS YOU!"))
            assertTrue(line, LinePool.accepts(line))
    }

    @Test
    fun poolRejectsFragmentsAndShortLines() {
        for (line in listOf("GO to the", "Take out the trash and the", "it Auto V's Story Mode.", "FREE MONTH OF GTA+",
            "PHOTO MODE SELECT", "Main menu", "Hold on"))
            assertFalse(line, LinePool.accepts(line))
        for (line in listOf("Get down!", "Who's there?", "Line number 7 here", "We need to move before the cops show up"))
            assertTrue(line, LinePool.accepts(line))
    }

    @Test
    fun gameIdiomsBecomePlainEnglish() {
        assertEquals("Hold your fire! They're allies!", GameEnglish.plain("Hold your fire! They're friendlies!"))
        assertEquals("I've got your back.", GameEnglish.plain("I got your six."))
        assertEquals("Watch out! Incoming!", GameEnglish.plain("Heads up! Incoming!"))
        assertEquals("You're late.", GameEnglish.plain("Took you long enough."))
        assertEquals("Careful, enemies are coming.", GameEnglish.plain("Careful, we've got company."))
        assertEquals("Copy that. Going in.", GameEnglish.plain("Copy that. Moving in."))
        assertEquals("The friendliest town in the north.", GameEnglish.plain("The friendliest town in the north."))
        assertEquals("Stand down!", GameEnglish.plain("Stand down!"))
    }

    @Test
    fun sourceEndingIsKept() {
        val cases = listOf(
            Triple("Run!", "Koş.", "Koş!"), Triple("Run!", "Koş", "Koş!"), Triple("What?!", "Ne?", "Ne?!"), Triple("Wait…", "Bekle.", "Bekle…"),
            Triple("Wait...", "Bekle.", "Bekle..."), Triple("Where is he?", "O nerede.", "O nerede?"),
            Triple("He said \"Run!\"", "\"Koş.\" dedi.", "\"Koş.\" dedi."), Triple("He said \"Run!\"", "\"Koş\" dedi", "\"Koş\" dedi"),
            Triple("\"Run!\"", "\"Koş.\"", "\"Koş!\""), Triple("We go.", "Gidiyoruz!", "Gidiyoruz!"), Triple("We go.", "Gidiyoruz", "Gidiyoruz"),
            Triple("Boy!", "Evlat!", "Evlat!"),
        )
        for ((source, translation, expected) in cases) assertEquals(source, expected, TurkishPostEdit.apply(source, translation))
    }

    @Test
    fun spaceBeforePunctuationIsRemovedAndQuotesFollowTheSource() {
        for ((translation, expected) in listOf("Dur , bekle !" to "Dur, bekle!", "Ne  oldu ?" to "Ne oldu?", "Peki ... gidelim ." to "Peki... gidelim."))
            assertEquals(expected, TurkishPostEdit.apply("Okay. Go.", translation))
        assertEquals("\"Koş\" dedi, Kratos'un oğlu.", TurkishPostEdit.apply("He said \"run\", Kratos's son.", "“Koş” dedi, Kratos’un oğlu."))
        assertEquals("“Koş” dedi, Kratos’un oğlu.", TurkishPostEdit.apply("He said “run”, Kratos’s son.", "\"Koş\" dedi, Kratos'un oğlu."))
    }

    @Test
    fun imperativesFollowAnInformalLine() {
        assertEquals(listOf("Sana söyledim.", "Bekle!", "Dikkat et, evlat."), TurkishPostEdit.register(listOf("Sana söyledim.", "Bekleyin!", "Dikkat edin, evlat.")))
        assertEquals(listOf("Seni gördüm. Hemen gel!"), TurkishPostEdit.register(listOf("Seni gördüm. Hemen gelin!")))
        for (sentence in listOf("Bekleyin!", "Siz bekleyin, sana sonra bakarım!", "Sen gelin misin?"))
            assertEquals(listOf(sentence), TurkishPostEdit.register(listOf(sentence)))
        assertEquals(listOf(null, "Sana söyledim.", null, "Dur!"), TurkishPostEdit.register(listOf(null, "Sana söyledim.", null, "Durun!")))
    }

    @Test
    fun sessionRequestLogLinesAreClassified() {
        assertEquals(DisconnectKind.REGISTRATION_INVALID,
            DisconnectKind.sessionRequestHint("Reported Application Reason: 0x80108b09 (Regist failed, probably invalid PIN)")?.kind)
        assertEquals(DisconnectKind.REGISTRATION_INVALID, DisconnectKind.sessionRequestHint("Reported Application Reason: 0x80108B02 (Invalid PSN ID)")?.kind)
        // PS5 kayıt dışı bir kodla reddetti: kod ayrıntıda (GitHub #33, #202).
        assertEquals(SessionState.Disconnected(DisconnectKind.REJECTED, "0x80108bff"),
            DisconnectKind.sessionRequestHint("Reported Application Reason: 0x80108bff (unknown)"))
        assertNull(DisconnectKind.sessionRequestHint("Reported Application Reason: garbage"))
        assertEquals(DisconnectKind.NETWORK, DisconnectKind.sessionRequestHint("Session request connect failed eventually.")?.kind)
        assertEquals(DisconnectKind.NETWORK, DisconnectKind.sessionRequestHint("Failed to receive session request response")?.kind)
        assertEquals(DisconnectKind.NETWORK, DisconnectKind.sessionRequestHint("Failed to send session request")?.kind)
        assertNull(DisconnectKind.sessionRequestHint("Session request successful"))
        assertNull(DisconnectKind.sessionRequestHint("Failed to parse session request response"))
        assertEquals(DisconnectKind.REGISTRATION_INVALID, DisconnectKind.sessionRequestHint(listOf("Failed to send session request",
            "Reported Application Reason: 0x80108b09 (Regist failed)"))?.kind)
    }

    @Test
    fun subtitleScaleReachesTheTv() {
        assertEquals(46, AppSettings.scaledFontSize(46, 100))
        assertEquals(55, AppSettings.scaledFontSize(46, 120))
        assertEquals(74, AppSettings.scaledFontSize(46, 160))
        assertEquals(37, AppSettings.scaledFontSize(46, 80))
        // #218: TV'de en küçük boy masaüstüne yakın (Mac 20, Windows 16); daha azı alt sınıra çekilir.
        assertEquals(18, AppSettings.scaledFontSize(46, 40))
        assertEquals(18, AppSettings.scaledFontSize(46, 10))
    }

    @Test
    fun phoneScreenReplacesRevisedLine() {
        var status = LiveStatus()
        status = status.phoneEvent(SubtitleEvent.Subtitle("Bunun için", 1000))
        status = status.phoneEvent(SubtitleEvent.Subtitle("Bunun için vaktimiz yok.", 1000, replaces = true))
        assertEquals("Bunun için vaktimiz yok.", status.current)
        assertEquals("", status.previous)
        status = status.phoneEvent(SubtitleEvent.Subtitle("Tekneye koş!", 1000))
        assertEquals("Bunun için vaktimiz yok.", status.previous)
        status = status.phoneEvent(SubtitleEvent.Cleared)
        assertEquals("", status.current)
        assertEquals("", status.previous)
    }
}

/** Okuma hattının sırası ve TV'ye giden `replace` (Mac/iPhone SubtitlePipelineTests ile aynı durumlar). */
class PipelineQueueTest {
    private class Recorder : SubtitleSender {
        val sent = mutableListOf<Pair<String, Boolean>>()
        override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
            sent.add(text to replaces)
        }
        override fun clear() {}
    }

    /** Kaynağa benzemeyen sahte çeviri (benzer çeviri "zaten hedef dilde" sayılıp gösterilmez). */
    private fun tr(text: String) = "<" + text.reversed() + ">"

    private val direct = object : java.util.concurrent.AbstractExecutorService() {
        override fun execute(command: Runnable) = command.run()
        override fun shutdown() {}
        override fun shutdownNow() = mutableListOf<Runnable>()
        override fun isShutdown() = false
        override fun isTerminated() = false
        override fun awaitTermination(timeout: Long, unit: java.util.concurrent.TimeUnit) = true
    }

    @Test
    fun grownLineReplacesItsHalfOnTheTv() {
        val recorder = Recorder()
        var now = 0L
        val pipeline = SubtitlePipeline({ tr(it) }, recorder, { now }, direct)
        val area = CropRegion().box
        pipeline.process(Reading.fromText("We do not have"), area)
        now += 100
        pipeline.process(Reading.fromText("We do not have"), area)
        now += 100
        pipeline.process(Reading.fromText("We do not have time for this."), area)
        assertEquals(listOf(tr("We do not have") to false, tr("We do not have time for this.") to true), recorder.sent)
    }

    @Test
    fun twoLinesWaitWhileATranslationRuns() {
        val recorder = Recorder()
        var now = 0L
        val queued = mutableListOf<Runnable>()
        val manual = object : java.util.concurrent.AbstractExecutorService() {
            override fun execute(command: Runnable) { queued.add(command) }
            override fun shutdown() {}
            override fun shutdownNow() = mutableListOf<Runnable>()
            override fun isShutdown() = false
            override fun isTerminated() = false
            override fun awaitTermination(timeout: Long, unit: java.util.concurrent.TimeUnit) = true
        }
        val pipeline = SubtitlePipeline({ tr(it) }, recorder, { now }, manual)
        val area = CropRegion().box
        for (line in listOf("Run to the boat!", "Where is the ship?", "I told you to stay with your mother.")) {
            pipeline.process(Reading.fromText(line), area)
            now += 300
        }
        queued.removeAt(0).run()
        // Üç satır da gösterilir: süren çeviri bitince sıradaki iki satır sırayla çevrilir (eskiden yalnız en yenisi kalıyordu).
        assertEquals(listOf(tr("Run to the boat!"), tr("Where is the ship?"), tr("I told you to stay with your mother.")),
            recorder.sent.map { it.first })
    }
}
