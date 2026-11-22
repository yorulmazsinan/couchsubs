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

    /// Menü satırlarının kenarı hizalıdır; ortalanmış kısa konuşma satırları ("No / Wait / Go on") menü sayılmaz.
    /// Konuşan adıyla başlayan satır da menü değildir (Windows, Android ile aynı).
    func testCenteredShortLinesAndSpeakerLinesAreNotAMenu() {
        let menu = Reading(lines: [line("MAP", 0.05, 0.05, 0.10), line("HELP", 0.05, 0.15, 0.11), line("SETTINGS", 0.051, 0.25, 0.17)])
        XCTAssertTrue(menu.isMenu)
        let spoken = Reading(lines: [line("No", 0.47, 0.05, 0.53), line("Wait", 0.46, 0.15, 0.54), line("Go on", 0.45, 0.25, 0.55)])
        XCTAssertFalse(spoken.isMenu)
        let named = Reading(lines: [line("JASON: No", 0.05, 0.05, 0.15), line("LUCIA: Wait", 0.05, 0.15, 0.16),
                                    line("JASON: Go", 0.05, 0.25, 0.15)])
        XCTAssertFalse(named.isMenu)
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

    /// GitHub #933 (GTA 6): karakter TV izlerken haber bandı konuşmanın altında hiç değişmeden duruyor; uzun süredir
    /// değişmeyen ortalı blok, yanında yeni beliren ortalı blok varken seçilmez. Tek sabit blok seçilmeye devam eder.
    func testStaleCenteredBlockLosesToNewOne() {
        let speech = line("We are live from the scene where it all happened.", 0.25, 0.3, 0.75)
        let ticker = line("STORM HITS VICE CITY COAST - LIVE COVERAGE", 0.3, 0.8, 0.7)
        let ages = [speech.text: 1200, ticker.text: 9000]
        var skipped: [String] = []
        let both = Reading(lines: [speech, ticker])
        XCTAssertEqual(both.subtitleBlock(in: area).text, ticker.text)
        let chosen = both.subtitleBlock(in: area, age: { ages[$0] }, stale: { skipped.append($0.text) })
        XCTAssertEqual(chosen.text, speech.text)
        XCTAssertEqual(skipped, [ticker.text])
        // Tek sabit blok (değişmeyen uzun cümle) altyazıdır.
        skipped = []
        XCTAssertEqual(Reading(lines: [ticker]).subtitleBlock(in: area, age: { ages[$0] }, stale: { skipped.append($0.text) }).text,
                       ticker.text)
        XCTAssertTrue(skipped.isEmpty)
        // İkisi de aynı anda belirip sabit kaldıysa (hangisinin yeni olduğu bilinmiyor) eski kural geçerli.
        XCTAssertEqual(both.subtitleBlock(in: area, age: { _ in 9000 }).text, ticker.text)
        // Bant konuşan adı gibi başlıyor ("EXCLUSIVE: …"): sabitse yine atlanır, yeni konuşma seçilir.
        let headline = line("EXCLUSIVE: LEONIDA'S TOP SPOTS FOR A DECENT CATCH", 0.25, 0.8, 0.75)
        let news = Reading(lines: [speech, headline])
        XCTAssertEqual(news.subtitleBlock(in: area).text, headline.text)
        XCTAssertEqual(news.subtitleBlock(in: area, age: { $0 == headline.text ? 9000 : 1000 }).text, speech.text)
        // Konuşan adlı blok yeniyse ya da yanındaki yeni yazı kısa (görev/HUD) ise seçilmeye devam eder.
        let named = line("ANCHOR: Stay with us for more.", 0.3, 0.3, 0.7)
        XCTAssertEqual(Reading(lines: [named, ticker]).subtitleBlock(in: area, age: { $0 == named.text ? 1000 : 9000 }).text,
                       named.text)
        let short = line("Follow John", 0.4, 0.8, 0.6)
        XCTAssertEqual(Reading(lines: [named, short]).subtitleBlock(in: area, age: { $0 == named.text ? 9000 : 1000 }).text,
                       named.text)
    }

    func testStickyRowsReportsHowLongALineIsUnchanged() {
        var rows = StickyRows()
        let reading = Reading(lines: [TextLine("BREAKING NEWS: STORM HITS COAST")])
        _ = rows.filter(reading, at: 0)
        _ = rows.filter(reading, at: 1000)
        XCTAssertEqual(rows.unchangedMs("BREAKING NEWS: STORM HITS COAST", at: 1000), 1000)
        XCTAssertNil(rows.unchangedMs("Something else entirely here", at: 1000))
    }
}
