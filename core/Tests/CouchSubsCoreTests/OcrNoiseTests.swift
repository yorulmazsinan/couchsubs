// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

final class OcrNoiseTests: XCTestCase {
    /// Anıl'ın videosu: süslü yazıda bir sözcük her karede başka çöpe dönüşüyordu.
    func testGarbledWordsAreRemoved() {
        XCTAssertEqual(OcrNoise.clean("Across the deep waters, Pbo ou$3e went, hoping a boat would carry him home."),
                       "Across the deep waters, Pbo went, hoping a boat would carry him home.")
        XCTAssertEqual(OcrNoise.clean("Across the deep waters2aljd O went, Hoping a boat."),
                       "Across the deep waters O went, Hoping a boat.")
        XCTAssertEqual(OcrNoise.clean("He left 3e, at dawn."), "He left, at dawn.")
    }

    func testUsualTokensAreKept() {
        for line in ["Turn on the PS5 now.", "Hold R2-D2 still.", "It costs $500.", "Meet me at 3:00pm.",
                     "The 2nd gate is 100m away.", "Run at 60fps, 4K.", "Score x2!", "Year 1984.", "I can't — wait…",
                     "\"Kratos!\" she said.", "Mk2 rifle, 9.5kg.", "L1 + R1 Spartan Rage"] {
            XCTAssertEqual(OcrNoise.clean(line), line, line)
        }
    }

    /// Mafia'da görülen "?!" ve kutu kenarı artıkları; Windows'taki OcrNoiseTests ile aynı örnekler.
    func testStrayPunctuationAndBoxEdgesAreRemoved() {
        let cases = [
            ("?! Where do you think you're going?", "Where do you think you're going?"),
            ("Where do you think you're going ?!", "Where do you think you're going?!"),
            ("Get in the car, Enzo. ?!", "Get in the car, Enzo."),
            ("Wait, ?! Don Salieri wants you.", "Wait, Don Salieri wants you."),
            (". Get in the car.", "Get in the car."),
            ("| Get in the car, Enzo.", "Get in the car, Enzo."),
            ("Get in the car, Enzo. |", "Get in the car, Enzo."),
            ("Leave it. l", "Leave it."),
        ]
        for (raw, clean) in cases { XCTAssertEqual(OcrNoise.clean(raw), clean, raw) }
    }

    func testMisreadPronounBecomesI() {
        let cases = [
            ("l don't know, Don Salieri.", "I don't know, Don Salieri."),
            ("| don't know.", "I don't know."),
            ("l'm telling you, l saw him.", "I'm telling you, I saw him."),
            ("|'ll be right back.", "I'll be right back."),
            ("You and l've been here before.", "You and I've been here before."),
        ]
        for (raw, clean) in cases { XCTAssertEqual(OcrNoise.clean(raw), clean, raw) }
    }

    func testRealPunctuationIsKept() {
        for line in ["What?! The door opened by itself!", "- Where? - Home.", "Wait... what?", "I... I don't know.",
                     "\"Run!\" he said.", "So, you're Enzo?", "... and then he left.", "Wait ... what?", "I said no!",
                     "Leave it, I said.", "Press L to aim."] {
            XCTAssertEqual(OcrNoise.clean(line), line, line)
        }
    }

    /// Aynı karenin (ya da aynı cümlenin) iki okumasından sözcüğe daha çok benzeyeni seçmek için (Windows: OcrNoiseTests).
    func testCleanReadingScoresHigherThanGarbled() {
        XCTAssertGreaterThan(OcrNoise.score("CESARE: Wait for me!"), OcrNoise.score("- CESAREiVJütt'h!"))
        XCTAssertGreaterThan(OcrNoise.score("We go to McDonald's now."), 0)
        XCTAssertLessThan(OcrNoise.score("T hats the[lil Should be quiet now."), OcrNoise.score("That should be quiet now."))
    }

    /// Geçişte üst üste solan iki altyazının karışık okuması çöp sayılır; olağan cümleler, kısaltmalar ve "Hmm" sayılmaz.
    func testGarbledReadingsAreRecognised() {
        for text in ["Gtt solkolfege.", "- CESAREiVJütt'h!", "Wrrk thng."] {
            XCTAssertTrue(OcrNoise.looksGarbled(text), text)
        }
        for text in ["Hold the gate.", "The FBI and the NPC agents.", "Hmm, I don't know about that, boy.", "Go to college."] {
            XCTAssertFalse(OcrNoise.looksGarbled(text), text)
        }
    }

    func testReadingDropsLinesThatWereOnlyNoise() {
        let reading = Reading(lines: [TextLine("We go now."), TextLine("ou$3e 2aljd")]).withoutOcrNoise()
        XCTAssertEqual(reading.text, "We go now.")
    }
}
