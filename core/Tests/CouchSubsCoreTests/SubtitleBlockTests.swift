// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Alanda altyazının yanında menü, köşe göstergesi ve kumanda ipucu da okunur (Red Dead Redemption 2).
final class SubtitleBlockTests: XCTestCase {
    private let area = TextBox(left: 0, top: 0.6, right: 1, bottom: 1)

    private func line(_ text: String, _ left: Double, _ top: Double, _ right: Double, height: Double = 0.07) -> TextLine {
        TextLine(text, box: TextBox(left: left, top: top, right: right, bottom: top + height))
    }

    func testMenuAndCornerTextAreNotSubtitles() {
        let menu = ["MAP", "HELP", "PROGRESS", "PLAYER", "STORY", "ONLINE", "SOCIAL CLUB", "SETTINGS"].enumerated().map {
            line($0.element, 0.05, 0.05 + Double($0.offset) * 0.1, 0.05 + Double($0.element.count) * 0.015)
        }
        let reading = Reading(lines: menu + [line("PHOTO MODE", 0.85, 0.9, 0.97)])
        XCTAssertEqual(reading.subtitleBlock(in: area), .empty)
    }

    func testCenteredSubtitleIsKeptWithoutCornerGauge() {
        let reading = Reading(lines: [
            line("We'll lose these tracks if we don't hurry.", 0.25, 0.7, 0.75),
            line("9", 0.02, 0.7, 0.04),
            line("PHOTO MODE", 0.85, 0.9, 0.97),
        ])
        let block = reading.subtitleBlock(in: area)
        XCTAssertEqual(block.text, "We'll lose these tracks if we don't hurry.")
        XCTAssertEqual(block.box, TextBox(left: 0.25, top: 0.7, right: 0.75, bottom: 0.77))
    }

    func testTwoLineSubtitleStaysTogether() {
        let reading = Reading(lines: [
            line("Mac and John... they were both shot.", 0.3, 0.6, 0.7),
            line("We need to move.", 0.4, 0.68, 0.6),
        ])
        XCTAssertEqual(reading.subtitleBlock(in: area).text, "Mac and John... they were both shot.\nWe need to move.")
    }

    func testLeftAlignedSentenceIsStillRead() {
        let reading = Reading(lines: [line("Mafioso: We're worried about this one.", 0.05, 0.8, 0.5)])
        XCTAssertEqual(reading.subtitleBlock(in: area).text, "Mafioso: We're worried about this one.")
    }

    func testLinesWithoutPlaceAreUntouched() {
        let reading = Reading(text: "MAP\nHELP")
        XCTAssertEqual(reading.subtitleBlock(in: area), reading)
    }

    func testButtonAtTheEndIsAPrompt() {
        XCTAssertTrue(ButtonPrompts.isPrompt("PHOTO MODE L1 + R1"))
        XCTAssertTrue(ButtonPrompts.isPrompt("PHOTO MODE [L1] + [R3]"))
        XCTAssertFalse(ButtonPrompts.isPrompt("Hand me the L1."))
    }

    func testGaugeNumberStuckToLineIsDropped() {
        XCTAssertEqual(OcrNoise.clean("9? We'll lose these tracks."), "We'll lose these tracks.")
        XCTAssertEqual(OcrNoise.clean("100. Mac and John..."), "Mac and John...")
        XCTAssertEqual(OcrNoise.clean("23m CESARE: It's here! Shoot him!"), "CESARE: It's here! Shoot him!")
        XCTAssertEqual(OcrNoise.clean("100 men came"), "100 men came")
    }

    /// GTA 6 (#404): etkileşim ve ekipman yazıları tek başına okununca altyazı sayılmaz; kısa konuşma kalır.
    func testActionLabelsAreNotSubtitles() {
        for label in ["TAKE AMMO PACK (0/3)", "SIT", "CLOSE", "FRIDGE", "FRESHEN UP", "• ADD TO TRUNK", "> REMOVE FROM TRUNK",
                      "D STASH", "A TURN ON", "TURN ON", "BEAST", "EASY", "BENCH PRESS", "DEADLIFTS"] {
            XCTAssertTrue(ButtonPrompts.isActionLabel(label), label)
            XCTAssertEqual(Reading(lines: [line(label, 0.4, 0.8, 0.6)]).subtitleBlock(in: area), .empty, label)
            XCTAssertEqual(Reading(text: label).subtitleBlock(in: area), .empty, label)
        }
        for speech in ["Yes.", "Okay.", "Why?", "OKAY.", "WHAT?", "Same.", "Talk to Andy", "Follow Andy",
                       "EXCLUSIVE: LEONIDA'S TOP SPOTS FOR A DECENT CATCH", "はい", "Mommy..."] {
            XCTAssertFalse(ButtonPrompts.isActionLabel(speech), speech)
            XCTAssertEqual(Reading(lines: [line(speech, 0.4, 0.8, 0.6)]).subtitleBlock(in: area).text, speech)
        }
    }

    func testActionLabelBelowSubtitleDoesNotHideIt() {
        let reading = Reading(lines: [
            line("Hey. Looking for Andy.", 0.35, 0.7, 0.65),
            line("TAKE AMMO PACK (0/3)", 0.42, 0.9, 0.58),
        ])
        XCTAssertEqual(reading.subtitleBlock(in: area).text, "Hey. Looking for Andy.")
    }

    func testWrappedAllCapsSubtitleStaysTogether() {
        let reading = Reading(lines: [line("I TOLD YOU", 0.42, 0.7, 0.58), line("NOT TO GO THERE.", 0.4, 0.78, 0.6)])
        XCTAssertEqual(reading.subtitleBlock(in: area).text, "I TOLD YOU\nNOT TO GO THERE.")
    }
}
